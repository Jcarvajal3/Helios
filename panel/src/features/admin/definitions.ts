import type { BadgeTone } from '@/components/ui'
import type { MerchantPayable } from '@/features/admin/api'
import type { Parametros } from '@/features/admin/parametros'
import { tonoImpago } from '@/features/admin/umbrales'

// ═══════════════════════════════════════════════════════════════════════════
// Un número, una definición, un lugar.
//
// El panel tenía el mismo concepto con dos nombres y dos valores en pantallas
// distintas: "exposición viva" y "deuda viva", "por pagar a comercios" y
// "comprometido". No era un fallo de cálculo — era que cada pantalla sumaba
// por su cuenta.
//
// Aquí se decide **cómo se llama cada cifra y qué la compone**, una sola vez.
// Riesgo de crédito y Dinero leen de `buildMetrics`; Hoy solo toma
// `payablesTotals` para su semáforo del cierre, y el Resumen de Gerencia toma
// de `DEFINICIONES` el nombre y la explicación de las cifras que repite.
// Ninguna vuelve a sumar nada. El cálculo de verdad sigue viviendo en la base
// (el libro de asientos manda); lo que vive aquí es el nombre, la explicación
// y qué campo del servidor le corresponde.
//
// Cuando el servidor todavía no publica una cifra que la especificación pide,
// se declara igualmente con `available: false` y el motivo. Es mejor una
// tarjeta que dice "falta el dato" que una tarjeta que no existe: así se ve
// que el hueco es del servidor y no de la pantalla.
//
// Los colores de la mora, el impago y el cobro a tiempo salen de los umbrales
// de `business_parameters` (`umbrales.ts`), los mismos en todo el panel. Sin
// los parámetros la cifra se pinta neutra: un color inventado es peor que
// ninguno.
//
// ───────────────────────────────────────────────────────────────────────────
// Cómo se escribe un `label` (2026-09-21)
// ───────────────────────────────────────────────────────────────────────────
// **El rótulo dice qué es la cifra, no cómo se llama en contabilidad.** Había
// seis tarjetas tituladas "Caja", "Principal en la calle", "Capital libre",
// "Comisión devengada", "Castigado" e "Impago": todas correctas y ninguna
// legible sin que alguien te la explique. Javier, textual: *"«Principal en la
// calle» no dice absolutamente nada y es imposible saber a qué se refiere.
// Comprender estas métricas es como armar un rompecabezas"*.
//
// Las tres reglas que salieron de ahí:
//
//   1. **Verbo o preposición antes que sustantivo técnico.** "Por cobrar a
//      usuarios" y "Por pagar a locales" se leen como pareja; "Deuda de
//      usuarios" y "Por pagar a comercios" no. "Dado por perdido" en vez de
//      "Castigado". "Service fee ganado" en vez de "Comisión devengada".
//   2. **El término contable no se tira, se baja al `what`.** Quien audite
//      necesita leer "devengado" y "principal"; quien mira el panel a diario,
//      no. El ícono de información es donde conviven.
//   3. **Si dos cifras son partes de una tercera, van DENTRO de ella.** Es lo
//      que hace la tarjeta de "Por cobrar a usuarios" con el consumo y el
//      service fee, y la de "Service fee ganado" con lo ya cobrado. Dos tarjetas
//      hermanas no tienen forma de decir que una está contenida en la otra, y
//      el lector acaba sumándolas.
//
// Y dos más de Javier (2026-09-27):
//
//   4. **El fee se llama «service fee», o «fee» donde no cabe.** Nunca
//      «servicio», «servicio de Ronda» ni «comisión»: la comisión es la del
//      local (`comision_local_usd`), que es otra cosa. Las claves de aquí
//      (`comisionEnDeuda`, `comisionDevengada`…) no cambian: solo lo que se lee.
//   5. **Todo «consumo» dice si lleva el fee**: «Consumo (sin fee)» en el
//      rótulo o, si no cabe, un `what` que empieza por «Sin el service fee».
//
// Y el repaso de rigor de Javier (2026-09-27, ola 5):
//
//   6. **El vocabulario es uno**: «Facturado (sin fee)» para el consumo sin
//      fee, «Service fee + IVA» para el fee con su IVA, «Service fee sin IVA»
//      para lo que gana Ronda, «Perdido», «Mora (%)», «Cobrado a tiempo»,
//      «usuarios» y no «personas». Un porcentaje lleva «(%)» en el rótulo.
//   7. **El `what` es UNA frase con la definición operativa**: qué se cuenta,
//      sobre qué población, en qué periodo y en qué unidad; si es un %, qué
//      entre qué. Quien lo compone con otra frase detrás, la añade después.
// ═══════════════════════════════════════════════════════════════════════════

