/**
 * Pruebas del mapa de pantallas que lee la función del asistente.
 *
 *   npx tsx src/features/admin/asistente/mapa.test.ts
 *
 * Lo que no puede pasar: que el asistente enlace una pantalla que el panel no
 * acepta, que una cifra apunte a una pantalla que no está en el mapa, o que
 * el archivo no tenga la forma que lee `leerMapa` en la función.
 */
import { CATALOGO, PANTALLAS } from '@/features/admin/catalogo'
import { rutaConocida } from './enlaces'
import { construirMapa } from './mapa'
import { comoFila } from '@/lib/json'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok || !detalle ? '' : ` — ${detalle}`}`)
}

const mapa = construirMapa(CATALOGO)

comprueba(comoFila(JSON.parse(JSON.stringify(mapa))).regenerar === false, 'el generado no se marca como provisional')
comprueba(mapa.pantallas.length === PANTALLAS.length, 'están todas las pantallas del catálogo', `${mapa.pantallas.length}`)
comprueba(
  mapa.cifras.length === CATALOGO.filter((e) => e.tipo === 'cifra').length,
  'están todas las cifras',
)

const sinRuta = mapa.pantallas.filter((p) => !p.ruta.startsWith('/admin') || !rutaConocida(p.ruta))
comprueba(sinRuta.length === 0, 'toda pantalla del mapa la acepta el panel como enlace', sinRuta.map((p) => p.ruta).join(', '))

const ids = new Set(mapa.pantallas.map((p) => p.id))
const sinPantalla = mapa.cifras.filter((c) => c.pantalla === null || !ids.has(c.pantalla))
comprueba(sinPantalla.length === 0, 'toda cifra apunta a una pantalla del mapa', sinPantalla.map((c) => c.id).join(', '))

comprueba(mapa.cifras.every((c) => c.rpc.trim() !== '' && c.que.trim() !== ''), 'toda cifra dice qué es y de qué RPC sale')

const searchMal = mapa.pantallas.filter((p) =>
  Object.values(p.search).some((v) => v !== null && (!Array.isArray(v) || v.length === 0)),
)
comprueba(searchMal.length === 0, 'cada parámetro de search lleva su lista de valores', searchMal.map((p) => p.id).join(', '))

const cobranza = mapa.pantallas.find((p) => p.ruta === '/admin/cobranza')
comprueba(
  (cobranza?.search.tramo ?? []).includes('sin_contactar'),
  'los filtros que el catálogo ya enlaza salen como valores admitidos',
  JSON.stringify(cobranza?.search),
)

const UUID = '0b6f6c1e-3d7a-4f3e-9d2a-1c2b3a4d5e6f'
comprueba(
  mapa.fichas.length === 4 &&
    mapa.fichas.every((f) => f.id !== '' && f.titulo !== '' && rutaConocida(f.ruta.replace('$id', UUID))),
  'las fichas llevan id, título y una ruta que el panel acepta',
)

comprueba(
  JSON.stringify(construirMapa(CATALOGO)) === JSON.stringify(mapa),
  'dos generaciones seguidas dan el mismo archivo',
)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallos.`)
if (fallos > 0) process.exit(1)
