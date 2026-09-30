/**
 * Ningún destino apunta a una pestaña o sub-pestaña de Métricas que no
 * existe.
 *
 *   npx tsx src/features/admin/metricas/destinos.test.ts
 *
 * El compilador ya rechaza un enlace tipado con una `vista` o una `sub` que
 * el registro no tiene. Esto cubre lo que el compilador no ve:
 *
 *   1. Ctrl K: cada pestaña y cada sub-pestaña del registro tiene su entrada
 *      («Métricas › Cobros › Calendario»), con su nombre y adónde lleva.
 *   2. Todo lo del catálogo que lleva a Métricas lleva a un sitio que existe
 *      y en la forma que el marco da por buena: sin una clave que se caiga,
 *      sin un nombre viejo que haya que traducir y sin escribir lo que vale
 *      por defecto (la pestaña Semana, la primera sub-pestaña).
 *   3. Las filas de «Semana a semana» y la charla de Inicio, igual.
 *   4. En el código: ningún `vista:`/`sub:` escrito junto a `/admin/metricas`
 *      ni ninguna URL `/admin/metricas?…` escrita a mano nombra una pestaña o
 *      sub-pestaña que no existe (un comentario viejo engaña igual).
 */
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

import { pastillasDeLaCharla } from '@/components/admin/inicio/charla'
import { CATALOGO, PANTALLAS } from '@/features/admin/catalogo'
import { validarBusquedaMetricas } from './busqueda'
import { IDS_PESTANA, definicionDe, idsDeSubpestanas, nombreDelLugar, subpestanasDe } from './pestanas'
import type { IdPestana, Lugar } from './pestanas'
import { GRUPOS_DE_FILAS, busquedaDeDestino } from './semana/filas'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const HOY = '2026-09-26'

/** Lo que acaba en la URL, por orden alfabético y sin las claves vacías. */
function url(o: object): string {
  return JSON.stringify(
    Object.fromEntries(
      Object.entries(o)
        .filter(([, v]) => v !== undefined)
        .sort(([a], [b]) => a.localeCompare(b)),
    ),
  )
}

/**
 * Si una búsqueda de `/admin/metricas` es canónica: el marco la valida y
 * sale igual. Si no, qué cambia.
 *
 * `vista: 'semana'` se tolera escrita: es la pestaña por defecto, el marco
 * la quita sin cambiar de sitio y en un destino se lee mejor que nada.
 */
function problemaDe(search: object | undefined): string | null {
  const { vista, ...resto } = { ...search } as Record<string, unknown>
  const dada = url(vista === 'semana' ? resto : { vista, ...resto })
  const validada = url(validarBusquedaMetricas({ ...search }, HOY))
  return dada === validada ? null : `${dada} → ${validada}`
}

console.log('── 1. Cada sitio del registro está en Ctrl K ──────────────────')
{
  const faltan: string[] = []
  for (const id of IDS_PESTANA) {
    const lugares: Array<{ clave: string; lugar: Lugar; titulo: string }> = [
      { clave: `metricas-${id}`, lugar: { vista: id }, titulo: `Métricas › ${definicionDe(id).titulo}` },
      ...subpestanasDe(id).map((s) => ({
        clave: `metricas-${id}-${s.id}`,
        lugar: { vista: id, sub: s.id } as Lugar,
        titulo: `Métricas › ${nombreDelLugar({ vista: id, sub: s.id } as Lugar)}`,
      })),
    ]
    for (const { clave, lugar, titulo } of lugares) {
      const p = PANTALLAS.find((x) => x.id === clave)
      if (!p) {
        faltan.push(`${clave}: no está`)
        continue
      }
      if (p.titulo !== titulo) faltan.push(`${clave}: se llama «${p.titulo}», no «${titulo}»`)
      if (p.destino.to !== '/admin/metricas') {
        faltan.push(`${clave}: lleva a ${p.destino.to}`)
        continue
      }
      const llega = validarBusquedaMetricas({ ...p.destino.search }, HOY)
      const vista = llega.vista ?? 'semana'
      const sub = 'sub' in llega ? llega.sub : undefined
      const esperada = lugar.sub === idsDeSubpestanas(lugar.vista)[0] ? undefined : lugar.sub
      if (vista !== lugar.vista || sub !== esperada) {
        faltan.push(`${clave}: lleva a ${vista}${sub ? ` › ${sub}` : ''}`)
      }
    }
  }
  comprueba(faltan.length === 0, 'cada pestaña y cada sub-pestaña tiene su pantalla, con su nombre y su destino', faltan.join('; '))

  const deMetricas = PANTALLAS.filter((p) => p.destino.to === '/admin/metricas').map((p) => p.id)
  const sobran = deMetricas.filter(
    (id) =>
      id !== 'metricas' &&
      !IDS_PESTANA.some((v) => id === `metricas-${v}` || subpestanasDe(v).some((s) => id === `metricas-${v}-${s.id}`)),
  )
  comprueba(sobran.length === 0, 'y no hay pantallas de sitios que ya no existen', sobran.join(', '))
}