export type MetricKey =
  | 'caja'
  | 'principalCalle'
  | 'comisionEnDeuda'
  | 'deudaUsuarios'
  | 'porPagarLocales'
  | 'capitalLibre'
  | 'comisionDevengada'
  | 'comisionCobrada'
  | 'castigado'
  | 'mora'
  | 'impago'
  | 'cobroATiempo'
  | 'puntoDeEmpate'

/**
 * El nombre y la explicación de cada cifra, sin valores.
 *
 * Así toda pantalla que enseña la misma cifra, lea de donde lea, la llama
 * igual y la explica igual.
 */
export const DEFINICIONES: Record<MetricKey, { label: string; what: string }> = {
  caja: {
    label: 'Dinero en caja',
    what: 'El saldo de la cuenta de caja del libro de asientos: lo cobrado a los pacientes (cuotas y cargos por atraso) menos lo transferido a las clínicas, la garantía depositada en los que tienen bóveda y los ajustes, que no es el saldo del banco (ese se coteja en Métricas › Caja › Proyección y banco).',
  },
  deudaUsuarios: {
    label: 'Por cobrar a pacientes',
    what: 'Lo que los pacientes deben y todavía no han pagado, vencido o no: el financiado (sin fee), el service fee + IVA de sus cuotas y los cargos por atraso pendientes, sin lo dado por perdido.',
  },
  principalCalle: {
    label: 'Financiado (sin fee)',
    what: 'Sin el service fee: la parte de las cuotas sin pagar que es financiamiento en las clínicas, el dinero de Helios que está fuera y que se pierde entero si el paciente no paga; sale de las cuotas.',
  },
  comisionEnDeuda: {
    label: 'Service fee + IVA',
    what: 'La otra parte de las cuotas sin pagar: el service fee y el IVA que lo grava (el IVA no es de Helios: se cobra al paciente y se remite).',
  },
  porPagarLocales: {
    label: 'Por pagar a clínicas',
    what: 'Lo que Helios les debe a las clínicas (sin los de prueba) por lo que ya se financiaron sus pacientes y todavía no se ha transferido: el financiado (sin fee) menos la comisión de la clínica, partido en atrasado (su cierre ya pasó) y por vencer.',
  },
  capitalLibre: {
    // El rótulo va delante del número, en el pie: «Caja tras pagar a todos los
    // locales −€642,00». «Capital libre» obligaba a saber de antemano qué
    // capital y libre de qué.
    label: 'Caja tras pagar a todas las clínicas',
    what: 'Dinero en caja menos lo que se les debe a las clínicas y no cubre su garantía, que sale negativo casi siempre porque a las clínicas se les paga por fecha de cierre y la deuda entera nunca vence el mismo día.',
  },
  comisionDevengada: {
    label: 'Service fee sin IVA',
    what: 'El service fee sin IVA de todos los financiamientos confirmados que no se han dado por perdidos, cobrado o no (lo devengado: se gana al confirmar el financiamiento y se cobra con las cuotas).',
  },
  comisionCobrada: {
    label: 'Service fee sin IVA cobrado',
    what: 'La parte de ese service fee sin IVA que los pacientes ya pagaron, sacada de las cuotas pagadas.',
  },
  castigado: {
    label: 'Perdido',
    what: 'La deuda que se declaró incobrable al llegar el atraso a los días de expulsión (un parámetro del negocio): deja de contar en lo que se espera cobrar y pasa a pérdida.',
  },
  mora: {
    label: 'Mora (%)',
    what: 'Vencido ÷ (vencido + por vencer): la parte de las cuotas sin pagar cuyo vencimiento ya pasó, en financiamiento + fee y sin lo dado por perdido, que tiene su propia cifra.',
  },
  impago: {
    label: 'Impago sobre lo financiado (%)',
    what: 'Sin el service fee: lo dado por perdido y sin pagar ÷ todo lo financiado desde el primer día, que solo es definitivo en las semanas de financiamiento que ya terminaron su ciclo de cobro.',
  },
  puntoDeEmpate: {
    label: 'Punto de empate del impago (%)',
    what: 'El impago con el que Helios ni gana ni pierde: el service fee que pagan los que cumplen frente a lo que cuesta cada uno que no paga (el financiamiento ya transferido a la clínica más el fee que nunca se cobra).',
  },
  cobroATiempo: {
    label: 'Cobrado a tiempo (%)',
    what: 'De las cuotas cuyo plazo ya terminó (vencimiento + días de gracia), la parte pagada dentro de él, por número de cuotas y por el día en que el paciente REPORTÓ el pago (no el de la aprobación).',
  },
}
/** Lo que suman todos los locales, que es lo que miran Hoy y Dinero. */
export type PayablesTotals = {
  /** Lo que hay que transferir en el próximo cierre, atrasados incluidos. */
  saleEsteCierre: number
  /** Cierres que ya pasaron y siguen sin transferirse. */
  atrasado: number
  /** Lo pendiente después del próximo cierre: sobre todo previsión de cuotas por vencer, que todavía no son liquidaciones. */
  comprometidoFuturo: number
  totalPendiente: number
  /** El lunes del próximo cierre. Igual para todos los locales. */
  fechaCierre: string | null
  /** Cuántos locales tienen algo atrasado. */
  localesAtrasados: number
}

