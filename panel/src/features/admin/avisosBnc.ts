/**
 * El bot de avisos del BNC: el SMS de cada pago móvil recibido llega desde el
 * Atajo del iPhone del CEO, y la base lo coteja con los pagos reportados
 * (`ronda_bank_sms_evaluate`). Aquí se lee lo que decidió frente a lo que
 * hizo el equipo.
 */

export type ModoBot = 'apagado' | 'sombra' | 'activo'

/** Lo que la base decidió con el aviso (`bank_sms_notices.outcome`). */
export type DecisionBot =
  | 'ilegible'
  | 'esperando'
  | 'varios'
  | 'telefono_distinto'
  | 'remitente_ajeno'
  | 'ya_aprobado'
  | 'aprobaria'
  | 'aprobado'
  | 'error'

export type EstadoPago = 'reported' | 'in_review' | 'reconciled' | 'rejected' | 'duplicate'

export type AvisoBnc = {
  id: string
  recibidoEn: string
  texto: string
  /** Quién mandó el SMS, según el iPhone. */
  remitente: string | null
  referencia: string | null
  montoVes: number | null
  /** «0424***9037», como lo trae el SMS. */
  telefono: string | null
  pagadoEn: string | null
  decision: DecisionBot
  modo: ModoBot | null
  decididoEn: string | null
  nota: string | null
  /** El pago lo eligió el bot. Si no, es el que tiene esa referencia, para ver qué hizo el equipo. */
  emparejadoPorBot: boolean
  pago: PagoDelAviso | null
}

export type PagoDelAviso = {
  id: string
  userId: string
  persona: string
  referencia: string
  telefono: string | null
  reportadoEn: string
  estado: EstadoPago
  revisadoEn: string | null
  revisadoPor: string | null
  motivoRechazo: string | null
  montoVes: number
  montoUsd: number
}

export type PagoSinAviso = {
  id: string
  userId: string
  persona: string
  referencia: string
  reportadoEn: string
  revisadoEn: string | null
  revisadoPor: string | null
  montoVes: number
  montoUsd: number
}

export type RevisionBot = {
  modo: ModoBot
  modoDesde: string | null
  modoPor: string | null
  /** El remitente del BNC fijado. Sin él, cualquier SMS con el mismo texto cuenta. */
  remitenteFijado: string | null
  primerAviso: string | null
  avisos: AvisoBnc[]
  sinAviso: PagoSinAviso[]
}

// ── La comparación con el equipo ─────────────────────────────────────────────────

/**
 * Cada aviso, frente a lo que hizo el equipo con su pago:
 *
 *   coinciden      el bot lo habría aprobado y el equipo lo aprobó.
 *   equipo_rechazo    el bot lo habría aprobado y el equipo lo rechazó. Es el caso que
 *                  impide activar el bot: tiene que ser cero.
 *   falta_equipo      el bot lo habría aprobado y el equipo aún no ha decidido.
 *   equipo_antes      cuando llegó el aviso, el equipo ya lo había aprobado.
 *   bot_aprobo     modo activo: lo aprobó el bot.
 *   para_equipo       el bot no se atrevió (varios, teléfono o remitente distinto,
 *                  error).
 *   sin_reporte    nadie ha reportado un pago que encaje.
 *   ilegible       el texto no es un pago móvil recibido.
 */
export type Comparacion =
  | 'coinciden'
  | 'equipo_rechazo'
  | 'falta_equipo'
  | 'equipo_antes'
  | 'bot_aprobo'
  | 'para_equipo'
  | 'sin_reporte'
  | 'ilegible'

export function comparar(aviso: AvisoBnc): Comparacion {
  switch (aviso.decision) {
    case 'ilegible':
      return 'ilegible'
    case 'esperando':
      return 'sin_reporte'
    case 'ya_aprobado':
      return 'equipo_antes'
    case 'aprobado':
      return 'bot_aprobo'
    case 'varios':
    case 'telefono_distinto':
    case 'remitente_ajeno':
    case 'error':
      return 'para_equipo'
    case 'aprobaria': {
      const estado = aviso.pago?.estado
      if (estado === 'reconciled') return 'coinciden'
      if (estado === 'rejected' || estado === 'duplicate') return 'equipo_rechazo'
      return 'falta_equipo'
    }
  }
}

/** Lo que tardó el equipo en aprobar después de que el bot lo habría hecho, en segundos. */
export function ventajaDelBot(aviso: AvisoBnc): number | null {
  if (comparar(aviso) !== 'coinciden') return null
  if (!aviso.decididoEn || !aviso.pago?.revisadoEn) return null
  const s = (Date.parse(aviso.pago.revisadoEn) - Date.parse(aviso.decididoEn)) / 1000
  return Number.isFinite(s) && s > 0 ? s : null
}

export type ResumenBot = {
  avisos: number
  ilegibles: number
  /** Los que el bot aprobaría o aprobó. */
  aprobaria: number
  coinciden: number
  equipoRechazo: number
  faltaEquipo: number
  lisAntes: number
  paraEquipo: number
  sinReporte: number
  /** Mediana de lo que se habría ganado, en segundos. Null sin coincidencias medibles. */
  medianaVentaja: number | null
}

export function resumir(avisos: readonly AvisoBnc[]): ResumenBot {
  const cuenta = (c: Comparacion) => avisos.filter((a) => comparar(a) === c).length
  const ventajas = avisos
    .map(ventajaDelBot)
    .filter((s): s is number => s !== null)
    .sort((a, b) => a - b)

  let mediana: number | null = null
  if (ventajas.length > 0) {
    const mitad = Math.floor(ventajas.length / 2)
    mediana = ventajas.length % 2 === 1 ? ventajas[mitad] : (ventajas[mitad - 1] + ventajas[mitad]) / 2
  }

  return {
    avisos: avisos.length,
    ilegibles: cuenta('ilegible'),
    aprobaria: avisos.filter((a) => a.decision === 'aprobaria' || a.decision === 'aprobado').length,
    coinciden: cuenta('coinciden'),
    equipoRechazo: cuenta('equipo_rechazo'),
    faltaEquipo: cuenta('falta_equipo'),
    lisAntes: cuenta('equipo_antes'),
    paraEquipo: cuenta('para_equipo'),
    sinReporte: cuenta('sin_reporte'),
    medianaVentaja: mediana,
  }
}
