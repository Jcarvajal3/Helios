import { formatUsd, sumarDias } from '@/components/ui'
import { booleano, comoFila, comoLista, numero, texto } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Por cobrar: lo que vence cada día de una semana y de qué local es.
//
// Lee `admin_receivables_by_day` (20260925190000). El día es el vencimiento
// de la cuota (`due_date`, día natural de Caracas) y el local, el del consumo
// de la cuota. Módulo puro, sin Supabase: la lectura de la base está en
// `components/admin/calendario-de-cobro/usePorCobrar.ts`.
//
// La clase de cada importe:
//   · `consumoUsd`   FINANCED: el consumo en el local, sin nada de Ronda;
//   · `comisionUsd`  la comisión de Ronda y su IVA (payable − financed);
//   · `cargosUsd`    los cargos por atraso de esas cuotas, siempre aparte;
//   · `totalUsd`     la suma de los tres. Solo se enseña AL LADO de sus
//                    sumandos: un total con la comisión dentro nunca va solo.
// El servidor redondea cada sumando al céntimo antes de sumar, así que el
// desglose cierra siempre con su total.
// ═══════════════════════════════════════════════════════════════════════════

/** Qué se mira: lo que sigue sin pagar (por defecto) o todo lo que vence. */
export const VER_POR_COBRAR = ['pendiente', 'todo'] as const
export type VerPorCobrar = (typeof VER_POR_COBRAR)[number]

/** Las cifras de un trozo: el periodo, un día, un local o un local en un día. */
export type CifrasPorCobrar = {
  /** Cuotas distintas con algo en este trozo. */
  cuotas: number
  /** Personas distintas: no se suman de un día a otro. */
  personas: number
  consumoUsd: number
  comisionUsd: number
  cargosUsd: number
  totalUsd: number
}

export type DiaPorCobrar = CifrasPorCobrar & {
  /** 'YYYY-MM-DD'. */
  dia: string
  locales: number
  /** Las cuotas de ese día que siguen sin pagar, se miren o no las pagadas. */
  cuotasSinPagar: number
  /** Ya pasó (según el día operativo, como el motor de mora) y queda algo sin pagar. */
  vencido: boolean
}

export type LocalPorCobrar = CifrasPorCobrar & { localId: string; local: string }

export type LocalDelDia = LocalPorCobrar & { dia: string }

/** Para explicar por qué lo pendiente de todas las fechas no es la cifra del libro. */
export type Cotejo = {
  /** Todo lo pendiente, de cualquier fecha, con los cargos de esas cuotas. */
  pendienteUsd: number
  /** Cargos por atraso pendientes que no cuelgan de ninguna cuota (anteriores al reparto por cuota). */
  cargosSinCuotaUsd: number
  /** «Por cobrar a usuarios» según el libro de asientos. */
  libroUsd: number
}

export type PorCobrar = {
  desde: string
  hasta: string
  /** Hoy en Caracas, día natural. */
  hoy: string
  diaOperativo: string
  incluyePagadas: boolean
  /** Lo que se mira en el periodo (pendiente, o todo lo que vence). */
  periodo: CifrasPorCobrar & { locales: number }
  /** De lo que vence en el periodo, lo ya pagado. */
  pagado: CifrasPorCobrar
  /** Lo que sigue sin pagar y venció antes del periodo (y antes de hoy). */
  vencidoAntes: CifrasPorCobrar & { hasta: string }
  /** Un día por fecha del periodo, los vacíos incluidos. */
  porDia: DiaPorCobrar[]
  /** Por local en todo el periodo, de mayor a menor total. */
  porLocal: LocalPorCobrar[]
  porDiaYLocal: LocalDelDia[]
  cotejo: Cotejo
}

function leerCifras(raw: unknown): CifrasPorCobrar {
  const r = comoFila(raw)
  return {
    cuotas: numero(r.cuotas),
    personas: numero(r.personas),
    consumoUsd: numero(r.consumo_usd),
    comisionUsd: numero(r.comision_usd),
    cargosUsd: numero(r.cargos_usd),
    totalUsd: numero(r.total_usd),
  }
}

function leerLocal(raw: unknown): LocalPorCobrar {
  const r = comoFila(raw)
  return { ...leerCifras(r), localId: texto(r.local_id), local: texto(r.local, 'Clínica sin nombre') }
}

