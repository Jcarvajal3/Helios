#!/usr/bin/env node
// ============================================================================
// Helios — Porta SQL de Ronda al vocabulario de Helios
//
//   node scripts/portar-de-ronda.mjs <entrada.sql> <salida.sql>
//   node scripts/portar-de-ronda.mjs --dir <carpeta-entrada> <carpeta-salida>
//   node scripts/portar-de-ronda.mjs --informe <entrada.sql|carpeta>
//
// El primer modo porta un archivo; el segundo, todos los `*.sql` de una
// carpeta (mismo nombre de archivo: el timestamp de Ronda se conserva). El
// tercero no escribe nada: lista cada `ronda`/`Ronda` que queda, con su
// contexto (código, texto, comentario), para revisar a mano lo que las reglas
// dejan pasar.
//
// Es DETERMINISTA: el mismo archivo de Ronda produce siempre el mismo archivo
// de Helios, así que un arreglo futuro de Ronda se porta corriendo esto sobre
// su migración y revisando el diff (ver supabase/README.md).
//
// ── Cómo lee el SQL ─────────────────────────────────────────────────────────
//
// Un lexer mínimo de Postgres separa el archivo en trozos: código, texto entre
// comillas simples ('…', E'…'), identificadores entre comillas dobles ("…"),
// comentarios (-- y /* */ anidados) y cuerpos entre dólares ($$…$$, $tag$…$tag$).
// Los cuerpos entre dólares se vuelven a leer como SQL, porque casi siempre
// son el cuerpo de una función (plpgsql o sql): así sus propios comentarios y
// textos se distinguen igual que fuera. `$1`, `$2` (parámetros) no abren un
// cuerpo.
//
// ── Las reglas, en orden ────────────────────────────────────────────────────
//
// R1. Prefijo de marca `ronda_` → `helios_`, EN TODAS PARTES (código, textos,
//     identificadores entre comillas y también comentarios). Solo cuando
//     `ronda_` empieza una palabra: `x_ronda_y` no se toca. Sensible a
//     mayúsculas: `RONDA_TESTS_REMOTE` o `Ronda_` no se tocan.
//       public.ronda_assign_debt(...)          → public.helios_assign_debt(...)
//       cron.schedule('ronda_sync_fx_rate', …) → cron.schedule('helios_sync_fx_rate', …)
//       'select public.ronda_snapshot_cash_forecast()' (comando de cron) → idem
//     En comentarios también, para que un `-- ver ronda_spend_block` no apunte
//     a una función que en Helios no existe.
//
// R2. GUC propias `ronda.<algo>` → `helios.<algo>` en código y textos (p. ej.
//     `current_setting('ronda.rt_grupos', true)`). Solo si tras el punto viene
//     una letra o `_`: "…la próxima ronda. Es…" no es una GUC.
//
// R3. La marca como palabra en TEXTOS y código (nunca en comentarios):
//     `Ronda` → `Helios` y `RONDA` → `HELIOS`, como palabra completa o al
//     empezar una palabra compuesta (`RondaDemo` → `HeliosDemo`). Son los
//     mensajes de error, textos de plantillas, `comment on … is '…'`, el
//     User-Agent de la ingesta de la tasa, etc.
//     NO toca `ronda` en minúscula: en español es un sustantivo ("la próxima
//     ronda", "cinco rondas") y solo aparece así en textos de grupos, que en
//     Helios se podan. Tampoco toca URLs de tiendas (`app.ronda`), que viven
//     en `app_release`, también podada.
//
// R4. Los comentarios conservan la prosa de Ronda ("Ronda cobra…", "Ronda-kyc",
//     rutas de Ronda-panel…): son historia de por qué se hizo algo, y
//     reescribirlos haría imposible comparar con el original. Solo R1 los toca.
//
// No hay más reglas a propósito: los nombres de dominio (`profiles`,
// `merchants`, `charges`, sufijos `_usd`…) se conservan (docs/00 §3.3), y los
// buckets, esquemas y roles de Ronda no llevan la marca (`payment-receipts`,
// `ledger`, `asistente_lector`…), así que no necesitan regla.
//
// Lo que las reglas no pueden decidir (datos de Ronda sembrados por una
// migración, objetos solo de la app) se resuelve en la poda
// (`supabase/migrations/20261001*_la_poda_*.sql`), no aquí, para que este
// script siga siendo un renombrado mecánico y reutilizable.
// ============================================================================

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// ── Lexer ───────────────────────────────────────────────────────────────────

