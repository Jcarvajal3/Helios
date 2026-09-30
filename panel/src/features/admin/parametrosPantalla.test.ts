/**
 * Pruebas de la gracia única en Ajustes › Parámetros.
 *
 *   npx tsx src/features/admin/parametrosPantalla.test.ts
 *
 * Desde el 27-09 hay UNA gracia: «a tiempo», el impago de cada cuota y el
 * cargo por atraso usan los mismos días (`late_fee_grace_days`). El parámetro
 * viejo de «a tiempo» sigue en la base, pero no se enseña ni se puede cambiar
 * por separado.
 */
import type { Parametro } from './parametros'
import { CLAVES_SIN_USO, QUE_DECIDE, agruparParametros, nombreDelParametro } from './parametrosPantalla'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function fila(key: string, label: string): Parametro {
  return {
    key,
    value: key === 'on_time_grace_days' ? 2 : 3,
    effectiveFrom: '2026-08-01',
    note: null,
    nextValue: null,
    nextFrom: null,
    history: [],
    label,
    unit: 'días',
    grupo: 'producto',
  }
}

console.log('── Una sola gracia ───────────────────────────────────────────')
const grupos = agruparParametros([
  fila('late_fee_grace_days', 'Días antes del cargo'),
  fila('on_time_grace_days', 'Días de reintento'),
  fila('late_fee_usd', 'Cargo por atraso'),
])
const claves = grupos.flatMap((g) => g.filas.map((f) => f.key))
comprueba(
  claves.join(',') === 'late_fee_grace_days,late_fee_usd',
  'la gracia vieja de «a tiempo» no sale en la pantalla (ni se puede cambiar)',
  claves.join(','),
)
comprueba(CLAVES_SIN_USO.has('on_time_grace_days'), 'la clave vieja está marcada como sin uso')
comprueba(
  agruparParametros([fila('on_time_grace_days', 'Días de reintento')]).length === 0,
  'un grupo que solo tenía la clave vieja no sale vacío',
)
comprueba(
  nombreDelParametro(fila('late_fee_grace_days', 'Días antes del cargo')) === 'Días de gracia',
  'la gracia se llama «Días de gracia» aunque la base diga otra cosa',
)
const explica = QUE_DECIDE.late_fee_grace_days ?? ''
comprueba(
  explica.includes('cargo') && explica.includes('a tiempo') && explica.includes('impago'),
  'su explicación dice las tres cosas que decide',
  explica,
)

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
