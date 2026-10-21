import { TIME_ZONE, diaOperativo } from '@/components/ui'
import { MESES_CORTOS } from '@/components/kit/rango'
import { diaDeLaSemana } from '@/features/admin/semana'

// ═══════════════════════════════════════════════════════════════════════════
// El día operativo y la hora de Caracas, para Inicio.
// ═══════════════════════════════════════════════════════════════════════════

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
