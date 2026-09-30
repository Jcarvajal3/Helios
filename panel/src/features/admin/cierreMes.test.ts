/**
 * Pruebas del cierre de mes y de lo devengado.
 *
 *   npx tsx src/features/admin/cierreMes.test.ts
 *
 * Un punto marcado «hecho» sin estarlo es el peor fallo de esta lista: el mes
 * se da por cerrado con un agujero dentro.
 */
import type { AccountingExport } from './ajustes'
import {
  comoMes,
  mesAnteriorA,
  nombreDelMes,
  puntoAbonos,
  puntoBanco,
  puntoExtracto,
  puntoLibro,
  puntoLocales,
  ultimoDia,
} from './cierreMes'
import { descuadreDelLibro, devengadoDelMes } from './contabilidad'
import { diaOperativo } from '@/components/ui'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

console.log('── El mes ───────────────────────────────────────────────────')
comprueba(comoMes('2026-09') === '2026-09' && comoMes('2026-13') === undefined && comoMes(202609) === undefined, 'valida el mes')
comprueba(mesAnteriorA('2026-01') === '2025-12', 'el anterior a enero es diciembre')
comprueba(ultimoDia('2028-02') === '2028-02-29' && ultimoDia('2026-09') === '2026-09-30', 'el último día, bisiestos incluidos')
comprueba(nombreDelMes('2026-09') === 'septiembre de 2026', 'el nombre del mes')
// El día operativo empieza a medianoche en Caracas (04:00 UTC).
comprueba(diaOperativo(new Date('2026-10-01T03:59:00Z')) === '2026-09-30', 'antes de medianoche es el día anterior', diaOperativo(new Date('2026-10-01T03:59:00Z')))
comprueba(diaOperativo(new Date('2026-10-01T07:00:00Z')) === '2026-10-01', 'a las 3 de la madrugada ya es ese día')

console.log('\n── Las comprobaciones ───────────────────────────────────────')
{
  const hoy = '2026-10-05'
  comprueba(puntoExtracto('2026-09-30', '2026-09', hoy).estado === 'hecho', 'extracto hasta fin de mes: hecho')
  comprueba(puntoExtracto('2026-09-28', '2026-09', hoy).estado === 'falta', 'extracto corto: falta')
  comprueba(puntoExtracto(null, '2026-09', hoy).estado === 'falta', 'sin extracto: falta')
  comprueba(puntoExtracto('2026-09-20', '2026-09', '2026-09-25').estado === 'todavia_no', 'mes en curso: todavía no')

  comprueba(puntoAbonos([{ movedOn: '2026-10-02' }], '2026-09', false).estado === 'hecho', 'un abono de octubre no cuenta')
  comprueba(puntoAbonos([{ movedOn: '2026-09-12' }], '2026-09', false).estado === 'falta', 'uno de septiembre sí')
  comprueba(puntoAbonos([], '2026-09', true).estado === 'falta', 'con la lista cortada no se da por hecho')

  const cortes = [
    { checkedOn: '2026-10-03', differenceUsd: 0 },
    { checkedOn: '2026-09-30', differenceUsd: 0.2 },
  ]
  comprueba(puntoBanco(cortes, '2026-09', hoy, true).estado === 'hecho', 'corte del último día que cuadra: hecho')
  comprueba(puntoBanco([{ checkedOn: '2026-09-30', differenceUsd: -3 }], '2026-09', hoy, true).estado === 'falta', 'corte que no cuadra: falta')
  comprueba(puntoBanco([{ checkedOn: '2026-09-29', differenceUsd: 0 }], '2026-09', hoy, true).estado === 'falta', 'sin corte del último día: falta')

  comprueba(puntoLibro(0.001, 12, 0.01).estado === 'hecho', 'libro que suma cero: hecho')
  comprueba(puntoLibro(3, 12, 0.01).estado === 'falta', 'libro descuadrado: falta')

  const cierres = [
    { runDate: '2026-09-07', pendienteUsd: 0, isPast: true },
    { runDate: '2026-09-14', pendienteUsd: 12.5, isPast: true },
    { runDate: '2026-10-05', pendienteUsd: 40, isPast: false },
  ]
  const locales = puntoLocales(cierres, '2026-09')
  comprueba(locales.estado === 'falta' && locales.primerPendiente === '2026-09-14', 'un cierre del mes sin saldar: falta', JSON.stringify(locales))
  comprueba(puntoLocales(cierres.slice(0, 1), '2026-09').estado === 'hecho', 'todos saldados: hecho')
  comprueba(puntoLocales([{ runDate: '2026-09-28', pendienteUsd: 5, isPast: false }], '2026-09').estado === 'todavia_no', 'un cierre por llegar: todavía no')
}

console.log('\n── Lo devengado ─────────────────────────────────────────────')
{
  const linea = (type: string, account: string, debitUsd: number, creditUsd: number, memo: string | null = null) => ({
    businessDate: '2026-09-10', createdAt: '2026-09-10T20:00:00Z', type, memo, account,
    debitUsd, creditUsd, fxRate: 975, debitVes: 0, creditVes: 0, counterparty: null,
  })
  const d: AccountingExport = {
    month: '2026-09', from: '2026-09-01', to: '2026-09-30',
    summary: { collectedUsd: 30, paidOutUsd: 20, revenueUsd: 13, vatUsd: 1.6, writtenOffUsd: 0, transactions: 4 },
    byAccount: [
      { account: 'cash', debitUsd: 30, creditUsd: 20, netUsd: 10, debitVes: 0, creditVes: 0 },
      { account: 'user_receivable', debitUsd: 0, creditUsd: 10, netUsd: -10, debitVes: 0, creditVes: 0 },
    ],
    entries: [
      linea('charge', 'platform_revenue', 0, 10),
      linea('charge', 'vat_payable', 0, 1.6),
      linea('late_fee', 'platform_revenue', 0, 4),
      linea('manual_adjustment', 'platform_revenue', 2, 0, 'Cargo por atraso condonado: pagó a tiempo'),
      linea('manual_adjustment', 'platform_revenue', 1, 0, 'Financiamiento revertido'),
    ],
  }
  const r = devengadoDelMes(d)
  comprueba(r.servicioUsd === 9, 'el service fee, sin cargos y con la reversa', String(r.servicioUsd))
  comprueba(r.cargosPorAtrasoUsd === 2, 'los cargos, menos el condonado', String(r.cargosPorAtrasoUsd))
  comprueba(r.ivaUsd === 1.6, 'el IVA aparte', String(r.ivaUsd))
  comprueba(r.cobradoUsd === 30 && r.pagadoALocalesUsd === 20, 'la caja del mes')
  comprueba(descuadreDelLibro(d) === 0, 'el balance de comprobación suma cero')
}

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
