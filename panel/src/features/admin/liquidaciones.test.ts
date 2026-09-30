/**
 * Pruebas de los nombres y la tasa de los pagos a locales.
 *
 *   npx tsx src/features/admin/liquidaciones.test.ts
 */
import {
  MOTIVO_DE_LIQUIDACION,
  aBolivares,
  medioConReferencia,
  nombreDelMedio,
  tasaDelDia,
} from './liquidaciones'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

comprueba(MOTIVO_DE_LIQUIDACION.scheduled_installment === 'Cuota por fecha', 'el nombre de una liquidación')
comprueba(nombreDelMedio('pago_movil') === 'Pago Móvil', 'el nombre de un medio')
comprueba(nombreDelMedio('cripto') === 'cripto', 'un medio desconocido sale tal cual')
comprueba(!medioConReferencia('efectivo'), 'el efectivo no lleva referencia de banco')
comprueba(medioConReferencia('pago_movil'), 'el Pago Móvil sí lleva referencia')

const historial = [
  { effectiveDate: '2026-09-22', rate: 980 },
  { effectiveDate: '2026-09-19', rate: 970 },
  { effectiveDate: '2026-09-18', rate: 965 },
]

comprueba(tasaDelDia(historial, '2026-09-19') === 970, 'la tasa publicada ese día')
comprueba(tasaDelDia(historial, '2026-09-21') === 970, 'el domingo vale la del viernes', String(tasaDelDia(historial, '2026-09-21')))
comprueba(tasaDelDia(historial, '2026-09-25') === 980, 'después de la última, la última')
comprueba(tasaDelDia(historial, '2026-09-01') === null, 'antes de la primera no hay tasa')
comprueba(tasaDelDia([], '2026-09-19') === null, 'sin historial no hay tasa')

comprueba(aBolivares(12.345, 975.5) === 12042.55, 'dólares a bolívares al céntimo', String(aBolivares(12.345, 975.5)))

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
