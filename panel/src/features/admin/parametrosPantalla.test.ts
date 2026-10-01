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
import {
  CLAVES_SIN_USO,
  QUE_DECIDE,
  agruparParametros,
  formatValorParametro,
  leerValorParametro,
  nombreDelParametro,
} from './parametrosPantalla'

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

console.log('\n── Los parámetros de Helios (contrato §3) ────────────────────')
{
  const de = (key: string, unit: string | null, grupo: Parametro['grupo'] = null, label: string | null = null): Parametro => ({
    ...fila(key, ''),
    label,
    unit,
    grupo,
  })
  const deHelios = agruparParametros([
    de('staff_commission_usd', '$', 'producto'),
    de('min_charge_usd', '$'),
    de('payment_four_eyes', null),
    de('alert_staff_share_pct', '%', 'umbral'),
    de('eligibility_lookups_per_staff_day', 'consultas'),
    de('late_fee_usd', '$', 'producto'),
  ])
  comprueba(
    deHelios.map((g) => g.grupo).join(',') === 'producto,financiamiento,control,alertas',
    'comisión y mínimo, controles y alertas: cada uno en su grupo, aunque la base diga otro',
    deHelios.map((g) => g.grupo).join(','),
  )
  comprueba(
    deHelios[1]?.filas.map((f) => f.key).join(',') === 'staff_commission_usd,min_charge_usd',
    'los financiamientos llevan la comisión y el mínimo',
  )
  comprueba(formatValorParametro(0.5, '$', 'staff_commission_usd') === '$0,50', 'la comisión en dólares', formatValorParametro(0.5, '$', 'staff_commission_usd'))
  comprueba(formatValorParametro(3000, null, 'alert_merchant_exposure_usd') === '$3.000,00', 'un _usd sin unidad también es dólares', formatValorParametro(3000, null, 'alert_merchant_exposure_usd'))
  comprueba(formatValorParametro(1, null, 'payment_four_eyes') === 'Activado', 'el doble control es un interruptor')
  comprueba(formatValorParametro(0, null, 'payment_four_eyes') === 'Apagado', 'apagado es 0')
  comprueba(!leerValorParametro('2', null, 'payment_four_eyes').ok, 'un interruptor no acepta 2')
  comprueba(leerValorParametro('1', null, 'payment_four_eyes').ok, 'un interruptor acepta 1')
  comprueba(!leerValorParametro('2,5', 'consultas').ok, 'las consultas se cuentan enteras')
  comprueba(formatValorParametro(1, 'consultas') === '1 consulta', 'en singular', formatValorParametro(1, 'consultas'))
  comprueba(
    nombreDelParametro(de('payment_four_eyes', null)) === 'Doble control de pagos',
    'sin rótulo en la base, el del panel y no la clave',
  )
  comprueba(nombreDelParametro(de('min_charge_usd', '$', null, 'Mínimo')) === 'Mínimo', 'con rótulo en la base, el de la base')
  comprueba((QUE_DECIDE.staff_commission_usd ?? '').includes('lunes'), 'la comisión dice cuándo se paga')
}

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
