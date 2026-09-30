import { MESES_LARGOS, formatDayShort, sumarDias } from '@/components/ui'

// ═══════════════════════════════════════════════════════════════════════════
// Cómo se nombra una semana de consumo y los vencimientos de sus cuotas.
//
//   rotuloDeSemana('2026-09-21')          '21–27 sep'
//   rotuloDeSemana('2026-08-31')          '31 ago–6 sep'
//   semanaLarga('2026-09-21')             'del 21 al 27 de septiembre'
//   rangoDeVencimiento('2026-09-28', '2026-10-04')   'del 28 sep al 4 oct'
//
// Los días van como texto 'YYYY-MM-DD' y se suman con `Date.UTC`
// (`sumarDias`): con `new Date('2026-09-21')` en Caracas el lunes sale
// domingo.
//
// Puro: se prueba en `semanas.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

function partes(dia: string): { anio: string; mes: number; dia: number } {
  const [anio = '', mes = '1', d = '1'] = dia.slice(0, 10).split('-')
  return { anio, mes: Number(mes), dia: Number(d) }
}

/** El domingo que cierra la semana del lunes `lunes`. */
export function domingoDeLaSemana(lunes: string): string {
  return sumarDias(lunes, 6)
}

/** '21–27 sep', o '31 ago–6 sep' si la semana cruza de mes. Para una lista o un eje. */
/**
 * El nombre de una cohorte: A1 es la semana del primer consumo de Ronda y
 * cada semana siguiente suma uno, haya tenido consumo o no. Así el nombre de
 * una semana no cambia con el local elegido ni cuando llegan semanas nuevas.
 * `primerLunes` es el lunes de la cohorte más vieja de TODOS los locales.
 */
export function nombreDeCohorte(lunes: string, primerLunes: string): string {
  const semanas = Math.round((Date.parse(`${lunes}T00:00:00Z`) - Date.parse(`${primerLunes}T00:00:00Z`)) / 604_800_000)
  return `A${semanas + 1}`
}

export function rotuloDeSemana(lunes: string): string {
  const domingo = domingoDeLaSemana(lunes)
  const a = partes(lunes)
  const b = partes(domingo)
  if (a.mes === b.mes) return `${a.dia}–${formatDayShort(domingo)}`
  return `${formatDayShort(lunes)}–${formatDayShort(domingo)}`
}

/**
 * 'del 21 al 27 de septiembre', 'del 31 de agosto al 6 de septiembre'. El año
 * solo sale si la semana cruza de uno a otro: dentro del año no dice nada.
 */
export function semanaLarga(lunes: string): string {
  const domingo = domingoDeLaSemana(lunes)
  const a = partes(lunes)
  const b = partes(domingo)
  const mesA = MESES_LARGOS[a.mes - 1] ?? String(a.mes)
  const mesB = MESES_LARGOS[b.mes - 1] ?? String(b.mes)
  if (a.anio !== b.anio) return `del ${a.dia} de ${mesA} de ${a.anio} al ${b.dia} de ${mesB} de ${b.anio}`
  if (a.mes === b.mes) return `del ${a.dia} al ${b.dia} de ${mesA}`
  return `del ${a.dia} de ${mesA} al ${b.dia} de ${mesB}`
}

/**
 * Cuándo vencen las cuotas de una tanda: 'el 28 sep' si es un solo día,
 * 'del 28 sep al 4 oct' si son varios, 'del 21 al 27 sep' en el mismo mes.
 */
export function rangoDeVencimiento(desde: string, hasta: string): string {
  if (desde === hasta) return `el ${formatDayShort(desde)}`
  const a = partes(desde)
  const b = partes(hasta)
  if (a.mes === b.mes && a.anio === b.anio) return `del ${a.dia} al ${formatDayShort(hasta)}`
  return `del ${formatDayShort(desde)} al ${formatDayShort(hasta)}`
}

/** El día de la curva en palabras: '6 días antes', 'vence', '+1 día', '+14 días'. */
export function rotuloDeDia(dia: number): string {
  if (dia === 0) return 'vence'
  const n = Math.abs(dia)
  const dias = n === 1 ? 'día' : 'días'
  return dia < 0 ? `${n} ${dias} antes` : `+${n} ${dias}`
}