const ES_IDENT = /[A-Za-z0-9_$\u0080-￿]/;

/**
 * Parte un texto SQL en trozos { tipo, texto } con tipo en:
 * 'codigo' | 'texto' | 'ident' | 'comentario' | 'dolar'.
 * Para 'dolar' añade { abre, cuerpo, cierra }. Nunca falla: una comilla sin
 * cerrar se trata como texto hasta el final.
 */
export function lexear(sql) {
  const trozos = [];
  let i = 0;
  let codigo = '';
  const n = sql.length;
  const empujarCodigo = () => {
    if (codigo) trozos.push({ tipo: 'codigo', texto: codigo });
    codigo = '';
  };

  while (i < n) {
    const c = sql[i];
    const s = sql[i + 1];

    // -- comentario de línea
    if (c === '-' && s === '-') {
      empujarCodigo();
      let j = sql.indexOf('\n', i);
      if (j === -1) j = n;
      trozos.push({ tipo: 'comentario', texto: sql.slice(i, j) });
      i = j;
      continue;
    }

    // /* comentario */ (anidable en Postgres)
    if (c === '/' && s === '*') {
      empujarCodigo();
      let prof = 0;
      let j = i;
      while (j < n) {
        if (sql[j] === '/' && sql[j + 1] === '*') { prof++; j += 2; continue; }
        if (sql[j] === '*' && sql[j + 1] === '/') { prof--; j += 2; if (prof === 0) break; continue; }
        j++;
      }
      trozos.push({ tipo: 'comentario', texto: sql.slice(i, j) });
      i = j;
      continue;
    }

    // 'texto' o E'texto'
    if (c === "'") {
      const escape = /[eE]$/.test(codigo) && !ES_IDENT.test(codigo.slice(-2, -1) || ' ');
      empujarCodigo();
      let j = i + 1;
      while (j < n) {
        if (escape && sql[j] === '\\') { j += 2; continue; }
        if (sql[j] === "'") {
          if (sql[j + 1] === "'") { j += 2; continue; }
          j++;
          break;
        }
        j++;
      }
      if (j > n) j = n;
      trozos.push({ tipo: 'texto', texto: sql.slice(i, j) });
      i = j;
      continue;
    }

    // "identificador"
    if (c === '"') {
      empujarCodigo();
      let j = i + 1;
      while (j < n) {
        if (sql[j] === '"') {
          if (sql[j + 1] === '"') { j += 2; continue; }
          j++;
          break;
        }
        j++;
      }
      trozos.push({ tipo: 'ident', texto: sql.slice(i, j) });
      i = j;
      continue;
    }

    // $tag$ cuerpo $tag$ — no si es $1 ni si el $ sigue a un identificador
    if (c === '$' && !ES_IDENT.test(codigo.slice(-1) || ' ')) {
      const m = /^\$([A-Za-z_][A-Za-z0-9_]*)?\$/.exec(sql.slice(i, i + 80));
      if (m) {
        const abre = m[0];
        const fin = sql.indexOf(abre, i + abre.length);
        if (fin !== -1) {
          empujarCodigo();
          const cuerpo = sql.slice(i + abre.length, fin);
          trozos.push({ tipo: 'dolar', abre, cuerpo, cierra: abre, texto: abre + cuerpo + abre });
          i = fin + abre.length;
          continue;
        }
      }
    }

    codigo += c;
    i++;
  }
  empujarCodigo();
  return trozos;
}

// ── Reglas ──────────────────────────────────────────────────────────────────

// R1: `ronda_` al empezar palabra (lookbehind: nada de letra, dígito, _ ni $).
const R1 = /(?<![A-Za-z0-9_$])ronda_/g;
// R2: GUC `ronda.algo`.
const R2 = /(?<![A-Za-z0-9_$.])ronda\.(?=[a-z_])/g;
// R3: la marca como palabra (o al empezar un compuesto en CamelCase).
const R3a = /(?<![A-Za-z0-9_$À-ɏ])Ronda(?![a-z0-9_À-ɏ])/g;
const R3b = /(?<![A-Za-z0-9_$À-ɏ])RONDA(?![A-Za-z0-9_À-ɏ])/g;

