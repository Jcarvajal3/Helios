import { formatUsd } from '@/components/ui'
import type { Desglose } from '@/features/admin/metricas/lectura'

// ═══════════════════════════════════════════════════════════════════════════
// Cómo se escribe, en Cohortes, de qué está hecho un importe que se cobra.
//
// Cohortes habla en lo que hay que COBRAR (decisión de Javier del 27-09): el
// total a cobrar de una semana es la cuota 1 + la cuota 2, con el service
// fee dentro. Es la excepción aprobada a la regla de no sumar el fee a un
// total, y vale SOLO porque va siempre con sus dos sumandos a la vista: el
// facturado (lo consumido en los locales, sin fee) y el service fee con su
// IVA. Lo mismo cada cuota, lo cobrado, lo vencido y lo por vencer. Las
// palabras son las del vocabulario de Métricas: «Facturado (sin fee)» y
// «Service fee + IVA», iguales que en Semana › Resumen.
//
//   lineaDelDesglose(d)   'Facturado €1.152,00 (sin fee) · service fee + IVA €267,26'
//   desgloseCorto(d)      'facturado €1.152,00 · fee + IVA €267,26'
//   desgloseEnFrase(d)    'facturado €1.152,00 + service fee + IVA €267,26'
//
// Puro: se prueba en `desglose.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** La línea que va debajo de un importe que se cobra, en pequeño: una tarjeta, una cifra. */
export function lineaDelDesglose({ financedUsd, feeUsd }: Pick<Desglose, 'financedUsd' | 'feeUsd'>): string {
  return `Financiado ${formatUsd(financedUsd)} (sin fee) · service fee + IVA ${formatUsd(feeUsd)}`
}

/** El desglose en un sitio estrecho (una celda de tabla, un globo): la cabecera dice qué es la cifra. */
export function desgloseCorto({ financedUsd, feeUsd }: Pick<Desglose, 'financedUsd' | 'feeUsd'>): string {
  return `financiado ${formatUsd(financedUsd)} · fee + IVA ${formatUsd(feeUsd)}`
}

/** El desglose dentro de una frase, para ir entre paréntesis detrás del importe. */
export function desgloseEnFrase({ financedUsd, feeUsd }: Pick<Desglose, 'financedUsd' | 'feeUsd'>): string {
  return `financiado ${formatUsd(financedUsd)} + service fee + IVA ${formatUsd(feeUsd)}`
}

/** Un importe con su desglose en una sola línea de texto: para una tabla plegada o un CSV leído. */
export function importeYDesglose(d: Desglose): string {
  return `${formatUsd(d.payableUsd)} (${desgloseCorto(d)})`
}
