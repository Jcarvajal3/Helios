import { TIME_ZONE, diaOperativo } from '@/components/ui'
import { MESES_CORTOS } from '@/components/kit/rango'
import { diaDeLaSemana } from '@/features/admin/semana'

// ═══════════════════════════════════════════════════════════════════════════
// El día operativo y la hora de Caracas, para Inicio.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * A qué hora de Caracas cambia el día operativo: medianoche (plan H2). En
 * Ronda eran las 10:00, porque la madrugada era de la noche anterior.
 */
export const HORA_DEL_CORTE = 0

/** La hora del corte como se escribe. */
export const HORA_DEL_CORTE_ESCRITA = 'medianoche'

const MINUTOS_DEL_DIA = 24 * 60

/** El día operativo de un instante (por defecto, ahora): 'YYYY-MM-DD'. */
export function hoyOperativo(ahora: Date = new Date()): string {
  return diaOperativo(ahora)
}

const HORA_Y_MINUTO = new Intl.DateTimeFormat('en-GB', {
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
  timeZone: TIME_ZONE,
})

/** La hora y el minuto de Caracas de un instante, en números: 15 y 42. */
export function horaYMinutoDeCaracas(ahora: Date): { hora: number; minuto: number } {
  const partes = HORA_Y_MINUTO.formatToParts(ahora)
  // `% 24`: algunos motores escriben la medianoche como «24».
  const hora = Number(partes.find((p) => p.type === 'hour')?.value ?? '0') % 24
  const minuto = Number(partes.find((p) => p.type === 'minute')?.value ?? '0')
  return { hora, minuto }
}

/**
 * Minutos hasta el próximo cambio de día operativo, la medianoche de Caracas.
 * A medianoche en punto el día acaba de empezar: faltan veinticuatro horas.
 */
export function minutosHastaElCorte(ahora: Date): number {
  const { hora, minuto } = horaYMinutoDeCaracas(ahora)
  const faltan = HORA_DEL_CORTE * 60 - (hora * 60 + minuto)
  return faltan > 0 ? faltan : faltan + MINUTOS_DEL_DIA
}

/** Cuánto falta, para leerlo de un vistazo: '18 h 45 min', '2 h', '45 min'. */
export function duracionCorta(minutos: number): string {
  const total = Math.max(0, Math.round(minutos))
  const horas = Math.floor(total / 60)
  const resto = total % 60
  if (horas === 0) return `${resto} min`
  return resto === 0 ? `${horas} h` : `${horas} h ${resto} min`
}

/** La hora de Caracas de un instante, como se dice: '3:15 p. m.'. */
export function horaDeCaracas(ahora: Date): string {
  return ahora.toLocaleTimeString('es-VE', {
    hour: 'numeric',
    minute: '2-digit',
    timeZone: TIME_ZONE,
  })
}

/** Un día suelto con su nombre, corto: '2026-09-25' → 'Viernes 25 sep'. */
export function diaCortoConNombre(dia: string): string {
  const [, m = '', d = ''] = dia.slice(0, 10).split('-')
  const nombre = diaDeLaSemana(dia)
  const conMayuscula = nombre.charAt(0).toLocaleUpperCase('es') + nombre.slice(1)
  return `${conMayuscula} ${Number(d)} ${MESES_CORTOS[Number(m) - 1] ?? m}`
}
