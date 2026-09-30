// ═══════════════════════════════════════════════════════════════════════════
// Respuestas de mentira de `admin_metricas_cohortes` / `admin_metricas_cohorte`
// para las pruebas de esta carpeta, con la forma exacta del JSON de la base
// (20260927530000 y `a_cobrar` de 20260927610000). Las cifras cuadran entre
// sí como en la base: los cinco estados suman la cuota, el fee es payable −
// financed, lo que hay que cobrar es la cuota 1 + la 2 estado a estado y lo
// que volvió es el consumo de las cuotas pagadas.
//
// Solo lo importan los `*.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

type Estado = 'a_tiempo' | 'tarde' | 'vencida' | 'por_vencer' | 'perdida'

/** Una parte de cuota: lo que se cobra (payable) y su consumo (financed). */
export type ParteCruda = { payable: number; financed: number; cuotas?: number; personas?: number }

function redondo(n: number): number {
  return Math.round(n * 100) / 100
}

function parte(p: ParteCruda | undefined) {
  const payable = p?.payable ?? 0
  const financed = p?.financed ?? 0
  return {
    cuotas: p?.cuotas ?? (payable > 0 ? 1 : 0),
    personas: p?.personas ?? (payable > 0 ? 1 : 0),
    payable_usd: payable,
    financed_usd: financed,
    fee_usd: redondo(payable - financed),
  }
}

/** Una cuota cruda a partir de sus estados; los totales y los porcentajes se deducen. */
export function cuotaCruda(
  n: 1 | 2,
  venceDesde: string,
  venceHasta: string,
  estados: Partial<Record<Estado, ParteCruda>>,
  personas = 10,
) {
  const todos: Estado[] = ['a_tiempo', 'tarde', 'vencida', 'por_vencer', 'perdida']
  const crudos = Object.fromEntries(todos.map((e) => [e, parte(estados[e])]))
  const payable = redondo(todos.reduce((a, e) => a + (estados[e]?.payable ?? 0), 0))
  const financed = redondo(todos.reduce((a, e) => a + (estados[e]?.financed ?? 0), 0))
  const pctDe = (v: number) => (payable > 0 ? redondo((100 * v) / payable) : null)
  const aTiempo = estados.a_tiempo?.payable ?? 0
  const tarde = estados.tarde?.payable ?? 0
  return {
    sequence: n,
    vence_desde: venceDesde,
    vence_hasta: venceHasta,
    cuotas: todos.reduce((a, e) => a + crudos[e].cuotas, 0),
    personas,
    payable_usd: payable,
    financed_usd: financed,
    fee_usd: redondo(payable - financed),
    cobrado_pct: pctDe(aTiempo + tarde),
    a_tiempo_pct: pctDe(aTiempo),
    vencido_pct: pctDe(estados.vencida?.payable ?? 0),
    estados: crudos,
  }
}

type CuotaCruda = ReturnType<typeof cuotaCruda>

/**
 * Lo que hay que cobrar de una semana, como lo arma la base (a_cobrar): la
 * cuota 1 + la 2, estado a estado. Las personas de cada estado son personas
 * distintas, que aquí no se pueden deducir: van las de la cuota con más, o
 * las que se pasen.
 */
