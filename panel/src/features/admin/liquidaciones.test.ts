/**
 * Pruebas de los nombres y la tasa de los pagos a locales.
 *
 *   npx tsx src/features/admin/liquidaciones.test.ts
 */
import {
  MOTIVO_DE_LIQUIDACION,
  aBolivares,
  bolivaresPorMoneda,
  medioConReferencia,
  monedasDe,
  nombreDelMedio,
  partesPorMoneda,
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

// ── Lo que va en cada moneda ──────────────────────────────────────────────
// Una mitad de una consulta de $100 (en dólares) y otra de €100 (en euros,
// $112,63 al registrarla), y la comisión de la secretaria en dólares.
const lineas = [
  { id: 'b', dueDate: '2026-10-09', currency: 'EUR' as const, amountUsd: 56.32, amountCur: 50, pendingUsd: 56.32, pendingCur: 50 },
  { id: 'a', dueDate: '2026-10-08', currency: 'USD' as const, amountUsd: 50, amountCur: 50, pendingUsd: 50, pendingCur: 50 },
  { id: 'c', dueDate: '2026-10-10', currency: 'USD' as const, amountUsd: 5, amountCur: 5, pendingUsd: 5, pendingCur: 5 },
]
const todo = partesPorMoneda(lineas, 111.32)
comprueba(todo.USD === 55 && todo.EUR === 50, 'todo lo marcado: cada parte en su moneda', JSON.stringify(todo))
const parcial = partesPorMoneda(lineas, 78.16)
comprueba(
  parcial.USD === 50 && parcial.EUR === 25,
  'a medias: la más antigua entera y la siguiente en proporción',
  JSON.stringify(parcial),
)
const aMedias = partesPorMoneda(
  [{ id: 'x', dueDate: '2026-10-08', currency: 'EUR', amountUsd: 56.32, amountCur: 50, pendingUsd: 28.16, pendingCur: 25 }],
  28.16,
)
comprueba(aMedias.EUR === 25, 'una ya pagada a medias aporta lo que le falta en su moneda', JSON.stringify(aMedias))
comprueba(monedasDe(lineas).join() === 'USD,EUR', 'las monedas de lo marcado, dólares primero')
comprueba(monedasDe([lineas[0]]).join() === 'EUR', 'solo euros')

comprueba(
  bolivaresPorMoneda({ USD: 55, EUR: 50 }, { USD: 200, EUR: 230.5 }) === 22525,
  'los bolívares: cada parte a la tasa de su moneda',
  String(bolivaresPorMoneda({ USD: 55, EUR: 50 }, { USD: 200, EUR: 230.5 })),
)
comprueba(bolivaresPorMoneda({ USD: 55, EUR: 50 }, { USD: 200, EUR: null }) === null, 'sin la tasa del euro, no se inventa')
comprueba(bolivaresPorMoneda({ USD: 55, EUR: 0 }, { USD: 200, EUR: null }) === 11000, 'sin euros no hace falta su tasa')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
