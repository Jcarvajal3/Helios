import type { BadgeTone } from '@/components/ui'
import type { Bloqueo } from './bloqueos'
import { ordenarColas, tieneTrabajo } from './colas'
import type { Lectura } from './colas'

// ═══════════════════════════════════════════════════════════════════════════
// «Pendiente»: qué tarjetas pinta Inicio y en qué orden. Módulo puro.
//
// Primero lo que impide operar (los bloqueos), después las comprobaciones que
// no se pudieron hacer —pueden esconder un bloqueo— y al final las colas con
// trabajo o sin leer, en el orden de «Tu cola». Las vacías no se pintan: siete
// filas de «Nada esperando» eran casi toda la pantalla.
// ═══════════════════════════════════════════════════════════════════════════

/** Cuántas tarjetas caben en la fila de Inicio. El resto está en «Ver toda la cola». */
export const TARJETAS_EN_LA_FILA = 4

/** Una comprobación de «Bloquea la operación» cuya lectura falló. */
export type SinComprobar = { que: string; reintentar: () => void }

export type TarjetaDePendiente<TCola> =
  | { tipo: 'bloqueo'; clave: string; bloqueo: Bloqueo }
  | { tipo: 'sin-comprobar'; clave: string; que: string; reintentar: () => void }
  | { tipo: 'cola'; clave: string; cola: TCola }

export type Pendiente<TCola> =
  /** Todavía no hay nada que enseñar y algo sigue leyéndose. */
  | { estado: 'cargando' }
  /** Todo se leyó y no hay nada: la tarjeta tranquila. */
  | { estado: 'al-dia' }
  | {
      estado: 'con-trabajo'
      /** Las que caben en la fila, en orden. */
      tarjetas: ReadonlyArray<TarjetaDePendiente<TCola>>
      /** Todas las que habría, también las que no caben. */
      total: number
      /** Bloqueos más colas con trabajo: lo que de verdad espera a alguien. */
      pendientes: number
      /** La primera tarjeta con botón: la única en lima. */
      principal: string | null
      /** Lo más urgente que hay: rojo si algo bloquea o ya se pasó de plazo. */
      urgencia: BadgeTone
    }

type ColaConLectura = { id: string; lectura: Lectura }

function urgenciaDe(bloqueos: number, lecturas: ReadonlyArray<Lectura>): BadgeTone {
  const plazos = lecturas.flatMap((l) => (tieneTrabajo(l) && l.estado === 'listo' ? [l.resumen.plazo] : []))
  if (bloqueos > 0 || plazos.includes('pasado')) return 'error'
  if (plazos.includes('hoy')) return 'warning'
  return 'neutral'
}

/**
 * Lo que pinta «Pendiente». Una cola que falló se pinta —con su «No se pudo
 * leer»—, porque puede esconder trabajo; una que todavía carga, no, para no
 * llenar la fila de huecos que luego desaparecen.
 */
export function pendienteDeHoy<TCola extends ColaConLectura>(
  {
    bloqueos,
    sinComprobar,
    comprobando,
    colas,
  }: {
    bloqueos: ReadonlyArray<Bloqueo>
    sinComprobar: ReadonlyArray<SinComprobar>
    /** Alguna comprobación de bloqueo sigue leyéndose. */
    comprobando: boolean
    colas: ReadonlyArray<TCola>
  },
  cuantas: number = TARJETAS_EN_LA_FILA,
): Pendiente<TCola> {
  const conAlgo = ordenarColas(colas).filter((c) => tieneTrabajo(c.lectura) || c.lectura.estado === 'error')

  const todas: TarjetaDePendiente<TCola>[] = [
    ...bloqueos.map((b): TarjetaDePendiente<TCola> => ({ tipo: 'bloqueo', clave: `bloqueo-${b.id}`, bloqueo: b })),
    ...sinComprobar.map(
      (s): TarjetaDePendiente<TCola> => ({
        tipo: 'sin-comprobar',
        clave: `sin-comprobar-${s.que}`,
        que: s.que,
        reintentar: s.reintentar,
      }),
    ),
    ...conAlgo.map((c): TarjetaDePendiente<TCola> => ({ tipo: 'cola', clave: `cola-${c.id}`, cola: c })),
  ]

  if (todas.length === 0) {
    const leyendo = comprobando || colas.some((c) => c.lectura.estado === 'cargando')
    return leyendo ? { estado: 'cargando' } : { estado: 'al-dia' }
  }

  const principal =
    todas.find((t) => t.tipo === 'bloqueo' || (t.tipo === 'cola' && tieneTrabajo(t.cola.lectura)))?.clave ??
    null

  return {
    estado: 'con-trabajo',
    tarjetas: todas.slice(0, cuantas),
    total: todas.length,
    pendientes: bloqueos.length + conAlgo.filter((c) => tieneTrabajo(c.lectura)).length,
    principal,
    urgencia: urgenciaDe(
      bloqueos.length,
      conAlgo.map((c) => c.lectura),
    ),
  }
}
