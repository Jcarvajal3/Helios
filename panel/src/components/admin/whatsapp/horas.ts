import { TIME_ZONE } from '@/components/ui'

/** El día de un instante en Caracas, `2026-10-19`. */
function diaEnCaracas(ms: number): string {
  return new Date(ms).toLocaleDateString('en-CA', { timeZone: TIME_ZONE })
}

/** «14:32» si es de hoy, «18/10» si no. Como la lista de chats de WhatsApp. */
export function horaCorta(ms: number | null, ahora = Date.now()): string {
  if (ms === null) return ''
  if (diaEnCaracas(ms) === diaEnCaracas(ahora)) return hora(ms)
  return new Date(ms).toLocaleDateString('es-VE', {
    day: '2-digit',
    month: '2-digit',
    timeZone: TIME_ZONE,
  })
}

/** «Hoy», «Ayer» o «18 de octubre», para separar los mensajes por día. */
export function rotuloDelDia(ms: number, ahora = Date.now()): string {
  const dia = diaEnCaracas(ms)
  if (dia === diaEnCaracas(ahora)) return 'Hoy'
  if (dia === diaEnCaracas(ahora - 86_400_000)) return 'Ayer'
  return new Date(ms).toLocaleDateString('es-VE', {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
    timeZone: TIME_ZONE,
  })
}

export function diaDe(ms: number): string {
  return diaEnCaracas(ms)
}

/** «14:32» en Caracas. */
export function hora(ms: number): string {
  return new Date(ms).toLocaleTimeString('es-VE', {
    hour: '2-digit',
    minute: '2-digit',
    timeZone: TIME_ZONE,
  })
}
