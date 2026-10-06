import { formatPct } from '@/components/ui'
import type { BadgeTone } from '@/components/ui'
import type { Destino } from '@/features/admin/catalogo'
import { contar, senalDelCierre } from './cifras'
import type { DeudaVencida, ImpagoPrimeraCuota, LecturaDeCifra } from './cifras'
import type { VeredictoDelCierre } from './numeros'
import type { Pendiente } from './tarjetasDePendiente'

// ═══════════════════════════════════════════════════════════════════════════
// La tira de la charla de Inicio: lo pendiente y tres cifras, plegados en
// pastillas mientras la conversación ocupa la pantalla. Módulo puro.
//
// Salen de las mismas lecturas que las tarjetas: la pastilla y la tarjeta no
// pueden decir cosas distintas. Lo que todavía carga no se pinta; lo que
// falló lo dice, nunca con un cero.
// ═══════════════════════════════════════════════════════════════════════════

export type PastillaDeLaCharla = {
  clave: 'pendientes' | 'mora' | 'cierre' | 'impago'
  texto: string
  tono: BadgeTone
  /** Adónde lleva. `null`: de vuelta a Inicio, que es donde está lo pendiente. */
  destino: Destino | null
}

const A_COBRANZA: Destino = { to: '/admin/cobranza' }
const AL_CIERRE: Destino = { to: '/admin/pagos-clinicas' }
const A_LA_PRIMERA_CUOTA: Destino = { to: '/admin/metricas', search: { vista: 'cobros', sub: 'impago-por-cuota' } }

const SIN_LEER = 'no se pudo leer'

type Base = Pick<PastillaDeLaCharla, 'clave' | 'destino'>

function dePendiente(p: Pendiente<unknown>): PastillaDeLaCharla | null {
  const base: Base = { clave: 'pendientes', destino: null }
  if (p.estado === 'cargando') return null
  if (p.estado === 'al-dia') return { ...base, texto: 'Todo al día', tono: 'success' }
  if (p.pendientes === 0) return { ...base, texto: `Pendiente: ${SIN_LEER}`, tono: 'neutral' }
  return { ...base, texto: contar(p.pendientes, 'pendiente', 'pendientes'), tono: p.urgencia }
}

function deMora(l: LecturaDeCifra<Pick<DeudaVencida, 'senal'> | null>): PastillaDeLaCharla | null {
  const base: Base = { clave: 'mora', destino: A_COBRANZA }
  if (l.estado === 'cargando') return null
  if (l.estado === 'error') return { ...base, texto: `Mora: ${SIN_LEER}`, tono: 'neutral' }
  // Sin deuda viva no hay tasa: no es un 0 %.
  const senal = l.datos?.senal
  return senal ? { ...base, texto: senal.texto, tono: senal.tone } : null
}

function deCierre(l: LecturaDeCifra<{ veredicto: VeredictoDelCierre }>): PastillaDeLaCharla | null {
  const base: Base = { clave: 'cierre', destino: AL_CIERRE }
  if (l.estado === 'cargando') return null
  if (l.estado === 'error') return { ...base, texto: `Pago de hoy: ${SIN_LEER}`, tono: 'neutral' }
  const senal = senalDelCierre(l.datos.veredicto)
  return { ...base, texto: `Pago de hoy: ${senal.texto.toLocaleLowerCase('es')}`, tono: senal.tone }
}

function deImpago(l: LecturaDeCifra<Pick<ImpagoPrimeraCuota, 'pct' | 'senal'>>): PastillaDeLaCharla | null {
  const base: Base = { clave: 'impago', destino: A_LA_PRIMERA_CUOTA }
  if (l.estado === 'cargando') return null
  if (l.estado === 'error') return { ...base, texto: `Impago cuota 1: ${SIN_LEER}`, tono: 'neutral' }
  const { pct, senal } = l.datos
  if (pct === null) return null
  return { ...base, texto: `Impago cuota 1 ${formatPct(pct)}`, tono: senal?.tone ?? 'neutral' }
}

/** Las pastillas de la tira, en el orden de la pantalla normal: lo pendiente y las cifras. */
export function pastillasDeLaCharla({
  pendiente,
  mora,
  cierre,
  impago,
}: {
  pendiente: Pendiente<unknown>
  mora: LecturaDeCifra<Pick<DeudaVencida, 'senal'> | null>
  cierre: LecturaDeCifra<{ veredicto: VeredictoDelCierre }>
  impago: LecturaDeCifra<Pick<ImpagoPrimeraCuota, 'pct' | 'senal'>>
}): PastillaDeLaCharla[] {
  return [dePendiente(pendiente), deMora(mora), deCierre(cierre), deImpago(impago)].filter(
    (p): p is PastillaDeLaCharla => p !== null,
  )
}
