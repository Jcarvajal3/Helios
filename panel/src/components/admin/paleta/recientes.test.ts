/**
 * Pruebas de Recientes.
 *
 *   npx tsx src/components/admin/paleta/recientes.test.ts
 *
 * Lo guardado en el navegador puede venir de otra versión del panel o estar
 * roto: se lee con desconfianza y nunca tumba la paleta.
 */
import {
  MAX_RECIENTES,
  anadirReciente,
  cargarRecientes,
  guardarRecientes,
  leerRecientes,
} from './recientes'
import type { Reciente } from './recientes'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const UUID = '0b6f6c1e-3d7a-4f3e-9d2a-1c2b3a4d5e6f'
const ana: Reciente = { tipo: 'persona', id: UUID, titulo: 'Ana Rivas', detalle: '0414-1234567' }
const dinero: Reciente = { tipo: 'catalogo', id: 'dinero' }

console.log('── Añadir ────────────────────────────────────────────────────')
igual(anadirReciente([], dinero), [dinero], 'a una lista vacía')
igual(anadirReciente([dinero, ana], ana), [ana, dinero], 'lo repetido sube al principio y no se duplica')
{
  const llena = Array.from({ length: MAX_RECIENTES }, (_, i): Reciente => ({ tipo: 'catalogo', id: `p${i}` }))
  const tras = anadirReciente(llena, dinero)
  igual(tras.length, MAX_RECIENTES, `nunca más de ${MAX_RECIENTES}`)
  igual(tras[0], dinero, 'lo nuevo, primero')
  igual(tras.some((r) => r.id === `p${MAX_RECIENTES - 1}`), false, 'se cae el más viejo')
}

console.log('\n── Leer lo guardado ──────────────────────────────────────────')
igual(leerRecientes([dinero, ana]), [dinero, ana], 'lo válido pasa tal cual')
igual(leerRecientes('basura'), [], 'lo que no es una lista, vacío')
igual(leerRecientes(null), [], 'null, vacío')
igual(
  leerRecientes([
    { tipo: 'persona', id: 'no-es-un-uuid', titulo: 'X', detalle: '' },
    { tipo: 'persona', id: UUID, detalle: 'sin título' },
    { tipo: 'nave', id: UUID, titulo: 'X', detalle: '' },
    { tipo: 'catalogo' },
    42,
    dinero,
  ]),
  [dinero],
  'se descarta lo roto y se queda lo bueno',
)
igual(
  leerRecientes([{ tipo: 'persona', id: UUID.toUpperCase(), titulo: 'Ana', detalle: 7 }]),
  [{ tipo: 'persona', id: UUID, titulo: 'Ana', detalle: '7' }],
  'el id se normaliza y un detalle numérico se lee como texto',
)
igual(leerRecientes([dinero, dinero, ana]), [dinero, ana], 'sin repetidos')

console.log('\n── Sin almacenamiento no revienta ────────────────────────────')
let reviento = false
try {
  guardarRecientes([dinero])
  igual(cargarRecientes(), [], 'en Node no hay localStorage: se lee vacío')
} catch {
  reviento = true
}
igual(reviento, false, 'guardar y cargar sin localStorage no lanzan')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
