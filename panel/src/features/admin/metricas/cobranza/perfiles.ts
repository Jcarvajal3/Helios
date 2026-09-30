import type { BadgeTone } from '@/components/ui'

// ═══════════════════════════════════════════════════════════════════════════
// Los perfiles de deudor: cómo se llaman, qué prioridad tienen y qué quiere
// decir cada uno.
//
// Quién cae en cada perfil lo decide la base (`metricas.perfil_deudor`,
// CONTRATOS §8), no el panel: la sección de Métricas y la cola de Por cobrar
// leen el mismo perfil. Aquí solo se nombran, y las definiciones se escriben
// con los umbrales que manda la base, para que ningún número del texto se
// quede viejo si cambian.
//
// Puro: se prueba en `deudores.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** En el orden en que se trabajan: el primero que encaja gana. */
export const PERFILES_DEUDOR = [
  'nunca_ha_pagado',
  'promesa_rota',
  'sin_respuesta',
  'reincidente',
  'paga_tarde_pero_paga',
  'se_le_paso',
  'vigilar',
] as const

export type PerfilDeudor = (typeof PERFILES_DEUDOR)[number]

export const PRIORIDADES = ['alta', 'media', 'baja'] as const
export type Prioridad = (typeof PRIORIDADES)[number]

/** Los umbrales con que la base reparte a la gente (`metricas.perfil_deudor_umbrales`). */
export type UmbralesDePerfil = {
  promesaRotaDias: number
  sinRespuestaGestiones: number
  sinRespuestaDiasAtraso: number
  sinRespuestaHoras: number
  reincidenteTarde: number
  seLePasoDias: number
  seLePasoPct: number
  vigilarDias: number
  vigilarPctTarde: number
  vigilarMinPagadas: number
  recuperacionDias: number
}

/** Los del contrato: se usan solo mientras la respuesta no los trae. */
export const UMBRALES_DEL_CONTRATO: UmbralesDePerfil = {
  promesaRotaDias: 14,
  sinRespuestaGestiones: 2,
  sinRespuestaDiasAtraso: 7,
  sinRespuestaHoras: 72,
  reincidenteTarde: 2,
  seLePasoDias: 3,
  seLePasoPct: 80,
  vigilarDias: 3,
  vigilarPctTarde: 50,
  vigilarMinPagadas: 2,
  recuperacionDias: 30,
}

/**
 * El nombre de cada perfil dice qué lo define (auditoría de rigor del
 * 27-09: nada de metáforas). Las claves no cambian: las usan la base, la URL
 * (`perfil=`) y Por cobrar.
 */
export const ROTULO_PERFIL: Record<PerfilDeudor, string> = {
  nunca_ha_pagado: 'Ninguna cuota pagada',
  promesa_rota: 'Promesa de pago incumplida',
  sin_respuesta: 'Sin respuesta a las gestiones',
  reincidente: 'Atrasos repetidos',
  paga_tarde_pero_paga: 'Vencido, con pagos previos',
  se_le_paso: 'Atraso de pocos días, buen historial',
  vigilar: 'Al día, con riesgo de atraso',
}

/** La prioridad de cada perfil: la misma que pone la base. */
export const PRIORIDAD_DEL_PERFIL: Record<PerfilDeudor, Prioridad> = {
  nunca_ha_pagado: 'alta',
  promesa_rota: 'alta',
  sin_respuesta: 'alta',
  reincidente: 'media',
  paga_tarde_pero_paga: 'media',
  se_le_paso: 'baja',
  vigilar: 'baja',
}

export const ROTULO_PRIORIDAD: Record<Prioridad, string> = {
  alta: 'Prioridad alta',
  media: 'Prioridad media',
  baja: 'Prioridad baja',
}

/**
 * El tono de la pastilla de prioridad. Es un estado de trabajo (a quién se
 * llama antes), así que va con color: rojo lo urgente, ámbar lo que sigue y
 * gris lo que puede esperar.
 */
export const TONO_PRIORIDAD: Record<Prioridad, BadgeTone> = {
  alta: 'error',
  media: 'warning',
  baja: 'neutral',
}

function veces(n: number, uno: string, varios: string): string {
  return `${n} ${n === 1 ? uno : varios}`
}

/** Qué quiere decir el perfil, en una frase, con los umbrales de la base. */
export function queEsElPerfil(perfil: PerfilDeudor, u: UmbralesDePerfil): string {
  switch (perfil) {
    case 'nunca_ha_pagado':
      return 'No ha pagado ninguna cuota y tiene alguna vencida.'
    case 'promesa_rota':
      return `Prometió pagar un día de los últimos ${u.promesaRotaDias} y no pagó.`
    case 'sin_respuesta':
      return `${veces(u.sinRespuestaGestiones, 'gestión', 'gestiones')} o más desde que le venció sin pago ni promesa en ${u.sinRespuestaHoras} horas, y más de ${veces(u.sinRespuestaDiasAtraso, 'día', 'días')} de atraso.`
    case 'reincidente':
      return `Ya pagó tarde ${veces(u.reincidenteTarde, 'cuota', 'cuotas')} o más y vuelve a tener algo vencido.`
    case 'paga_tarde_pero_paga':
      return 'Tiene algo vencido, ya ha pagado alguna cuota y no encaja en ningún perfil anterior.'
    case 'se_le_paso':
      return `Lleva ${veces(u.seLePasoDias, 'día', 'días')} de atraso o menos y pagó a tiempo el ${u.seLePasoPct} % de sus cuotas o más.`
    case 'vigilar':
      return `Sin nada vencido, le vence una cuota en ${veces(u.vigilarDias, 'día', 'días')} o menos y pagó tarde al menos el ${u.vigilarPctTarde} % de sus cuotas (con ${u.vigilarMinPagadas} pagadas o más).`
  }
}

/** Vigilar no está en mora: se cuenta y se enseña aparte. */
export function estaEnMora(perfil: PerfilDeudor): boolean {
  return perfil !== 'vigilar'
}
