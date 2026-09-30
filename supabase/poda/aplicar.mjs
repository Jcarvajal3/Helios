#!/usr/bin/env node
// ============================================================================
// Helios — Aplica las migraciones pendientes al proyecto remoto, SIN Docker
//
//   node supabase/poda/aplicar.mjs                  # aplica todo lo pendiente
//   node supabase/poda/aplicar.mjs --pendientes     # solo lista, no aplica
//   node supabase/poda/aplicar.mjs --hasta 20260901000000
//   node supabase/poda/aplicar.mjs --project-ref <ref>   (por defecto: Helios)
//   node supabase/poda/aplicar.mjs --marcar <version>    # registra sin correr
//   node supabase/poda/aplicar.mjs --solo 20261003       # solo versiones con ese prefijo
//
// `--solo` existe para que dos sesiones trabajen a la vez sobre la misma base
// sin aplicarse los ficheros a medio escribir la una a la otra: cada una se
// reserva un prefijo de timestamp y aplica solo lo suyo.
//
// Por qué existe: en esta máquina no hay Docker, y `supabase db push` necesita
// la contraseña de la base. `supabase db query --linked` va por la Management
// API y no necesita ninguna de las dos cosas. Este script hace lo mismo que
// `db push`:
//
//   1. Crea `supabase_migrations.schema_migrations` si no existe, con la
//      MISMA forma que usa el CLI (version text PK, statements text[], name
//      text; copiada de Ronda-dev). Así, el día que se use `supabase db push`,
//      el CLI ve estas migraciones como aplicadas y no las repite.
//   2. Lee qué versiones ya están registradas.
//   3. Por cada archivo de `supabase/migrations/` que falte, en orden de
//      timestamp, manda EN UNA SOLA PETICIÓN el archivo + el INSERT de su fila
//      en el historial. La Management API corre la petición entera en una
//      transacción implícita: si algo falla, no queda ni el cambio a medias ni
//      la fila del historial. Por eso es reanudable: se vuelve a correr y
//      empieza por la primera que falta.
//   4. Se para en el primer error y lo imprime.
//
// ⚠️ Lo que NO puede ir en una migración aplicada así (igual que con db push):
//   - `create index concurrently` (no corre dentro de una transacción);
//   - usar en el MISMO archivo un valor de enum recién añadido con
//     `alter type … add value` (va en su propia migración, como en Ronda);
//   - `begin`/`commit` de primer nivel (dentro de un `procedure` sí valen).
// ============================================================================

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { partirSentencias } from '../../scripts/portar-de-ronda.mjs';

const AQUI = path.dirname(fileURLToPath(import.meta.url));
const RAIZ = path.resolve(AQUI, '..', '..');
const MIGRACIONES = path.join(RAIZ, 'supabase', 'migrations');
const REF_HELIOS = 'ahyfbnfsbyzdoyjzjvfb';

const args = process.argv.slice(2);
const opt = (nombre) => {
  const i = args.indexOf(nombre);
  return i === -1 ? undefined : args[i + 1];
};
const ref = opt('--project-ref') ?? process.env.HELIOS_PROJECT_REF ?? REF_HELIOS;
const hasta = opt('--hasta');
const soloListar = args.includes('--pendientes');
const marcar = opt('--marcar');
const solo = opt('--solo');

/**
 * Corre SQL remoto. Devuelve las filas del ÚLTIMO resultado, o lanza.
 *
 * El CLI abre una sesión con un rol temporal (`cli_login_postgres`) y a veces
 * esa conexión falla ("password authentication failed", "failed to connect")
 * sin que el SQL llegue a correr. Eso se reintenta; un error DEL SQL no.
 */