export function leerPorCobrar(raw: unknown): PorCobrar {
  const d = comoFila(raw)
  const periodo = comoFila(d.periodo)
  const antes = comoFila(d.vencido_antes)
  const cotejo = comoFila(d.cotejo)

  return {
    desde: texto(d.desde),
    hasta: texto(d.hasta),
    hoy: texto(d.hoy),
    diaOperativo: texto(d.dia_operativo),
    incluyePagadas: booleano(d.incluye_pagadas),
    periodo: { ...leerCifras(periodo), locales: numero(periodo.locales) },
    pagado: leerCifras(d.pagado),
    vencidoAntes: { ...leerCifras(antes), hasta: texto(antes.hasta) },
    porDia: comoLista(d.por_dia).map((fila) => {
      const r = comoFila(fila)
      return {
        ...leerCifras(r),
        dia: texto(r.dia),
        locales: numero(r.locales),
        cuotasSinPagar: numero(r.cuotas_sin_pagar),
        vencido: booleano(r.vencido),
      }
    }),
    porLocal: comoLista(d.por_local).map(leerLocal),
    porDiaYLocal: comoLista(d.por_dia_y_local).map((fila) => ({
      ...leerLocal(fila),
      dia: texto(comoFila(fila).dia),
    })),
    cotejo: {
      pendienteUsd: numero(cotejo.pendiente_usd),
      cargosSinCuotaUsd: numero(cotejo.cargos_sin_cuota_usd),
      libroUsd: numero(cotejo.libro_usd),
    },
  }
}

// ── La semana y el día ─────────────────────────────────────────────────────

/** Las iniciales de una semana que empieza en lunes. */
const INICIALES = ['L', 'M', 'X', 'J', 'V', 'S', 'D'] as const

/** 'J 24': el día en el eje de una semana que empieza en lunes. */
export function rotuloDelDia(lunes: string, indice: number): string {
  return `${INICIALES[indice] ?? ''} ${Number(sumarDias(lunes, indice).slice(8, 10))}`
}

/** El día elegido, solo si cae dentro del periodo; si no, como si no hubiera. */
export function diaDentro(dia: string | undefined, desde: string, hasta: string): string | null {
  return dia !== undefined && dia >= desde && dia <= hasta ? dia : null
}

/** Las cifras que se enseñan: las del día elegido o las del periodo entero. */
export function cifrasDe(d: PorCobrar, dia: string | null): CifrasPorCobrar {
  if (dia === null) return d.periodo
  return d.porDia.find((x) => x.dia === dia) ?? SIN_NADA
}

const SIN_NADA: CifrasPorCobrar = {
  cuotas: 0,
  personas: 0,
  consumoUsd: 0,
  comisionUsd: 0,
  cargosUsd: 0,
  totalUsd: 0,
}

/**
 * Los locales del periodo, o los de un día, de mayor a menor total. La
 * persona que debe en dos locales cuenta en los dos: cada fila es lo que
 * corresponde a ese local.
 */
export function localesDe(d: PorCobrar, dia: string | null): LocalPorCobrar[] {
  const filas = dia === null ? d.porLocal : d.porDiaYLocal.filter((f) => f.dia === dia)
  return [...filas].sort((a, b) => b.totalUsd - a.totalUsd || a.local.localeCompare(b.local, 'es'))
}

/** Si hay cargos por atraso en lo que se ve: entonces son un tercer sumando. */
export function hayCargos(d: PorCobrar): boolean {
  return d.periodo.cargosUsd > 0 || d.porDia.some((x) => x.cargosUsd > 0)
}

// ── El cotejo con el libro ─────────────────────────────────────────────────

const CENTIMO = 0.005

/**
 * Por qué lo pendiente de todas las semanas juntas puede no ser «Por cobrar a
 * usuarios» del Balance, dicho en una frase. Lo del Balance sale del libro de
 * asientos y esto de las cuotas: el libro lleva además los cargos por atraso
 * que no cuelgan de ninguna cuota y cualquier ajuste manual. Se dice la
 * diferencia y no las dos cifras: las dos llevan la comisión dentro.
 */
export function fraseDelCotejo(c: Cotejo): string {
  const diferencia = c.libroUsd - c.pendienteUsd
  if (Math.abs(diferencia) < CENTIMO) {
    return 'Lo pendiente de todas las semanas juntas cuadra con «Por cobrar a pacientes» del Balance, que sale del libro.'
  }

  const sinCuota = c.cargosSinCuotaUsd
  const resto = diferencia - sinCuota
  const partes: string[] = []
  if (sinCuota >= CENTIMO) {
    partes.push(
      `${formatUsd(sinCuota)} son cargos por atraso anteriores al reparto por cuota, que no tienen día de vencimiento`,
    )
  }
  if (resto >= CENTIMO) {
    partes.push(`${formatUsd(resto)} son asientos del libro que no salen de una cuota, como un ajuste manual`)
  }
  if (resto <= -CENTIMO) {
    partes.push(`al libro le faltan ${formatUsd(-resto)} que sí están en las cuotas`)
  }

  const cabeza = `Lo pendiente de todas las semanas juntas no cuadra con «Por cobrar a pacientes» del Balance: el libro lleva ${formatUsd(Math.abs(diferencia))} ${diferencia > 0 ? 'más' : 'menos'}.`
  if (partes.length === 0) return cabeza
  const detalle = partes.join('; ')
  return `${cabeza} ${detalle.charAt(0).toUpperCase()}${detalle.slice(1)}.`
}
