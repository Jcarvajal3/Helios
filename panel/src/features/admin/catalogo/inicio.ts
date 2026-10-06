import { House } from 'lucide-react'

import type { Entrada } from './tipos'

/**
 * Inicio: la pantalla por la que se entra. No es de ningún equipo, porque es
 * el índice de todos.
 */
export const inicio = [
  {
    tipo: 'pantalla',
    id: 'inicio',
    titulo: 'Inicio',
    descripcion:
      'Qué hay que hacer hoy: lo que bloquea la operación, las colas de trabajo de todos los equipos y sus números.',
    espacio: 'inicio',
    sinonimos: ['hoy', 'cola de trabajo', 'portada', 'pendientes de hoy', 'tu cola', 'tus números'],
    destino: { to: '/admin' },
    icono: House,
  },

  // ── Acciones ─────────────────────────────────────────────────────────────
  {
    tipo: 'accion',
    id: 'empezar-la-cola-de-hoy',
    titulo: 'Empezar la cola de hoy',
    descripcion:
      'Abrir la primera ficha de la lista más urgente y pasar a la siguiente sin volver a la lista.',
    espacio: 'inicio',
    sinonimos: [
      'modo cola',
      'empezar',
      'qué hago ahora',
      'lo más urgente',
      'empezar la cola de pagos',
      'empezar la cola de promesas',
    ],
    destino: { to: '/admin' },
  },

  // ── Cifras ───────────────────────────────────────────────────────────────
  {
    tipo: 'cifra',
    id: 'semaforo-del-cierre',
    titulo: 'Semáforo del pago a clínicas',
    descripcion: 'Si la caja cubre lo que hay que transferirles hoy a las clínicas.',
    espacio: 'inicio',
    sinonimos: ['cubre el pago de hoy', 'semáforo del cierre', 'alcanza la caja', 'faltan fondos'],
    destino: { to: '/admin' },
    que: 'Lo que sale hoy hacia las clínicas (atrasados incluidos) frente al dinero en caja: «Cubre» o «No cubre». Se les paga a diario: cada liquidación, el día siguiente a su vencimiento.',
    rpc: 'admin_merchant_payables',
  },
] as const satisfies ReadonlyArray<Entrada>