export function aCobrarCrudo(
  cuotas: ReadonlyArray<CuotaCruda>,
  personas: { total?: number; cobrado?: number; falta?: number } = {},
) {
  const todos: Estado[] = ['a_tiempo', 'tarde', 'vencida', 'por_vencer', 'perdida']
  type Parte = ReturnType<typeof parte>
  const suma = (partes: ReadonlyArray<Parte>) => ({
    cuotas: partes.reduce((a, p) => a + p.cuotas, 0),
    personas: Math.max(0, ...partes.map((p) => p.personas)),
    payable_usd: redondo(partes.reduce((a, p) => a + p.payable_usd, 0)),
    financed_usd: redondo(partes.reduce((a, p) => a + p.financed_usd, 0)),
    fee_usd: redondo(partes.reduce((a, p) => a + p.fee_usd, 0)),
  })
  const estados = Object.fromEntries(
    todos.map((e) => [e, suma(cuotas.map((q) => q.estados[e]))]),
  ) as Record<Estado, Parte>
  const cobrado = suma([estados.a_tiempo, estados.tarde])
  const falta = suma([estados.vencida, estados.por_vencer])
  const payable = redondo(cuotas.reduce((a, q) => a + q.payable_usd, 0))
  const financed = redondo(cuotas.reduce((a, q) => a + q.financed_usd, 0))
  const pctDe = (v: number) => (payable > 0 ? redondo((100 * v) / payable) : null)
  const vencen = cuotas.flatMap((q) => [q.vence_desde, q.vence_hasta]).sort()
  return {
    cuotas: cuotas.reduce((a, q) => a + q.cuotas, 0),
    personas: personas.total ?? Math.max(0, ...cuotas.map((q) => q.personas)),
    payable_usd: payable,
    financed_usd: financed,
    fee_usd: redondo(payable - financed),
    vence_desde: vencen.at(0) ?? null,
    vence_hasta: vencen.at(-1) ?? null,
    cobrado_pct: pctDe(cobrado.payable_usd),
    a_tiempo_pct: pctDe(estados.a_tiempo.payable_usd),
    vencido_pct: pctDe(estados.vencida.payable_usd),
    falta_pct: pctDe(falta.payable_usd),
    cobrado: { ...cobrado, personas: personas.cobrado ?? cobrado.personas },
    falta: { ...falta, personas: personas.falta ?? falta.personas },
    estados,
  }
}

/** Una cohorte cruda: lo de la semana se deduce de sus cuotas. */
export function cohorteCruda(
  semana: string,
  cuotas: ReadonlyArray<CuotaCruda>,
  extra: {
    consumos?: number
    personas?: number
    en_curso?: boolean
    hasta?: string
    /** Las personas distintas de lo que hay que cobrar: con cobros, con algo que falta. */
    personasACobrar?: { cobrado?: number; falta?: number }
  } = {},
) {
  const suma = (e: Estado) =>
    redondo(cuotas.reduce((a, q) => a + (q.estados[e] as { financed_usd: number }).financed_usd, 0))
  const financed = redondo(cuotas.reduce((a, q) => a + q.financed_usd, 0))
  const volvio = redondo(suma('a_tiempo') + suma('tarde'))
  return {
    semana,
    hasta: extra.hasta ?? semana,
    en_curso: extra.en_curso ?? false,
    consumos: extra.consumos ?? 20,
    financed_usd: financed,
    personas: extra.personas ?? 15,
    volvio_financed_usd: volvio,
    volvio_pct: financed > 0 ? redondo((100 * volvio) / financed) : null,
    a_tiempo_financed_usd: suma('a_tiempo'),
    tarde_financed_usd: suma('tarde'),
    vencido_financed_usd: suma('vencida'),
    por_vencer_financed_usd: suma('por_vencer'),
    perdido_financed_usd: suma('perdida'),
    personas_con_vencido: cuotas.reduce((a, q) => a + (q.estados.vencida as { personas: number }).personas, 0),
    a_cobrar: aCobrarCrudo(cuotas, { total: extra.personas ?? 15, ...extra.personasACobrar }),
    cuotas,
  }
}

/**
 * Tres semanas vistas el sábado 26-09-2026 (día operativo), con dos días de
 * gracia: la del 7 (cobrada casi entera), la del 14 (cuota 1 venciendo con
 * algo vencido, cuota 2 por vencer) y la del 21 (en curso, nada vencido).
 */
export const HOY = '2026-09-26'
export const GRACIA = 2

