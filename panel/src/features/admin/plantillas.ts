import { formatDay, formatUsd, formatPhone, formatVes } from '@/components/ui'
import { TRAMOS_VENCIDOS, rotuloDeTramo, tramoDe } from '@/features/admin/tramos'
import type { CortesDeTramo, TramoVencido } from '@/features/admin/tramos'

// ═══════════════════════════════════════════════════════════════════════════
// Las plantillas de WhatsApp de cobranza.
//
// Un mensaje por momento: antes de vencer, el día que vence y uno por cada
// tramo de atraso (`tramos.ts`). No se le escribe igual a quien vence mañana
// que a quien lleva cuarenta días. Las variables se rellenan con los datos de la
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
  /** «12 días». Solo la ofrecen las plantillas de tramo. */
  dias_atraso: string
}

/** Las siete plantillas que usa el panel, en el orden en que se enseñan. */
export type ClavePlantilla = 'por_vencer' | 'vence_hoy' | TramoVencido

export const CLAVES_PLANTILLA: readonly ClavePlantilla[] = ['por_vencer', 'vence_hoy', ...TRAMOS_VENCIDOS]

/**
 * La plantilla que le toca a una persona: la de su tramo si debe algo
 * vencido y, si no, la de antes de vencer o la del día del vencimiento.
 * Los tramos se calculan con los mismos cortes que el filtro de la cartera.
 */
export function claveDePlantilla(
  persona: { daysOverdue: number; bucket: string },
  cortes: CortesDeTramo,
): ClavePlantilla {
  const tramo = tramoDe(persona.daysOverdue, cortes)
  if (tramo !== 'al_dia') return tramo
  return persona.bucket === 'vence_hoy' ? 'vence_hoy' : 'por_vencer'
}

/**
 * Cuándo se usa cada plantilla, en palabras: «Antes del vencimiento»,
 * «1–3 días de atraso». `null` si es un tramo y aún no se conocen los cortes.
 */
export function cuandoSeUsa(clave: ClavePlantilla, cortes: CortesDeTramo | null): string | null {
  if (clave === 'por_vencer') return 'Antes del vencimiento'
  if (clave === 'vence_hoy') return 'El día del vencimiento'
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
  const deuda = d.persona.overdueUsd > 0 ? d.persona.overdueUsd : d.persona.upcomingUsd
  return rellenar(plantilla, {
    nombre: (d.persona.fullName ?? '').trim().split(/\s+/)[0] || 'hola',
    monto_usd: formatUsd(deuda),
    monto_bs: d.tasa ? formatVes(deuda * d.tasa) : 'el equivalente en bolívares',
    fecha_vencimiento: formatDay(d.persona.nextDueDate),
    banco: d.cuenta?.bankName ?? '',
    telefono_pago: d.cuenta ? formatPhone(d.cuenta.phone) : '',
    cedula_pago: d.cuenta?.rif ?? '',
    dias_atraso: diasDeAtraso(d.persona.daysOverdue),
  })
}
