import { MESES_CORTOS, sumarDias } from '@/components/kit/rango'
import { diaDeLaSemana } from '@/features/admin/semana'

// ═══════════════════════════════════════════════════════════════════════════
// Cómo se nombra una semana en la pestaña Locales: «3–9 ago», «31 ago–6 sep».
//
// Los días van como texto 'YYYY-MM-DD' y se suman con `sumarDias` (Date.UTC):
// nunca `new Date('2026-09-21')`, que en Caracas es el domingo 20.
//
// Puro: se prueba en `semanas.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

function partes(dia: string): { anio: number; mes: number; dia: number } {
  const [y = '0', m = '1', d = '1'] = dia.slice(0, 10).split('-')
  return { anio: Number(y), mes: Number(m), dia: Number(d) }
}

function mesCorto(mes: number): string {
  return MESES_CORTOS[mes - 1] ?? String(mes)
}

/**
 * La semana que empieza en `lunes`, en corto: «3–9 ago», «31 ago–6 sep» si
 * cambia de mes y «29 dic 2025–4 ene 2026» si cambia de año.
 */
export function semanaCorta(lunes: string): string {
  const a = partes(lunes)
  const b = partes(sumarDias(lunes, 6))
  if (a.anio !== b.anio) return `${a.dia} ${mesCorto(a.mes)} ${a.anio}–${b.dia} ${mesCorto(b.mes)} ${b.anio}`
  if (a.mes !== b.mes) return `${a.dia} ${mesCorto(a.mes)}–${b.dia} ${mesCorto(b.mes)}`
  return `${a.dia}–${b.dia} ${mesCorto(b.mes)}`
}

/** «del 14 al 20 sep», «del 31 ago al 6 sep»: la semana dentro de una frase. */
export function semanaEnFrase(lunes: string): string {
  const a = partes(lunes)
  const b = partes(sumarDias(lunes, 6))
  return a.mes === b.mes
    ? `del ${a.dia} al ${b.dia} ${mesCorto(b.mes)}`
    : `del ${a.dia} ${mesCorto(a.mes)} al ${b.dia} ${mesCorto(b.mes)}`
}

/** «lunes 28»: el día del cierre de caja, que siempre es un lunes. */
export function diaConNumero(dia: string): string {
  return `${diaDeLaSemana(dia)} ${partes(dia).dia}`
}

/** «7 sep»: un día suelto en corto. */
export function diaCorto(dia: string): string {
  const p = partes(dia)
  return `${p.dia} ${mesCorto(p.mes)}`
}