export const SEMANA_7 = cohorteCruda(
  '2026-09-07',
  [
    cuotaCruda(1, '2026-09-14', '2026-09-20', {
      a_tiempo: { payable: 300, financed: 243.5, cuotas: 30, personas: 25 },
      tarde: { payable: 40, financed: 32.5, cuotas: 4, personas: 4 },
      vencida: { payable: 12.3, financed: 10, cuotas: 1, personas: 1 },
    }),
    cuotaCruda(2, '2026-09-21', '2026-09-27', {
      a_tiempo: { payable: 250, financed: 203, cuotas: 25, personas: 22 },
      por_vencer: { payable: 102.3, financed: 83, cuotas: 10, personas: 9 },
    }),
  ],
  { hasta: '2026-09-13', consumos: 30, personas: 30 },
)

export const SEMANA_14 = cohorteCruda(
  '2026-09-14',
  [
    cuotaCruda(1, '2026-09-21', '2026-09-27', {
      a_tiempo: { payable: 405.05, financed: 328.75, cuotas: 43, personas: 36 },
      tarde: { payable: 6.37, financed: 5.17, cuotas: 1, personas: 1 },
      vencida: { payable: 151.7, financed: 123.13, cuotas: 16, personas: 12 },
      por_vencer: { payable: 146.63, financed: 119.01, cuotas: 19, personas: 19 },
    }),
    cuotaCruda(2, '2026-09-28', '2026-10-04', {
      a_tiempo: { payable: 198.43, financed: 161.08, cuotas: 20, personas: 17 },
      por_vencer: { payable: 511.08, financed: 414.86, cuotas: 59, personas: 51 },
    }),
  ],
  { hasta: '2026-09-20', consumos: 52, personas: 65 },
)

export const SEMANA_21 = cohorteCruda(
  '2026-09-21',
  [
    cuotaCruda(1, '2026-09-28', '2026-10-03', {
      a_tiempo: { payable: 83.02, financed: 67.38, cuotas: 10, personas: 7 },
      por_vencer: { payable: 631.69, financed: 512.67, cuotas: 65, personas: 55 },
    }),
    cuotaCruda(2, '2026-10-05', '2026-10-10', {
      por_vencer: { payable: 714.71, financed: 580.05, cuotas: 75, personas: 59 },
    }),
  ],
  { hasta: '2026-09-27', en_curso: true, consumos: 44, personas: 59 },
)

export const LISTA_CRUDA = {
  hoy: HOY,
  gracia_dias: GRACIA,
  semana_en_curso: '2026-09-21',
  local: null,
  // Desordenadas a propósito: la lectura las ordena.
  cohortes: [SEMANA_7, SEMANA_21, SEMANA_14],
}

function diasDeCurva(esta: ReadonlyArray<number | null>, media: ReadonlyArray<number | null>) {
  return Array.from({ length: 21 }, (_, i) => ({
    dia: i - 6,
    esta_pct: esta[i] ?? null,
    media_pct: media[i] ?? null,
    semanas_en_media: (media[i] ?? null) === null ? 3 : 4,
  }))
}

export const DETALLE_CRUDO = {
  semana: { desde: '2026-09-14', hasta: '2026-09-20', en_curso: false },
  hoy: HOY,
  gracia_dias: GRACIA,
  local: null,
  cohorte: SEMANA_14,
  curvas: [
    {
      sequence: 2,
      semanas_media: ['2026-09-07'],
      dias: diasDeCurva([], [45.5, 47.9]),
    },
    {
      sequence: 1,
      semanas_media: ['2026-09-07', '2026-08-31', '2026-08-24', '2026-08-17'],
      // Esta semana ha cerrado hasta dos días antes de vencer.
      dias: diasDeCurva(
        [0.96, 6.81, 11.94, 15.92, 17.61],
        [9.23, 15.05, 20.47, 28.56, 37.61, 43.24, 71.48, 78.45, 80.09, 83.86, 85.02, 85.46],
      ),
    },
  ],
  por_local: [
    { ...SEMANA_14, merchant_id: '11111111-1111-4111-8111-111111111111', nombre: 'La Quinta Bar' },
  ],
}
