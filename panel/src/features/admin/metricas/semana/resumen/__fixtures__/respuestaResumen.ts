// Una respuesta cruda de `admin_metricas_semana_resumen`, con la forma y el
// orden de magnitud de dev (semana del 21-09 en curso, hoy 26-09, seis días).
// Cuadra como cuadra la base: payable = financed + fee, fee = servicio + iva,
// y la suma de las noches no es la semana entera (hay más noches que estas).

type Tramo = {
  financed_usd: number
  fee_usd: number
  payable_usd: number
  servicio_usd: number
  iva_usd: number
  consumos: number
  ticket_medio_usd: number | null
  personas: number
  nuevas: number
}

const SEMANA: Tramo = {
  financed_usd: 1129,
  fee_usd: 261.92,
  payable_usd: 1390.92,
  servicio_usd: 225.8,
  iva_usd: 36.12,
  consumos: 43,
  ticket_medio_usd: 26.26,
  personas: 61,
  nuevas: 30,
}

const ANTERIOR: Tramo = {
  financed_usd: 1015.5,
  fee_usd: 235.6,
  payable_usd: 1251.1,
  servicio_usd: 203.1,
  iva_usd: 32.5,
  consumos: 45,
  ticket_medio_usd: 22.57,
  personas: 58,
  nuevas: 29,
}

/** Una semana cerrada de la chispa, escalada a partir de la anterior. */
function semanaVieja(desde: string, hasta: string, factor: number): Record<string, unknown> {
  const t = (n: number) => Math.round(n * factor * 100) / 100
  const financed = t(ANTERIOR.financed_usd)
  const servicio = t(ANTERIOR.servicio_usd)
  const iva = t(ANTERIOR.iva_usd)
  const fee = Math.round((servicio + iva) * 100) / 100
  const consumos = Math.round(ANTERIOR.consumos * factor)
  return {
    desde,
    hasta,
    hasta_dato: hasta,
    dias: 7,
    en_curso: false,
    financed_usd: financed,
    fee_usd: fee,
    payable_usd: Math.round((financed + fee) * 100) / 100,
    servicio_usd: servicio,
    iva_usd: iva,
    consumos,
    ticket_medio_usd: consumos > 0 ? Math.round((financed / consumos) * 100) / 100 : null,
    personas: Math.round(ANTERIOR.personas * factor),
    nuevas: Math.round(ANTERIOR.nuevas * factor),
  }
}

export const NOCHES_CRUDAS = [
  {
    business_date: '2026-09-26',
    merchant_id: '179b20df-8f9c-1a61-4927-f53fd545b218',
    nombre: 'Terraza Semilla',
    consumos: 6,
    personas: 11,
    nuevas: 3,
    financed_usd: 182,
    fee_usd: 42.21,
    payable_usd: 224.21,
    ticket_medio_usd: 30.33,
  },
  {
    business_date: '2026-09-26',
    merchant_id: '2a2f0e8e-0b7b-4c55-9c9f-0f6c1b0d2e11',
    nombre: 'La Quinta Bar',
    consumos: 5,
    personas: 8,
    nuevas: 2,
    financed_usd: 150,
    fee_usd: 34.8,
    payable_usd: 184.8,
    ticket_medio_usd: 30,
  },
  {
    business_date: '2026-09-25',
    merchant_id: '2a2f0e8e-0b7b-4c55-9c9f-0f6c1b0d2e11',
    nombre: 'La Quinta Bar',
    consumos: 4,
    personas: 6,
    nuevas: 6,
    financed_usd: 88.5,
    fee_usd: 20.53,
    payable_usd: 109.03,
    ticket_medio_usd: 22.13,
  },
]

/**
 * La respuesta cruda. `semanas`: cuántas semanas trae la chispa (la última
 * es la elegida); `local`: el uuid del local elegido, o `null`.
 */
export function respuestaCruda({
  semanas = 8,
  local = null,
  noches = NOCHES_CRUDAS,
}: {
  semanas?: number
  local?: string | null
  noches?: ReadonlyArray<Record<string, unknown>>
} = {}): Record<string, unknown> {
  // Del 21-09 hacia atrás, de siete en siete días.
  const lunes = ['2026-08-03', '2026-08-10', '2026-08-17', '2026-08-24', '2026-08-31', '2026-09-07', '2026-09-14']
  const domingos = ['2026-08-09', '2026-08-16', '2026-08-23', '2026-08-30', '2026-09-06', '2026-09-13', '2026-09-20']
  const viejas = lunes
    .map((l, i) => semanaVieja(l, domingos[i] ?? l, 0.4 + i * 0.1))
    .slice(Math.max(0, lunes.length - (semanas - 1)))

  return {
    hoy: '2026-09-26',
    local,
    semana: { desde: '2026-09-21', hasta: '2026-09-27', en_curso: true },
    hasta: '2026-09-26',
    dias: 6,
    // El sábado 26 a las 15:00 de Caracas: la anterior, hasta el sábado 19 a la misma hora.
    anterior: { desde: '2026-09-14', hasta: '2026-09-19', dias: 6, misma_altura: true, corte: '2026-09-19T19:00:00+00:00' },
    cifras: SEMANA,
    comparacion: ANTERIOR,
    semanas: [
      ...viejas,
      { desde: '2026-09-21', hasta: '2026-09-27', hasta_dato: '2026-09-26', dias: 6, en_curso: true, ...SEMANA },
    ],
    noches,
  }
}
