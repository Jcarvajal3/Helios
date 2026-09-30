/**
 * Una respuesta de `admin_metricas_locales` como la manda la base (snake_case,
 * numéricos a veces como texto), para las pruebas de la pestaña Locales.
 *
 * La semana en curso del 21 al 27 de septiembre, vista el sábado 26 (seis días
 * contados). Tres locales con ventas —La Quinta, que lidera; El Marchante,
 * que crece; y Nuevo Local, que empezó a vender dentro de la ventana— y uno
 * activo que no vendió. Las cifras son inventadas pero cuadran entre sí: la
 * suma de los consumos por local es la de todos, y las personas de todos son
 * menos que la suma (hay quien fue a dos locales).
 */

const SEMANAS = [
  '2026-07-06',
  '2026-07-13',
  '2026-07-20',
  '2026-07-27',
  '2026-08-03',
  '2026-08-10',
  '2026-08-17',
  '2026-08-24',
  '2026-08-31',
  '2026-09-07',
  '2026-09-14',
  '2026-09-21',
]

const COHORTES = SEMANAS.slice(-8)

function cuota(cuotas: number, juzgadas: number, aTiempoJuzgadas: number, extra: Record<string, unknown> = {}) {
  return {
    cuotas,
    juzgadas,
    a_tiempo_juzgadas: aTiempoJuzgadas,
    pct_a_tiempo: juzgadas > 0 ? Math.round((1000 * aTiempoJuzgadas) / juzgadas) / 10 : null,
    a_tiempo: aTiempoJuzgadas,
    tarde: juzgadas - aTiempoJuzgadas,
    vencidas: 0,
    por_vencer: cuotas - juzgadas,
    perdidas: 0,
    vencido: { payable_usd: 0, financed_usd: 0, fee_usd: 0 },
    ...extra,
  }
}

