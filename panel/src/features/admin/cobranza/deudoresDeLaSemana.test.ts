/**
 * Pruebas de la lista de quién debe de una semana (Por cobrar › Cohortes).
 *
 *   npx tsx src/features/admin/cobranza/deudoresDeLaSemana.test.ts
 *
 * Lo que se vigila: que la respuesta de `admin_deudores_de_la_semana` se lea
 * entera (la fila de la cartera, lo de la semana y las señales), que el
 * filtro de cuota deje solo esas cuotas y su suma, y que las sumas por estado
 * cuenten a cada persona una vez.
 */
import { deLaCuota, leerDeudoresDeLaSemana, sumasPorEstado } from './deudoresDeLaSemana'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const cuota = (numero: number, estado: string, payable: number, vence = '2026-09-25') => ({
  numero,
  estado,
  vence,
  dias_atraso: estado === 'vencida' ? 3 : 0,
  payable_usd: payable,
  financed_usd: payable - 2,
  fee_usd: 2,
  local: 'Bar',
})

const crudo = {
  semana: '2026-09-14',
  business_date: '2026-09-28',
  horizonte_dias: 30,
  demotion_days: 30,
  rows: [
    {
      user_id: 'a',
      full_name: 'Ana',
      status: 'frozen',
      overdue_usd: 20,
      upcoming_usd: 10,
      days_overdue: 3,
      next_due_date: '2026-09-25',
      perfil: 'nunca_ha_pagado',
      prioridad: 'alta',
      senales: { avisos: 'activos', cuotas_pagadas: 0 },
      de_la_semana: {
        payable_usd: 30,
        financed_usd: 24,
        fee_usd: 6,
        cuotas: [cuota(1, 'vencida', 10), cuota(1, 'vencida', 10), cuota(2, 'por_vencer', 10, '2026-10-02')],
      },
    },
    {
      user_id: 'b',
      full_name: 'Beto',
      status: 'active',
      overdue_usd: 0,
      upcoming_usd: 12,
      next_due_date: '2026-10-02',
      de_la_semana: { payable_usd: 12, financed_usd: 10, fee_usd: 2, cuotas: [cuota(2, 'por_vencer', 12, '2026-10-02'), cuota(2, 'raro', 5)] },
    },
  ],
}

const d = leerDeudoresDeLaSemana(crudo)

console.log('── Leer la respuesta ────────────────────────────────────────')
comprueba(d.semana === '2026-09-14' && d.horizonteDias === 30 && d.demotionDays === 30, 'la cabecera')
comprueba(d.filas.length === 2 && d.filas[0].fullName === 'Ana', 'las filas, en su orden')
comprueba(d.filas[0].deLaSemana.payableUsd === 30 && d.filas[0].deLaSemana.feeUsd === 6, 'lo de la semana, con su desglose')
comprueba(d.filas[0].senales.cuotasPagadas === 0 && d.filas[0].perfil === 'nunca_ha_pagado', 'las señales y el perfil')
comprueba(d.filas[1].cuotas.length === 1, 'un estado desconocido no se inventa')

console.log('\n── El filtro de cuota ───────────────────────────────────────')
comprueba(deLaCuota(d.filas, 'todas').length === 2, 'las dos: todos')
const c1 = deLaCuota(d.filas, '1')
comprueba(c1.length === 1 && c1[0].userId === 'a', 'cuota 1: solo quien la debe')
comprueba(c1[0].deLaSemana.payableUsd === 20 && c1[0].cuotas.length === 2, 'y solo esas cuotas, con su suma')
const c2 = deLaCuota(d.filas, '2')
comprueba(c2.length === 2 && c2[0].deLaSemana.payableUsd === 10, 'cuota 2')

console.log('\n── Las sumas por estado ─────────────────────────────────────')
const s = sumasPorEstado(d.filas)
comprueba(s.vencida.importe.payableUsd === 20 && s.vencida.personas === 1, 'lo vencido, con cada paciente una vez')
comprueba(s.por_vencer.importe.payableUsd === 22 && s.por_vencer.personas === 2, 'lo por vencer')
comprueba(s.perdida.importe.payableUsd === 0 && s.perdida.personas === 0, 'lo perdido, en cero')

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