/**
 * Lo que se le deberá a un local después del próximo cierre: todo lo
 * pendiente menos lo que sale en ese cierre, que ya lleva dentro lo atrasado.
 */
export function comprometidoFuturoDe(m: Pick<MerchantPayable, 'totalPendingUsd' | 'nextRunUsd'>): number {
  return Math.max(0, m.totalPendingUsd - m.nextRunUsd)
}

export function payablesTotals(rows: MerchantPayable[] | undefined): PayablesTotals {
  // Los locales de prueba NO suman, aunque desde 20260918230000 sí lleguen en
  // la lista. Es la regla de todo el panel —la misma que Consumos— y aquí es
  // especialmente importante: de estas cifras salen Hoy, Dinero y la tarjeta
  // de «pagos a locales atrasados». Un local de prueba con deuda haría aparecer
  // una tarea que nadie tiene que hacer.
  const list = (rows ?? []).filter((m) => !m.isTest)
  const atrasado = list.reduce((s, m) => s + m.overdueUsd, 0)

  return {
    // "Salen el lunes" incluye lo que debió salir en cierres anteriores: el
    // dinero atrasado no deja de tener que salir por haberse retrasado. Y
    // `next_run_usd` (`helios_settlement_outlook`) YA lo lleva dentro: cuenta
    // todo lo devengado con vencimiento anterior al próximo cierre, atrasos
    // incluidos. Sumarle `overdue_usd` otra vez inflaba el cierre y dejaba
    // corto lo comprometido a futuro.
    saleEsteCierre: list.reduce((s, m) => s + m.nextRunUsd, 0),
    atrasado,
    comprometidoFuturo: list.reduce((s, m) => s + comprometidoFuturoDe(m), 0),
    totalPendiente: list.reduce((s, m) => s + m.totalPendingUsd, 0),
    fechaCierre: list[0]?.nextRunDate ?? null,
    localesAtrasados: list.filter((m) => m.overdueUsd > 0).length,
  }
}

/**
 * El color de una tasa de impago.
 *
 * Los umbrales de impago de los parámetros, los mismos que usa Riesgo en cada
 * cosecha; y rojo, pase lo que pase con ellos, en cuanto el impago llega al
 * punto de empate: ahí Ronda ya pierde dinero.
 */
export function tonoDelImpago(
  ratePct: number | null,
  breakEvenPct: number | null,
  parametros: Parametros | undefined,
): BadgeTone {
  if (ratePct === null) return 'neutral'
  if (breakEvenPct !== null && ratePct >= breakEvenPct) return 'error'
  return tonoImpago(ratePct, parametros)
}
