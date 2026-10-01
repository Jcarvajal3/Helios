#!/usr/bin/env node
// ============================================================================
// Helios — ¿Lo que llama el panel existe en la base, con esos parámetros?
//
//   node scripts/verificar-contrato.mjs            # contra Helios
//   node scripts/verificar-contrato.mjs --project-ref <ref>
//
// Lee todas las llamadas RPC de panel/src (`supabase.rpc('x', {…})` y
// `llamarRpc('x', {…})`, también con el nombre en una constante del mismo
// fichero) y las compara con `pg_proc` del proyecto remoto:
//
//   · la función existe en `public`;
//   · cada clave que manda el panel es un parámetro de la función;
//   · no falta ningún parámetro obligatorio (sin default).
//
// Con sobrecargas, basta con que una encaje. Si el objeto de argumentos usa
// `...spread` o no es un literal, solo se comprueba que exista. Sale con 1 si
// algo no cuadra, así que sirve como paso de CI.
//
// Existe porque el panel y la base se construyeron en paralelo contra
// docs/01-CONTRATO-RPC.md: tipos y tests de cada lado pasan aunque el otro
// espere otra firma. Esto es lo que lo cruza.
// ============================================================================

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const RAIZ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const SRC = path.join(RAIZ, 'panel', 'src')
const args = process.argv.slice(2)
const i = args.indexOf('--project-ref')
const REF = i === -1 ? 'ahyfbnfsbyzdoyjzjvfb' : args[i + 1]

// ── 1. Las llamadas del panel ───────────────────────────────────────────────

function ficheros(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) return ficheros(p)
    return /\.(ts|tsx)$/.test(e.name) && !/\.test\.ts$/.test(e.name) && !e.name.endsWith('.gen.ts') ? [p] : []
  })
}

/** El texto entre la llave que abre en `desde` y la que la cierra. */
function bloque(texto, desde) {
  let nivel = 0
  for (let k = desde; k < texto.length; k++) {
    const c = texto[k]
    if (c === "'" || c === '"' || c === '`') {
      // Salta cadenas para que una llave dentro de un texto no cuente.
      const cierre = texto.indexOf(c, k + 1)
      if (cierre === -1) return null
      k = cierre
      continue
    }
    if (c === '{') nivel++
    else if (c === '}') {
      nivel--
      if (nivel === 0) return texto.slice(desde + 1, k)
    }
  }
  return null
}

/** Las claves de primer nivel de un literal de objeto: `p_x: …` o `p_x,`. */
function claves(cuerpo) {
  let nivel = 0
  let actual = ''
  const trozos = []
  for (const c of cuerpo) {
    if ('{[('.includes(c)) nivel++
    if ('}])'.includes(c)) nivel--
    if (c === ',' && nivel === 0) {
      trozos.push(actual)
      actual = ''
    } else actual += c
  }
  trozos.push(actual)
  const out = []
  let spread = false
  for (const t of trozos.map((x) => x.trim()).filter(Boolean)) {
    if (t.startsWith('...')) {
      spread = true
      continue
    }
    const m = /^([A-Za-z_$][\w$]*)\s*(:|$)/.exec(t)
    if (m) out.push(m[1])
  }
  return { claves: out, spread }
}

