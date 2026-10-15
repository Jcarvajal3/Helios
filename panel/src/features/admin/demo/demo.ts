import { booleano, comoFila, comoLista, numero, numeroONulo, texto } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Los números de capacitación (20261014100200).
//
// Lo único fijo en una capacitación es el WhatsApp de quien capacita. El
// médico registra un paciente nuevo con datos inventados y ese número, en su
// panel o en su bot: el paciente nace de prueba, la pregunta llega a ese
// WhatsApp y el médico ve todo el proceso. A medianoche se borran del todo,
// el paciente y sus órdenes: la cédula vuelve a ser «nuevo» (20261014100300).
//
// Módulo puro, probado en `demo.test.ts`; las llamadas, en `api.ts`.
// ═══════════════════════════════════════════════════════════════════════════

export type NumeroDeCapacitacion = {
  phone: string
  label: string
  /** Pacientes de prueba de hoy con ese número (los retirados no cuentan). */
  patients: number
  /** Órdenes confirmadas que el próximo reinicio revertirá. */
  openOrders: number
  /** Preguntas esperando el «sí». */
  pendingOrders: number
}

export type ReinicioDeDemo = {
  revertidas: number
  anuladas: number
  /** Pacientes borrados del todo, con sus órdenes (20261014100300). */
  borrados: number
  ordenesBorradas: number
  /** Los que tenían asiento en el libro (de antes de 20261014100300): sin cédula. */
  retirados: number
  sinReiniciar: Array<{ orderNumber: number | null; motivo: string }>
}

export type EstadoDeDemo = {
  numeros: NumeroDeCapacitacion[]
  ultimoReinicio: (ReinicioDeDemo & { at: string; automatico: boolean }) | null
}

export function leerReinicio(raw: unknown): ReinicioDeDemo {
  const r = comoFila(raw)
  return {
    revertidas: numero(r.revertidas),
    anuladas: numero(r.anuladas),
    borrados: numero(r.borrados),
    ordenesBorradas: numero(r.ordenes_borradas),
    retirados: numero(r.retirados),
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
    numeros: comoLista(r.phones).map((x) => {
      const p = comoFila(x)
      return {
        phone: texto(p.phone_e164),
        label: texto(p.label),
        patients: numero(p.patients),
        openOrders: numero(p.open_orders),
        pendingOrders: numero(p.pending_orders),
      }
    }),
    ultimoReinicio: ultimo
      ? { ...leerReinicio(ultimo.detail), at: texto(ultimo.at), automatico: booleano(ultimo.automatic) }
      : null,
  }
}

function contar(n: number, uno: string, varios: string): string {
  return `${n} ${n === 1 ? uno : varios}`
}

/** El resumen de un reinicio, en una línea. */
export function resumenDeReinicio(r: ReinicioDeDemo): string {
  const partes: string[] = []
  if (r.borrados > 0) {
    partes.push(
      `${contar(r.borrados, 'paciente borrado', 'pacientes borrados')} con ${contar(r.ordenesBorradas, 'orden', 'órdenes')}`,
    )
  }
  if (r.revertidas > 0) partes.push(contar(r.revertidas, 'orden revertida', 'órdenes revertidas'))
  if (r.retirados > 0) partes.push(contar(r.retirados, 'paciente retirado', 'pacientes retirados'))
  if (r.sinReiniciar.length > 0) partes.push(`${r.sinReiniciar.length} sin reiniciar`)
  return partes.length > 0 ? partes.join(', ') : 'No había nada que reiniciar'
}

export type BorradorDeNumero = { phone: string; label: string }

export const BORRADOR_VACIO: BorradorDeNumero = { phone: '', label: '' }

/** Lo que falta para poder añadir; el servidor valida el formato. */
export function faltaEnBorrador(b: BorradorDeNumero): string | undefined {
  if (!b.phone.trim()) return 'Falta el WhatsApp de quien capacita.'
  if (!b.label.trim()) return 'Falta quién capacita con ese número.'
  return undefined
}
