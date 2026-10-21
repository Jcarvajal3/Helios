import { leerDesglose, leerHoyUsado, leerSemanaUsada } from '@/features/admin/metricas/lectura'
import type { Desglose, SemanaUsada } from '@/features/admin/metricas/lectura'
import { comoDia } from '@/lib/busqueda'
import { comoFila, comoLista, filaONula, numero, numeroONulo, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// La lectura de lo que pinta Métricas › Caja: `admin_metricas_caja` (lo que
// se movió en la semana), `admin_cash_position` (la foto de hoy) y
// `admin_cash_forecast_days` (la proyección). Sin aritmética de negocio: todo lo
// calcula la base sobre `metricas.caja_*`; aquí solo se traducen nombres.
//
// La regla de la comisión: todo lo que se paga en cuotas (`payable`) llega con su
// consumo y su Comisión Helios con IVA (`Desglose`), y la pantalla nunca lo enseña sin
// sus dos partes. La Comisión Helios de Helios (sin IVA) y los cargos por atraso son
// cifras aparte.
//
// Puro: se prueba en `lectura.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

const CERO: Desglose = { payableUsd: 0, financedUsd: 0, feeUsd: 0 }

/** Un desglose que la base siempre manda: si falta, es un fallo del contrato y vale cero. */
function desglose(v: unknown): Desglose {
  return leerDesglose(v) ?? CERO
}

// ── Lo que se movió en la semana ───────────────────────────────────────────

export type Movimientos = {
  /** Lo que entró de cuotas: su pago se aprobó esos días. Con su desglose. */
  cobrado: Desglose & { cuotas: number; personas: number }
  /** La parte de Comisión Helios SIN IVA que había dentro de lo cobrado. */
  servicioCobradoUsd: number
  /** Cargos por atraso cobrados: aparte, nunca dentro de las cuotas. */
  cargosCobrados: { usd: number; n: number }
  /** Transferido a los locales (merchant_payouts). */
  transferido: { usd: number; n: number }
  /** El consumo de esos días (sin comisión) y cuántos consumos. */
  consumo: { financedUsd: number; consumos: number }
  /** La Comisión Helios SIN IVA de los consumos de esos días: lo ganado. */
  servicioGanadoUsd: number
  cargosDevengadosUsd: number
  /** Lo que dice el libro de caja. `null` con un local: el libro no sabe de locales. */
  libro: { cobradoUsd: number; transferidoUsd: number; otrosUsd: number } | null
}

function leerMovimientos(v: unknown): Movimientos {
  const m = comoFila(v)
  const cobrado = comoFila(m.cobrado)
  const cargos = comoFila(m.cargos_cobrados)
  const transferido = comoFila(m.transferido)
  const consumo = comoFila(m.consumo)
  const libro = filaONula(m.libro)
  return {
    cobrado: { ...desglose(cobrado), cuotas: numero(cobrado.cuotas), personas: numero(cobrado.personas) },
    servicioCobradoUsd: numero(m.servicio_cobrado_usd),
    cargosCobrados: { usd: numero(cargos.usd), n: numero(cargos.n) },
    transferido: { usd: numero(transferido.usd), n: numero(transferido.n) },
    consumo: { financedUsd: numero(consumo.financed_usd), consumos: numero(consumo.consumos) },
    servicioGanadoUsd: numero(m.servicio_ganado_usd),
    cargosDevengadosUsd: numero(m.cargos_devengados_usd),
    libro: libro
      ? {
          cobradoUsd: numero(libro.cobrado_usd),
          transferidoUsd: numero(libro.transferido_usd),
          otrosUsd: numero(libro.otros_usd),
        }
      : null,
  }
}

/** Una de las ocho semanas de las chispas. */
export type SemanaDeCaja = {
  lunes: string
  domingo: string
  enCurso: boolean
  cobrado: Desglose
  cargosCobradosUsd: number
  transferidoUsd: number
  servicioGanadoUsd: number
  servicioCobradoUsd: number
  /** `null` con un local. */
  cajaAlCierreUsd: number | null
  /** Todo lo que vencía esa semana, pagado o no. Reparte lo que se esperaba cobrar. */
  vencia: Desglose
}

export type PorPagarLocales = {
  totalUsd: number
  atrasadoUsd: number
  esteCierreUsd: number
  fechaCierre: string | null
  localesAtrasados: number
  /** Solo con un local. */
  ultimoPagoDia: string | null
  ultimoPagoUsd: number | null
}

export type CajaDeLaSemana = {
  hoy: string | null
  semana: SemanaUsada | null
  /** Días operativos de la semana que se miran (menos de siete si va a medias). */
  dias: number
  /** La semana anterior a la misma altura. */
  anterior: { desde: string; hasta: string } | null
  merchantId: string | null
  movimientos: Movimientos
  movimientosAnterior: Movimientos
  /** La caja del libro. `null` con un local: la caja es de todo Helios. */
  caja: { alInicioUsd: number; alCierreUsd: number; alCierreAnteriorUsd: number } | null
  porPagarLocales: PorPagarLocales
  semanas: SemanaDeCaja[]
}

export function leerCaja(data: unknown): CajaDeLaSemana {
  const raw = comoFila(data)
  const anterior = filaONula(raw.anterior)
  const caja = filaONula(raw.caja)
  const locales = comoFila(raw.por_pagar_locales)
  const desde = comoDia(anterior?.desde)
  const hasta = comoDia(anterior?.hasta)

  return {
    hoy: leerHoyUsado(raw.hoy),
    semana: leerSemanaUsada(raw.semana),
    dias: numero(raw.dias),
    anterior: desde && hasta ? { desde, hasta } : null,
    merchantId: textoONulo(raw.merchant_id),
    movimientos: leerMovimientos(raw.movimientos),
    movimientosAnterior: leerMovimientos(raw.movimientos_anterior),
    caja: caja
      ? {
          alInicioUsd: numero(caja.al_inicio_usd),
          alCierreUsd: numero(caja.al_cierre_usd),
          alCierreAnteriorUsd: numero(caja.al_cierre_anterior_usd),
        }
      : null,
    porPagarLocales: {
      totalUsd: numero(locales.total_usd),
      atrasadoUsd: numero(locales.atrasado_usd),
      esteCierreUsd: numero(locales.este_cierre_usd),
      fechaCierre: comoDia(locales.fecha_cierre) ?? null,
      localesAtrasados: numero(locales.locales_atrasados),
      ultimoPagoDia: comoDia(locales.ultimo_pago_dia) ?? null,
      ultimoPagoUsd: numeroONulo(locales.ultimo_pago_usd),
    },
    semanas: comoLista(raw.semanas).map((fila) => {
      const s = comoFila(fila)
      return {
        lunes: String(s.lunes),
        domingo: String(s.domingo),
        enCurso: s.en_curso === true,
        cobrado: desglose(s.cobrado),
        cargosCobradosUsd: numero(s.cargos_cobrados_usd),
        transferidoUsd: numero(s.transferido_usd),
        servicioGanadoUsd: numero(s.servicio_ganado_usd),
        servicioCobradoUsd: numero(s.servicio_cobrado_usd),
        cajaAlCierreUsd: numeroONulo(s.caja_al_cierre_usd),
        vencia: desglose(s.vencia),
      }
    }),
  }
}

// ── La foto de hoy ─────────────────────────────────────────────────────────

/**
 * `admin_cash_position`: lo que se debe, lo perdido y la Comisión Helios, partidos.
 * Con un local, lo del libro (caja, provisión, ingreso) es `null`.
 */
export type FotoDeCaja = {
  merchantId: string | null
  cajaUsd: number | null
  /** Caja menos lo que el libro debe a los locales. `null` con un local. */
  capitalLibreUsd: number | null
  /** Lo que el libro dice que deben los usuarios (cuotas vivas + cargos). `null` con un local. */
  porCobrarLibroUsd: number | null
  /** La provisión del libro: lo dado por perdido. `null` con un local. */
  perdidoLibroUsd: number | null
  /** Lo que deben los usuarios: cuotas vivas (con desglose) y cargos por atraso aparte. */
  porCobrar: Desglose & { cargosUsd: number }
  vencido: Desglose
  /** Lo dado por perdido y sin pagar, con desglose, y los cargos castigados. */
  perdido: Desglose & { cargosUsd: number }
  /** Lo que se les debe a los locales (a ese local, con uno elegido). */
  porPagarLocalesUsd: number | null
  servicio: {
    ganadoUsd: number
    cobradoUsd: number
    cargosGanadosUsd: number
    cargosCobradosUsd: number
  }
}

export function leerFoto(data: unknown): FotoDeCaja {
  const raw = comoFila(data)
  const recv = comoFila(raw.receivable)
  const lost = comoFila(raw.lost)
  const service = comoFila(raw.service)
  return {
    merchantId: textoONulo(raw.merchant_id),
    cajaUsd: numeroONulo(raw.cash),
    capitalLibreUsd: numeroONulo(raw.free_capital),
    porCobrarLibroUsd: numeroONulo(raw.user_receivable),
    perdidoLibroUsd: numeroONulo(raw.written_off),
    porCobrar: { ...desglose(recv), cargosUsd: numero(recv.late_fees_usd) },
    vencido: desglose(raw.overdue),
    perdido: { ...desglose(lost), cargosUsd: numero(lost.late_fees_usd) },
    porPagarLocalesUsd: numeroONulo(raw.merchant_payable),
    servicio: {
      ganadoUsd: numero(service.earned_usd),
      cobradoUsd: numero(service.collected_usd),
      cargosGanadosUsd: numero(service.late_fees_earned_usd),
      cargosCobradosUsd: numero(service.late_fees_collected_usd),
    },
  }
}

// ── La proyección ──────────────────────────────────────────────────────────

export type DiaProyectado = {
  dia: string
  /** Lo que vence, sin ajustar. */
  vence: Desglose
  /** Lo mismo, por el cobro a tiempo histórico. */
  seEspera: Desglose
  /** Lo que sale a las clínicas ese día: lo ya devengado más lo que se devengará. */
  saleUsd: number
  /** De lo que sale, lo que ya está en `settlements` (con lo atrasado, hoy). */
  saleDevengadoUsd: number
  /** De lo que sale, las mitades de cuotas que todavía no han vencido. */
  salePorDevengarUsd: number
  netoUsd: number
}

export type Proyeccion = {
  businessDate: string
  merchantId: string | null
  /** La caja de partida. `null` con un local. */
  cajaHoyUsd: number | null
  dias: number
  /** Null cuando no hay historia suficiente: lo esperado es lo que vence. */
  factorATiempo: number | null
  diasDeGracia: number
  filas: DiaProyectado[]
}

export function leerProyeccion(data: unknown): Proyeccion {
  const raw = comoFila(data)
  return {
    businessDate: String(raw.business_date),
    merchantId: textoONulo(raw.merchant_id),
    cajaHoyUsd: numeroONulo(raw.cash_now_usd),
    dias: numero(raw.days),
    factorATiempo: numeroONulo(raw.on_time_factor),
    diasDeGracia: numero(raw.grace_days),
    filas: comoLista(raw.rows).map((fila) => {
      const r = comoFila(fila)
      return {
        dia: String(r.day),
        vence: desglose({
          payable_usd: r.expected_gross_usd,
          financed_usd: r.expected_gross_financed_usd,
          fee_usd: r.expected_gross_fee_usd,
        }),
        seEspera: desglose({
          payable_usd: r.expected_in_usd,
          financed_usd: r.expected_in_financed_usd,
          fee_usd: r.expected_in_fee_usd,
        }),
        saleUsd: numero(r.expected_out_usd),
        saleDevengadoUsd: numero(r.out_accrued_usd),
        salePorDevengarUsd: numero(r.out_to_accrue_usd),
        netoUsd: numero(r.net_usd),
      }
    }),
  }
}