console.log('\n── 2. Todo lo del catálogo que lleva a Métricas ───────────────')
{
  const mal = CATALOGO.filter((e) => e.destino.to === '/admin/metricas')
    .map((e) => [e.id, problemaDe(e.destino.search)] as const)
    .filter(([, p]) => p !== null)
    .map(([id, p]) => `${id}: ${p}`)
  comprueba(mal.length === 0, 'lleva a un sitio que existe, en su forma canónica', mal.join('; '))
}

console.log('\n── 3. Las filas de Semana a semana y la charla de Inicio ──────')
{
  const mal = GRUPOS_DE_FILAS.flatMap((g) => g.filas)
    .map((f) => {
      const subs = idsDeSubpestanas(f.destino.vista) as ReadonlyArray<string>
      if (f.destino.sub !== undefined && !subs.includes(f.destino.sub)) return `${f.id}: ${f.destino.vista} › ${f.destino.sub}`
      const p = problemaDe(busquedaDeDestino(f.destino, {}))
      return p ? `${f.id}: ${p}` : null
    })
    .filter((x): x is string => x !== null)
  comprueba(mal.length === 0, 'cada fila lleva a un sitio que existe', mal.join('; '))

  const charla = pastillasDeLaCharla({
    pendiente: { estado: 'con-trabajo', tarjetas: [], total: 1, pendientes: 1, principal: null, urgencia: 'warning' },
    mora: { estado: 'listo', datos: { senal: { tone: 'warning', texto: 'Mora' } } },
    cierre: { estado: 'listo', datos: { veredicto: 'cubre' } },
    impago: { estado: 'listo', datos: { pct: 10, senal: undefined } },
  })
  const aMetricas = charla.flatMap((p) => (p.destino?.to === '/admin/metricas' ? [p] : []))
  comprueba(aMetricas.length > 0, 'la charla de Inicio lleva a Métricas (el impago)')
  const malCharla = aMetricas
    .map((p) => (p.destino?.to === '/admin/metricas' ? problemaDe(p.destino.search) : null))
    .filter((x): x is string => x !== null)
  comprueba(malCharla.length === 0, 'y a un sitio que existe', malCharla.join('; '))
}

console.log('\n── 4. En el código ───────────────────────────────────────────')
{
  const src = fileURLToPath(new URL('../../../', import.meta.url))
  const ficheros: string[] = []
  const recorrer = (dir: string) => {
    for (const nombre of readdirSync(dir)) {
      const ruta = join(dir, nombre)
      if (statSync(ruta).isDirectory()) recorrer(ruta)
      else if (/\.(ts|tsx)$/.test(nombre) && !nombre.endsWith('.test.ts') && nombre !== 'routeTree.gen.ts') ficheros.push(ruta)
    }
  }
  recorrer(src)

  const vistas = new Set<string>(IDS_PESTANA)
  const subDe = (v: string) => new Set<string>(vistas.has(v) ? idsDeSubpestanas(v as IdPestana) : [])
  const mal: string[] = []
  for (const ruta of ficheros) {
    const texto = readFileSync(ruta, 'utf8')
    const donde = relative(src, ruta).replace(/\\/g, '/')
    // `traducirEnlaceViejo` nombra los enlaces viejos a propósito: es quien los traduce.
    if (donde === 'features/admin/metricas/busqueda.ts') continue

    // Un enlace tipado: `/admin/metricas` y, poco después, `vista: '…'` (y `sub: '…'`).
    for (const m of texto.matchAll(/\/admin\/metricas['"]/g)) {
      const trozo = texto.slice(m.index, m.index + 260)
      const cierre = trozo.search(/\}\s*\}|\n\s*\n/)
      const busqueda = cierre >= 0 ? trozo.slice(0, cierre) : trozo
      const vista = /vista:\s*'([a-z-]+)'/.exec(busqueda)?.[1]
      if (!vista) continue
      const sub = /sub:\s*'([a-z-]+)'/.exec(busqueda)?.[1]
      if (!vistas.has(vista)) mal.push(`${donde}: vista '${vista}'`)
      else if (sub && !subDe(vista).has(sub)) mal.push(`${donde}: ${vista} › '${sub}'`)
    }
    // Una URL escrita a mano: `/admin/metricas?vista=…&sub=…`.
    for (const m of texto.matchAll(/\/admin\/metricas\?([^\s'"`)]+)/g)) {
      const q = new URLSearchParams(m[1])
      const vista = q.get('vista')
      const sub = q.get('sub')
      if (vista && /^[a-z-]+$/.test(vista) && !vistas.has(vista)) mal.push(`${donde}: ?vista=${vista}`)
      else if (vista && sub && /^[a-z-]+$/.test(sub) && !subDe(vista).has(sub)) mal.push(`${donde}: ?vista=${vista}&sub=${sub}`)
    }
  }
  comprueba(ficheros.length > 100, `se leyó el código (${ficheros.length} ficheros)`)
  comprueba(mal.length === 0, 'ningún enlace ni URL escrita nombra una pestaña o sub-pestaña que no existe', mal.join('; '))
}

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