export const RESPUESTA_SEMANA = {
  semana: { desde: '2026-09-21', hasta: '2026-09-27', en_curso: true },
  hoy: '2026-09-26',
  hasta: '2026-09-26',
  dias: 6,
  anterior: { desde: '2026-09-14', hasta: '2026-09-19', misma_altura: true },
  cierre: { lunes: '2026-09-28', pasado: false },
  gracia_dias: 2,
  local: null,
  // Llegan desordenadas a propósito: la lectura ordena por consumo.
  locales: [
    {
      merchant_id: 'em',
      nombre: 'El Marchante',
      estado: 'active',
      ciudad: 'Caracas',
      consumo_usd: '364.00',
      consumos: 13,
      ticket_medio_usd: 28,
      consumo_anterior_usd: 303,
      consumos_anteriores: 11,
      personas: 19,
      nuevas: 9,
      noches: 3,
      consumos_en_grupo: 4,
      mejor_noche: { fecha: '2026-09-25', consumo_usd: 180 },
      parte_pct: 36.36,
      a_tiempo: { vencen: 10, juzgadas: 9, a_tiempo: 7, pct: 77.8 },
      vencido: { payable_usd: 72.56, financed_usd: 58.9, fee_usd: 13.66, cuotas: 4, personas: 3 },
      transferencia: { generado_usd: 150, transferido_usd: 0, pendiente_usd: 150, previsto_usd: 117.5, atrasado_usd: 40 },
    },
    {
      merchant_id: 'lq',
      nombre: 'La Quinta Bar',
      estado: 'active',
      ciudad: 'Caracas',
      consumo_usd: 548.4,
      consumos: 17,
      ticket_medio_usd: 32.26,
      consumo_anterior_usd: 512,
      consumos_anteriores: 16,
      personas: 27,
      nuevas: 9,
      noches: 4,
      consumos_en_grupo: 6,
      mejor_noche: { fecha: '2026-09-26', consumo_usd: 250.4 },
      parte_pct: 54.8,
      a_tiempo: { vencen: 20, juzgadas: 18, a_tiempo: 15, pct: 83.3 },
      vencido: { payable_usd: 108.2, financed_usd: 87.82, fee_usd: 20.38, cuotas: 6, personas: 5 },
      transferencia: { generado_usd: 300, transferido_usd: 0, pendiente_usd: 300, previsto_usd: 142 },
    },
    {
      merchant_id: 'nl',
      nombre: 'Nueva Clínica',
      estado: 'active',
      ciudad: null,
      consumo_usd: 88,
      consumos: 3,
      ticket_medio_usd: 29.33,
      consumo_anterior_usd: 0,
      consumos_anteriores: 0,
      personas: 4,
      nuevas: 4,
      noches: 1,
      consumos_en_grupo: 0,
      mejor_noche: { fecha: '2026-09-25', consumo_usd: 88 },
      parte_pct: 8.84,
      a_tiempo: { vencen: 0, juzgadas: 0, a_tiempo: 0, pct: null },
      vencido: { payable_usd: 0, financed_usd: 0, fee_usd: 0, cuotas: 0, personas: 0 },
      transferencia: { generado_usd: 0, transferido_usd: 0, pendiente_usd: 0, previsto_usd: 0 },
    },
    {
      merchant_id: 'sv',
      nombre: 'Sin Financiamientos',
      estado: 'active',
      ciudad: 'Valencia',
      consumo_usd: 0,
      consumos: 0,
      ticket_medio_usd: null,
      consumo_anterior_usd: 0,
      consumos_anteriores: 0,
      personas: 0,
      nuevas: 0,
      noches: 0,
      consumos_en_grupo: 0,
      mejor_noche: null,
      parte_pct: 0,
      a_tiempo: { vencen: 0, juzgadas: 0, a_tiempo: 0, pct: null },
      vencido: { payable_usd: 0, financed_usd: 0, fee_usd: 0, cuotas: 0, personas: 0 },
      transferencia: { generado_usd: 0, transferido_usd: 0, pendiente_usd: 0, previsto_usd: 0 },
    },
  ],
  totales: {
    merchant_id: null,
    nombre: 'Todas las clínicas',
    estado: null,
    ciudad: null,
    consumo_usd: 1000.4,
    consumos: 33,
    ticket_medio_usd: 30.32,
    consumo_anterior_usd: 815,
    consumos_anteriores: 27,
    personas: 47,
    nuevas: 21,
    noches: 4,
    consumos_en_grupo: 10,
    mejor_noche: { fecha: '2026-09-26', consumo_usd: 250.4 },
    parte_pct: 100,
    a_tiempo: { vencen: 30, juzgadas: 27, a_tiempo: 22, pct: 81.5 },
    vencido: { payable_usd: 180.76, financed_usd: 146.72, fee_usd: 34.04, cuotas: 10, personas: 8 },
    transferencia: { generado_usd: 450, transferido_usd: 0, pendiente_usd: 450, previsto_usd: 259.5, atrasado_usd: 40 },
  },
  series: {
    semanas: SEMANAS,
    locales: [
      {
        merchant_id: 'lq',
        nombre: 'La Quinta Bar',
        primer_consumo: '2026-06-20',
        consumo_usd: [100, 120, 150, 200, 310, 365.5, 420, 388, 512.5, 372, 512, 548.4],
        consumos: [4, 5, 6, 7, 10, 12, 14, 13, 17, 12, 17, 17],
        personas: [6, 7, 9, 11, 15, 18, 21, 20, 26, 19, 26, 27],
        nuevas: [3, 2, 4, 5, 7, 6, 8, 5, 9, 4, 8, 9],
      },
      {
        merchant_id: 'em',
        nombre: 'El Marchante',
        primer_consumo: '2026-06-05',
        consumo_usd: [50, 60, 0, 80, 0, 0, 0, 0, 0, 232, 303, 364],
        consumos: [2, 2, 0, 3, 0, 0, 0, 0, 0, 9, 11, 13],
        personas: [3, 3, 0, 4, 0, 0, 0, 0, 0, 14, 17, 19],
        nuevas: [3, 1, 0, 2, 0, 0, 0, 0, 0, 8, 7, 9],
      },
      {
        merchant_id: 'nl',
        nombre: 'Nueva Clínica',
        primer_consumo: '2026-09-25',
        consumo_usd: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 88],
        consumos: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3],
        personas: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4],
        nuevas: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4],
      },
    ],
  },
  cohortes: {
    semanas: COHORTES,
    locales: [
      {
        merchant_id: 'lq',
        nombre: 'La Quinta Bar',
        semanas: COHORTES.map((semana, i) => ({
          semana,
          cuota_1:
            i < 7
              ? i === 6
                ? cuota(30, 12, 9)
                : cuota(20 + i, 20 + i, 18, i === 5 ? { vencidas: 2, tarde: 0, vencido: { payable_usd: 24.64, financed_usd: 20, fee_usd: 4.64 } } : {})
              : cuota(27, 0, 0),
          cuota_2: i < 6 ? cuota(20 + i, 20 + i, 17) : cuota(25, 0, 0),
        })),
      },
      {
        merchant_id: 'em',
        nombre: 'El Marchante',
        // Sin ventas en las cuatro primeras semanas de la ventana.
        semanas: COHORTES.map((semana, i) => ({
          semana,
          cuota_1: i < 5 ? null : i === 5 ? cuota(14, 14, 11) : i === 6 ? cuota(17, 0, 0) : cuota(19, 0, 0),
          cuota_2: i < 5 ? null : cuota(14, 0, 0),
        })),
      },
      {
        merchant_id: 'nl',
        nombre: 'Nueva Clínica',
        semanas: COHORTES.map((semana, i) => ({
          semana,
          cuota_1: i === 7 ? cuota(4, 0, 0) : null,
          cuota_2: i === 7 ? cuota(4, 0, 0) : null,
        })),
      },
    ],
  },
}