export function consultar(sql, opciones = {}) {
  for (let intento = 1; ; intento++) {
    try {
      return consultarUnaVez(sql, opciones);
    } catch (e) {
      const deConexion = /failed to connect|connection refused|timeout|unexpected status 5\d\d|EOF/i.test(e.message)
        && !/Failed to run sql query/.test(e.message);
      if (!deConexion || intento >= 5) throw e;
      const espera = 3000 * intento;
      console.error(`  (fallo de conexión, reintento ${intento} en ${espera / 1000} s)`);
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, espera);
    }
  }
}

function consultarUnaVez(sql, { projectRef = ref } = {}) {
  const tmp = path.join(os.tmpdir(), `helios-q-${process.pid}-${Date.now()}.sql`);
  fs.writeFileSync(tmp, sql);
  try {
    const out = execFileSync(
      'supabase',
      ['db', 'query', '--linked', '--project-ref', projectRef, '-f', tmp, '-o', 'json'],
      { cwd: RAIZ, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 64 * 1024 * 1024 },
    );
    const ini = out.indexOf('{');
    if (ini === -1) return [];
    return JSON.parse(out.slice(ini)).rows ?? [];
  } catch (e) {
    const detalle = `${e.stdout ?? ''}\n${e.stderr ?? ''}`
      .split('\n')
      .filter((l) => l.trim() && !/new version of Supabase CLI|recommend updating|Initialising login role/.test(l))
      .join('\n');
    const err = new Error(detalle || e.message);
    err.sqlFallido = true;
    throw err;
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}

/** Un literal de texto con dólares, con una etiqueta que no aparezca dentro. */
function literal(texto) {
  let tag = 'm';
  let k = 0;
  while (texto.includes(`$${tag}$`)) tag = `m${++k}`;
  return `$${tag}$${texto}$${tag}$`;
}

const DDL_HISTORIAL = `
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version    text not null primary key,
  statements text[],
  name       text
);`;

function filaHistorial(version, nombre, sql) {
  const sentencias = partirSentencias(sql);
  const arr = sentencias.length
    ? `array[${sentencias.map(literal).join(',\n')}]::text[]`
    : `'{}'::text[]`;
  return `insert into supabase_migrations.schema_migrations (version, name, statements)
values (${literal(version)}, ${literal(nombre)}, ${arr});`;
}

function archivos() {
  return fs
    .readdirSync(MIGRACIONES)
    .filter((f) => /^\d{14}_.*\.sql$/.test(f))
    .sort()
    .map((f) => ({ f, version: f.slice(0, 14), nombre: f.slice(15, -4) }));
}

function main() {
  consultar(DDL_HISTORIAL);
  const hechas = new Set(
    consultar('select version from supabase_migrations.schema_migrations').map((r) => r.version),
  );

  if (marcar) {
    const a = archivos().find((x) => x.version === marcar);
    if (!a) throw new Error(`No hay migración ${marcar}`);
    const sql = fs.readFileSync(path.join(MIGRACIONES, a.f), 'utf8');
    consultar(filaHistorial(a.version, a.nombre, sql));
    console.log(`Registrada sin correr: ${a.f}`);
    return;
  }

  const pendientes = archivos().filter((a) => !hechas.has(a.version) && (!hasta || a.version <= hasta) && (!solo || a.version.startsWith(solo)));
  console.log(`Proyecto ${ref}: ${hechas.size} aplicadas, ${pendientes.length} pendientes`);
  if (soloListar) {
    for (const a of pendientes) console.log(`  · ${a.f}`);
    return;
  }

  for (const [i, a] of pendientes.entries()) {
    const sql = fs.readFileSync(path.join(MIGRACIONES, a.f), 'utf8');
    const t0 = Date.now();
    try {
      consultar(`${sql}\n;\n${filaHistorial(a.version, a.nombre, sql)}`);
    } catch (e) {
      console.error(`✗ ${a.f}\n${e.message}`);
      process.exit(1);
    }
    console.log(`✓ [${i + 1}/${pendientes.length}] ${a.f} (${((Date.now() - t0) / 1000).toFixed(1)} s)`);
  }
  console.log('Todo aplicado.');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}
