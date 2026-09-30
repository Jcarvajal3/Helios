/**
 * Pruebas de lo proyectado frente a lo que pasó.
 *
 *   npx tsx src/features/admin/proyectadoFrenteAReal.test.ts
 *
 * Lo que se vigila: que sin fotos la lista llegue vacía y con la fecha de la
 * próxima, que se lean todas las cifras de una semana y que el desvío no
 * cuente la semana en curso ni se invente un cero.
 */
import { desvioDelCobro, leerProyectadoFrenteAReal } from './proyectadoFrenteAReal'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

console.log('── Sin fotos ────────────────────────────────────────────────')
{
  const d = leerProyectadoFrenteAReal({
    business_date: '2026-09-25',
    weeks_requested: 8,
    snapshots: 0,
    first_snapshot_week: null,
    next_snapshot_on: '2026-09-28',
    rows: [],
  })
  comprueba(d.semanas.length === 0 && d.fotos === 0, 'sin fotos no hay semanas')
  comprueba(d.proximaFoto === '2026-09-28' && d.primeraFoto === null, 'dice cuándo es la próxima')
  comprueba(desvioDelCobro(d.semanas) === null, 'sin semanas cerradas no hay desvío, ni siquiera cero')
}

console.log('\n── Con fotos ────────────────────────────────────────────────')
{
  // Tal como la devolvió la base en el ensayo (rollback, dev).
  const d = leerProyectadoFrenteAReal({
    business_date: '2026-09-25',
    snapshots: 2,
    first_snapshot_week: '2026-09-14',
    next_snapshot_on: '2026-09-28',
    rows: [
      {
        week_start: '2026-09-14', week_end: '2026-09-20', complete: true, snapshot_week: '2026-09-14', lead_weeks: 0,
        projected_gross_usd: 10, projected_in_usd: 8, projected_out_usd: 2.349, projected_net_usd: 5.65,
        projected_cash_end_usd: 32.78, collected_usd: 6.5, paid_to_merchants_usd: 0, other_cash_usd: 0,
        actual_net_usd: 6.5, actual_cash_end_usd: 6.5,
      },
      {
        week_start: '2026-09-21', week_end: '2026-09-27', complete: false, snapshot_week: '2026-09-21', lead_weeks: 0,
        projected_gross_usd: 2.39, projected_in_usd: 2.39, projected_out_usd: 2.349, projected_net_usd: 0.04,
        projected_cash_end_usd: 35.17, collected_usd: 35.13, paid_to_merchants_usd: 0, other_cash_usd: 0,
        actual_net_usd: 35.13, actual_cash_end_usd: 35.13,
      },
    ],
  })
  const [a, b] = d.semanas
  comprueba(d.semanas.length === 2 && a.completa && !b.completa, 'lee la semana cerrada y la de hoy')
  comprueba(a.proyectadoCobrarUsd === 8 && a.cobradoUsd === 6.5 && a.proyectadoCajaFinalUsd === 32.78, 'lee las cifras')
  comprueba(b.cajaFinalUsd === 35.13 && b.fotoDelLunes === '2026-09-21', 'lee la caja y la foto')
  comprueba(desvioDelCobro(d.semanas) === -1.5, 'el desvío es solo de las semanas cerradas', String(desvioDelCobro(d.semanas)))
}

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