function reglasCodigoOTexto(t) {
  return t
    .replace(R1, 'helios_')
    .replace(R2, 'helios.')
    .replace(R3a, 'Helios')
    .replace(R3b, 'HELIOS');
}

function reglasComentario(t) {
  return t.replace(R1, 'helios_');
}

/** Aplica R1–R4 a un texto SQL. */
export function portar(sql) {
  let out = '';
  for (const t of lexear(sql)) {
    switch (t.tipo) {
      case 'comentario':
        out += reglasComentario(t.texto);
        break;
      case 'dolar':
        out += t.abre + portar(t.cuerpo) + t.cierra;
        break;
      default:
        out += reglasCodigoOTexto(t.texto);
    }
  }
  return out;
}

/**
 * Parte un archivo en sentencias de primer nivel (por `;` fuera de textos,
 * comentarios y cuerpos entre dólares). Es lo que se guarda en
 * `supabase_migrations.schema_migrations.statements`, como hace el CLI.
 */
export function partirSentencias(sql) {
  const sentencias = [];
  let actual = '';
  for (const t of lexear(sql)) {
    if (t.tipo !== 'codigo') { actual += t.texto; continue; }
    const partes = t.texto.split(';');
    for (let k = 0; k < partes.length; k++) {
      actual += partes[k];
      if (k < partes.length - 1) {
        const limpia = quitarComentarios(actual).trim();
        if (limpia) sentencias.push(actual.trim());
        actual = '';
      }
    }
  }
  if (quitarComentarios(actual).trim()) sentencias.push(actual.trim());
  return sentencias;
}

function quitarComentarios(sql) {
  return lexear(sql).filter((t) => t.tipo !== 'comentario').map((t) => t.texto).join('');
}

// ── Informe ─────────────────────────────────────────────────────────────────

function informe(sql, nombre) {
  const filas = [];
  const visitar = (texto, desplazamiento) => {
    let pos = desplazamiento;
    for (const t of lexear(texto)) {
      if (t.tipo === 'dolar') {
        visitar(t.cuerpo, pos + t.abre.length);
      } else {
        const re = /ronda/gi;
        let m;
        while ((m = re.exec(t.texto))) {
          const abs = pos + m.index;
          const linea = sql.slice(0, abs).split('\n').length;
          const lin = sql.split('\n')[linea - 1].trim().slice(0, 140);
          filas.push(`${nombre}:${linea}\t[${t.tipo}]\t${lin}`);
        }
      }
      pos += t.texto.length;
    }
  };
  visitar(sql, 0);
  return filas;
}

// ── CLI ─────────────────────────────────────────────────────────────────────

function main(argv) {
  const [a, b, c] = argv;
  if (a === '--dir') {
    if (!b || !c) uso();
    fs.mkdirSync(c, { recursive: true });
    const archivos = fs.readdirSync(b).filter((f) => f.endsWith('.sql')).sort();
    for (const f of archivos) {
      const entrada = fs.readFileSync(path.join(b, f), 'utf8');
      fs.writeFileSync(path.join(c, f), portar(entrada));
    }
    console.log(`Portados ${archivos.length} archivos de ${b} a ${c}`);
    return;
  }
  if (a === '--informe') {
    if (!b) uso();
    const st = fs.statSync(b);
    const archivos = st.isDirectory()
      ? fs.readdirSync(b).filter((f) => f.endsWith('.sql')).sort().map((f) => path.join(b, f))
      : [b];
    for (const f of archivos) {
      const filas = informe(fs.readFileSync(f, 'utf8'), path.basename(f));
      if (filas.length) console.log(filas.join('\n'));
    }
    return;
  }
  if (!a || !b) uso();
  fs.writeFileSync(b, portar(fs.readFileSync(a, 'utf8')));
}

function uso() {
  console.error(
    'Uso:\n' +
      '  node scripts/portar-de-ronda.mjs <entrada.sql> <salida.sql>\n' +
      '  node scripts/portar-de-ronda.mjs --dir <carpeta-entrada> <carpeta-salida>\n' +
      '  node scripts/portar-de-ronda.mjs --informe <entrada.sql|carpeta>',
  );
  process.exit(2);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2));
}
