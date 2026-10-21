import { formatDay, formatUsd, formatPhone, formatVes } from '@/components/ui'
import { TRAMOS_VENCIDOS, rotuloDeTramo, tramoDe } from '@/features/admin/tramos'
import type { CortesDeTramo, TramoVencido } from '@/features/admin/tramos'

// ═══════════════════════════════════════════════════════════════════════════
// Las plantillas de WhatsApp de cobranza.
//
// Un mensaje por tramo de atraso (`tramos.ts`): no se le escribe igual a
// quien lleva tres días que a quien lleva cuarenta. Solo para quien debe algo
// vencido: los recordatorios antes del vencimiento y el del día salen solos
// por WhatsApp y correo (crons cuota_en_3_dias, cuota_manana, cuota_hoy). Las variables se rellenan con los datos de la
// persona y con la cuenta de cobro que esté activa hoy, que es el error más
// caro de todos: un mensaje con la cuenta vieja manda el dinero a un sitio
// donde nadie lo va a aprobar.
//
// El texto vive en `collection_templates` y se edita en Cobranza ›
// Recordatorios › Plantillas de WhatsApp. Aquí queda el relleno, que es lo
// único que pasa en el navegador. Módulo puro.
// ═══════════════════════════════════════════════════════════════════════════

export type VariablesPlantilla = {
  nombre: string
  monto_bs: string
  monto_usd: string
  fecha_vencimiento: string
  banco: string
  telefono_pago: string
  cedula_pago: string
  /** «12 días». */
  dias_atraso: string
}

/** Las cuatro plantillas que usa el panel, una por tramo, en el orden en que se enseñan. */
export type ClavePlantilla = TramoVencido

export const CLAVES_PLANTILLA: readonly ClavePlantilla[] = TRAMOS_VENCIDOS

/**
 * La plantilla que le toca a una persona: la de su tramo. `null` si no debe
 * nada vencido: a ella no se le escribe desde cobranza (sus recordatorios
 * salen solos). Los tramos se calculan con los mismos cortes que el filtro
 * de la cartera.
 */
export function claveDePlantilla(
  persona: { daysOverdue: number },
  cortes: CortesDeTramo,
): ClavePlantilla | null {
  const tramo = tramoDe(persona.daysOverdue, cortes)
  return tramo === 'al_dia' ? null : tramo
}

/**
 * Cuándo se usa cada plantilla, en palabras: «1–7 días de atraso». `null`
 * si aún no se conocen los cortes.
 */
export function cuandoSeUsa(clave: ClavePlantilla, cortes: CortesDeTramo | null): string | null {
  return cortes ? `${rotuloDeTramo(clave, cortes)} de atraso` : null
}

/** «1 día», «12 días». */
export function diasDeAtraso(dias: number): string {
  return `${dias} ${dias === 1 ? 'día' : 'días'}`
}

/** Sustituye `{variable}` por su valor. Lo que no encaje se deja tal cual. */
export function rellenar(texto: string, vars: VariablesPlantilla): string {
  const valores: Partial<Record<string, string>> = vars
  // `hasOwn`: sin él, `{toString}` saldría como el código de una función.
  return texto.replace(/\{(\w+)\}/g, (match, clave: string) =>
    Object.hasOwn(valores, clave) ? (valores[clave] ?? match) : match,
  )
}

/**
 * Los datos de la vista previa. Inventados y con aspecto de inventados: nadie
 * debe confundir la vista previa con un mensaje de verdad.
 */
export const EJEMPLO_DE_COBRO: VariablesPlantilla = {
  nombre: 'Ana',
  monto_usd: formatUsd(12.5),
  monto_bs: formatVes(12_187.5),
  fecha_vencimiento: formatDay('2026-10-02'),
  banco: 'Banco de Ejemplo',
  telefono_pago: '0414-0000000',
  cedula_pago: 'J-00000000-0',
  dias_atraso: diasDeAtraso(12),
}

/** Lo que hace falta para escribirle a una persona. */
export type DatosDeCobro = {
  persona: {
    fullName: string | null
    /** PAYABLE: deuda vencida. */
    overdueUsd: number
    /** PAYABLE: lo que vence en los próximos días. */
    upcomingUsd: number
    /**
     * Lo mismo dicho en la moneda de cada orden («€56,96 + $2») y en bolívares
     * de hoy, cada parte a la tasa BCV de su moneda, como lo manda la cartera
     * (2026-10-07). Sin ellos, en dólares a la tasa del dólar, como antes.
     */
    overdueText?: string | null
    overdueVesHoy?: number | null
    upcomingText?: string | null
    upcomingVesHoy?: number | null
    nextDueDate: string
    daysOverdue: number
  }
  /** La tasa BCV del día; sin ella el monto en bolívares se dice con palabras. */
  tasa: number | null
  cuenta: { bankName: string; rif: string; phone: string } | null
}

/** Si el texto habla de la cuenta donde se paga. */
export function usaLaCuenta(texto: string): boolean {
  return /\{(banco|telefono_pago|cedula_pago)\}/.test(texto)
}

/**
 * El mensaje de cobro de una persona. La deuda que se pide es la vencida y,
 * si no hay vencida, la que está por vencer.
 *
 * Quien lo llama comprueba antes `usaLaCuenta`: un mensaje que pide pagar a
 * una cuenta en blanco no se manda.
 */
export function mensajeDeCobro(plantilla: string, d: DatosDeCobro): string {
  const vencida = d.persona.overdueUsd > 0
  const deuda = vencida ? d.persona.overdueUsd : d.persona.upcomingUsd
  // Una orden puede ir en euros: lo que dice la cartera en su moneda y en
  // bolívares de hoy manda sobre la cuenta en dólares.
  const enSuMoneda = vencida ? d.persona.overdueText : d.persona.upcomingText
  const bs = vencida ? d.persona.overdueVesHoy : d.persona.upcomingVesHoy
  return rellenar(plantilla, {
    nombre: (d.persona.fullName ?? '').trim().split(/\s+/)[0] || 'hola',
    monto_usd: enSuMoneda ?? formatUsd(deuda),
    monto_bs:
      bs !== undefined && bs !== null
        ? formatVes(bs)
        : d.tasa
          ? formatVes(deuda * d.tasa)
          : 'el equivalente en bolívares',
    fecha_vencimiento: formatDay(d.persona.nextDueDate),
    banco: d.cuenta?.bankName ?? '',
    telefono_pago: d.cuenta ? formatPhone(d.cuenta.phone) : '',
    cedula_pago: d.cuenta?.rif ?? '',
    dias_atraso: diasDeAtraso(d.persona.daysOverdue),
  })
}
