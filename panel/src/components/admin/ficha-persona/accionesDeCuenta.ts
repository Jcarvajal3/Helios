import { Ban, Lock, ShieldAlert, UserX } from 'lucide-react'

import type { HuecoDeMenu } from '@/components/admin/ficha/menu'
import { SOLO_SUPER_ADMIN } from '@/components/ui'
import type { ProfileStatus } from '@/features/admin/users'

// ═══════════════════════════════════════════════════════════════════════════
// Qué se le puede hacer a una cuenta, según cómo está.
//
// Puro, sin React: la ficha lo usa para repartir las acciones entre el carril
// (las de todos los días) y el «⋯» (las destructivas), y las pruebas lo leen
// en Node.
// ═══════════════════════════════════════════════════════════════════════════

/** Una acción sobre la cuenta, con lo que necesita su diálogo. */
export type AccionDeCuenta =
  | { tipo: 'estado'; destino: ProfileStatus }
  | { tipo: 'nivel'; level: number }
  | { tipo: 'marca' }
  | { tipo: 'prueba' }

/**
 * Los cambios de estado que admite una cuenta. Es la escalera de la mora:
 * congelar, suspender y expulsar, y la vuelta de los dos primeros. De la
 * expulsión no se vuelve.
 */
export type AccionesDeEstado = {
  /** El rótulo de la vuelta a activa, si está congelada o suspendida. */
  reactivar: 'Descongelar' | 'Levantar la suspensión' | null
  congelar: boolean
  suspender: boolean
  expulsar: boolean
}

export function accionesDeEstado(status: ProfileStatus): AccionesDeEstado {
  const congelado = status === 'frozen'
  const suspendido = status === 'suspended'
  const expulsado = status === 'expelled'

  return {
    reactivar: suspendido ? 'Levantar la suspensión' : congelado ? 'Descongelar' : null,
    congelar: !congelado && !suspendido && !expulsado,
    suspender: !suspendido && !expulsado,
    expulsar: !expulsado,
  }
}

/** El bloqueo manual, tal como lo sabe la ficha. */
export type EstadoDelBloqueo = 'abierto' | 'sin_bloqueo' | 'cargando' | 'error'

/**
 * El «⋯» de una persona: las acciones que frenan o sacan a alguien.
 *
 * Suspender, marcar, bloquear y expulsar van aquí y en rojo; congelar, el
 * nivel y la marca de prueba se quedan en el carril. Quitar la marca interna
 * no es destructivo, pero vive al lado de ponerla para que se encuentre donde
 * se puso. Levantar un bloqueo abierto va en el carril, a la vista.
 */
export function menuDePersona({
  status,
  marcada,
  bloqueo,
  apagado,
  abrir,
  bloquear,
}: {
  status: ProfileStatus
  /** Si ya lleva la marca interna. */
  marcada: boolean
  bloqueo: EstadoDelBloqueo
  /** Sin permiso: todo se ve, apagado y con el motivo. */
  apagado: boolean
  abrir: (accion: AccionDeCuenta) => void
  bloquear: () => void
}): Array<HuecoDeMenu> {
  const puede = accionesDeEstado(status)
  const permiso = apagado ? { disabled: true, motivoApagado: SOLO_SUPER_ADMIN } : {}

  const motivoBloqueo =
    bloqueo === 'cargando'
      ? 'Comprobando si ya tiene un bloqueo abierto…'
      : bloqueo === 'error'
        ? 'No se pudo leer si ya tiene un bloqueo abierto.'
        : undefined

  return [
    puede.suspender && {
      label: 'Suspender la cuenta',
      icon: Ban,
      peligro: true,
      onSelect: () => abrir({ tipo: 'estado', destino: 'suspended' }),
      ...permiso,
    },
    {
      label: marcada ? 'Quitar la marca interna' : 'Poner la marca interna',
      icon: ShieldAlert,
      peligro: !marcada,
      onSelect: () => abrir({ tipo: 'marca' }),
      ...permiso,
    },
    'separador',
    bloqueo !== 'abierto' && {
      label: 'Bloquear la cuenta',
      icon: Lock,
      peligro: true,
      onSelect: bloquear,
      ...(apagado
        ? permiso
        : motivoBloqueo
          ? { disabled: true, motivoApagado: motivoBloqueo }
          : {}),
    },
    puede.expulsar && {
      label: 'Expulsar',
      icon: UserX,
      peligro: true,
      onSelect: () => abrir({ tipo: 'estado', destino: 'expelled' }),
      ...permiso,
    },
  ]
}