const llamadas = []
for (const f of ficheros(SRC)) {
  const texto = fs.readFileSync(f, 'utf8')
  const constantes = new Map()
  for (const m of texto.matchAll(/const\s+([A-Z_][A-Z0-9_]*)\s*=\s*'([a-z_][a-z0-9_]*)'/g)) constantes.set(m[1], m[2])

  const re = /(?:\.rpc|llamarRpc)\s*(?:<[^>()]*>)?\(\s*(?:'([a-z_][a-z0-9_]*)'|([A-Za-z_][\w]*))\s*(,)?/g
  for (const m of texto.matchAll(re)) {
    const nombre = m[1] ?? constantes.get(m[2])
    if (!nombre) continue // nombre dinámico (p. ej. `llamarRpc` por dentro)
    const linea = texto.slice(0, m.index).split('\n').length
    let args = { claves: [], spread: false, literal: true }
    if (m[3]) {
      const resto = texto.slice(m.index + m[0].length)
      const salto = resto.search(/\S/)
      if (resto[salto] === '{') {
        const cuerpo = bloque(resto, salto)
        args = cuerpo === null ? { claves: [], spread: true, literal: false } : { ...claves(cuerpo), literal: true }
      } else {
        args = { claves: [], spread: true, literal: false }
      }
    }
    llamadas.push({ nombre, fichero: path.relative(RAIZ, f).replaceAll('\\', '/'), linea, ...args })
  }
}

// ── 2. Las funciones de la base ─────────────────────────────────────────────

const SQL = `
select p.proname as nombre,
       coalesce(p.proargnames, '{}') as argnames,
       coalesce(p.proargmodes::text[], '{}') as argmodes,
       p.pronargs as nargs,
       p.pronargdefaults as ndefaults
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'`

const tmp = path.join(os.tmpdir(), `helios-contrato-${process.pid}.sql`)
fs.writeFileSync(tmp, SQL)
let filas
try {
  const salida = execFileSync('supabase', ['db', 'query', '--linked', '--project-ref', REF, '-f', tmp, '-o', 'json'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    shell: process.platform === 'win32',
    maxBuffer: 64 * 1024 * 1024,
  })
  const json = JSON.parse(salida.slice(salida.indexOf('{')))
  filas = json.rows ?? json
} finally {
  fs.rmSync(tmp, { force: true })
}

const funciones = new Map()
for (const f of filas) {
  // Solo los parámetros de entrada: modo i (in), b (inout) o v (variadic); sin modos, todos.
  const nombres = f.argnames
  const modos = f.argmodes
  const entrada = modos.length ? nombres.filter((_, k) => ['i', 'b', 'v'].includes(modos[k])) : nombres.slice(0, f.nargs)
  const obligatorios = entrada.slice(0, f.nargs - f.ndefaults)
  const lista = funciones.get(f.nombre) ?? []
  lista.push({ entrada, obligatorios })
  funciones.set(f.nombre, lista)
}

// ── 3. Cruce ────────────────────────────────────────────────────────────────

const problemas = []
for (const c of llamadas) {
  const sobrecargas = funciones.get(c.nombre)
  const donde = `${c.fichero}:${c.linea}`
  if (!sobrecargas) {
    problemas.push(`${donde}  ${c.nombre}: no existe en la base`)
    continue
  }
  if (!c.literal || c.spread) continue
  const fallos = sobrecargas.map((s) => {
    const sobran = c.claves.filter((k) => !s.entrada.includes(k))
    const faltan = s.obligatorios.filter((k) => !c.claves.includes(k))
    return { sobran, faltan }
  })
  if (fallos.some((x) => x.sobran.length === 0 && x.faltan.length === 0)) continue
  const mejor = fallos.sort((a, b) => a.sobran.length + a.faltan.length - (b.sobran.length + b.faltan.length))[0]
  const partes = []
  if (mejor.sobran.length) partes.push(`la base no tiene ${mejor.sobran.join(', ')}`)
  if (mejor.faltan.length) partes.push(`falta ${mejor.faltan.join(', ')}`)
  problemas.push(`${donde}  ${c.nombre}: ${partes.join('; ')}`)
}

const unicas = new Set(llamadas.map((c) => c.nombre)).size
console.log(`${llamadas.length} llamadas del panel a ${unicas} RPC, contra ${REF}.`)
if (problemas.length === 0) {
  console.log('Todo cuadra.')
} else {
  console.log(`\n${problemas.length} no cuadran:\n`)
  for (const p of problemas) console.log('  ✗ ' + p)
  process.exit(1)
}
