import { booleano, comoFila, comoLista, numero, numeroONulo, texto, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Los pacientes demo de las capacitaciones (20261014100100).
//
// Quien capacita lleva su teléfono ligado a un paciente demo y va de médico en
// médico: el médico busca la cédula demo en su panel o en su bot, registra y
// el capacitador contesta «sí». Las órdenes demo no le liquidan nada a la
// clínica y se revierten cada noche a las 23:30.
//
// Módulo puro, probado en `demo.test.ts`; las llamadas, en `api.ts`.
// ═══════════════════════════════════════════════════════════════════════════

export type PacienteDemo = {
  id: string
  fullName: string
  documentNumber: string
  phone: string
  email: string | null
  usedUsd: number
  availableUsd: number
  /** Por qué no puede tomar una orden ahora (`cuota_vencida`, `estado`, `bloqueo`), o null. */
  blockedReason: string | null
  /** Órdenes esperando el «sí». Solo puede haber una a la vez por paciente. */
  pendingOrders: number
  /** Órdenes confirmadas que el próximo reinicio revertirá. */
  openOrders: number
}

export type ReinicioDeDemo = {
  revertidas: number
  anuladas: number
  sinReiniciar: Array<{ orderNumber: number | null; motivo: string }>
}

export type EstadoDeDemo = {
  limitUsd: number
  pacientes: PacienteDemo[]
  ultimoReinicio: (ReinicioDeDemo & { at: string; automatico: boolean }) | null
}

export function leerReinicio(raw: unknown): ReinicioDeDemo {
  const r = comoFila(raw)
  return {
    revertidas: numero(r.revertidas),
    anuladas: numero(r.anuladas),
    sinReiniciar: comoLista(r.sin_reiniciar).map((x) => {
      const f = comoFila(x)
      return { orderNumber: numeroONulo(f.order_number), motivo: texto(f.motivo) }
    }),
  }
}

export function leerEstadoDeDemo(raw: unknown): EstadoDeDemo {
  const r = comoFila(raw)
  const ultimo = r.last_reset == null ? null : comoFila(r.last_reset)
  return {
    limitUsd: numero(r.limit_usd),
    pacientes: comoLista(r.patients).map((x) => {
      const p = comoFila(x)
      return {
        id: texto(p.id),
        fullName: texto(p.full_name),
        documentNumber: texto(p.document_number),
        phone: texto(p.phone_e164),
        email: textoONulo(p.email),
        usedUsd: numero(p.used_usd),
        availableUsd: numero(p.available_usd),
        blockedReason: textoONulo(p.blocked_reason),
        pendingOrders: numero(p.pending_orders),
        openOrders: numero(p.open_orders),
      }
    }),
    ultimoReinicio: ultimo
      ? { ...leerReinicio(ultimo.detail), at: texto(ultimo.at), automatico: booleano(ultimo.automatic) }
      : null,
  }
}

/** El resumen de un reinicio, en una línea. */
export function resumenDeReinicio(r: ReinicioDeDemo): string {
  const partes: string[] = []
  if (r.revertidas > 0) partes.push(`${r.revertidas} ${r.revertidas === 1 ? 'orden revertida' : 'órdenes revertidas'}`)
  if (r.anuladas > 0) partes.push(`${r.anuladas} ${r.anuladas === 1 ? 'pregunta anulada' : 'preguntas anuladas'}`)
  if (r.sinReiniciar.length > 0) {
    partes.push(`${r.sinReiniciar.length} sin reiniciar`)
  }
  return partes.length > 0 ? partes.join(', ') : 'No había nada que reiniciar'
}

export type BorradorDePacienteDemo = {
  document: string
  firstName: string
  lastName: string
  phone: string
  email: string
}

export const BORRADOR_VACIO: BorradorDePacienteDemo = {
  document: '',
  firstName: '',
  lastName: '',
  phone: '',
  email: '',
}

/** Lo que falta para poder crear; el servidor valida el formato. */
export function faltaEnBorrador(b: BorradorDePacienteDemo): string | undefined {
  if (!b.document.trim()) return 'Falta la cédula demo.'
  if (!b.firstName.trim() || !b.lastName.trim()) return 'Faltan el nombre y el apellido.'
  if (!b.phone.trim()) return 'Falta el WhatsApp de quien da la capacitación.'
  if (!b.email.trim()) return 'Falta el correo: ahí llega el comprobante.'
  return undefined
}
