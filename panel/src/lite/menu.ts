import {
  BarChart3,
  CalendarDays,
  LayoutGrid,
  MessageCircle,
  Settings,
  Users,
  Wallet,
} from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

/**
 * El menú de Helios Lite: cuatro áreas y tres herramientas, como en la
 * propuesta del rediseño. Cada pestaña es una pantalla de Pro, con su ruta de
 * siempre: Lite no tiene pantallas propias salvo el Resumen, así que todo lo
 * que se puede hacer en Pro se puede hacer aquí, y un enlace copiado en una
 * versión abre lo mismo en la otra.
 *
 * Lo que la propuesta tenía y no se trae: «AI SEO», que era una foto fija sin
 * fuente de datos en el panel, y «Equipo», que no existe en la base.
 */
export type PestanaLite = { rotulo: string; to: string }

export type SeccionLite = {
  id: string
  titulo: string
  descripcion: string
  icono: LucideIcon
  /** La primera es a la que lleva el menú. */
  pestanas: ReadonlyArray<PestanaLite>
}

export const PRINCIPALES: ReadonlyArray<SeccionLite> = [
  {
    id: 'resumen',
    titulo: 'Resumen',
    descripcion: 'Cómo va el negocio y qué necesita atención.',
    icono: LayoutGrid,
    pestanas: [{ rotulo: 'Resumen', to: '/admin' }],
  },
  {
    id: 'operaciones',
    titulo: 'Operaciones',
    descripcion: 'Revisa los pendientes y abre cada caso para trabajar.',
    icono: Wallet,
    pestanas: [
      { rotulo: 'Pagos reportados', to: '/admin/cobros' },
      { rotulo: 'Por cobrar', to: '/admin/cobranza' },
      { rotulo: 'Pagos a médicos', to: '/admin/pagos-clinicas' },
      { rotulo: 'Contabilidad', to: '/admin/contabilidad' },
      { rotulo: 'Alertas', to: '/admin/alertas' },
    ],
  },
  {
    id: 'personas',
    titulo: 'Personas',
    descripcion: 'Médicos, pacientes y sus expedientes, sin perder el contexto.',
    icono: Users,
    pestanas: [
      { rotulo: 'Médicos y centros', to: '/admin/clinicas' },
      { rotulo: 'Directorio', to: '/admin/directorio' },
      { rotulo: 'Pacientes', to: '/admin/pacientes' },
      { rotulo: 'Órdenes', to: '/admin/financiamientos' },
      { rotulo: 'Seguimiento', to: '/admin/seguimiento' },
    ],
  },
  {
    id: 'resultados',
    titulo: 'Resultados',
    descripcion: 'Negocio, cobranza y caja, con sus periodos.',
    icono: BarChart3,
    pestanas: [{ rotulo: 'Resultados', to: '/admin/metricas' }],
  },
]

export const HERRAMIENTAS: ReadonlyArray<SeccionLite> = [
  {
    id: 'agenda',
    titulo: 'Agenda',
    descripcion: 'Contactos y visitas de capacitación, con fecha, dirección y teléfono.',
    icono: CalendarDays,
    pestanas: [{ rotulo: 'Agenda', to: '/admin/agenda' }],
  },
  {
    id: 'mensajes',
    titulo: 'Mensajes',
    descripcion: 'WhatsApp de Helios · conversaciones con pacientes y médicos, y los avisos.',
    icono: MessageCircle,
    pestanas: [
      { rotulo: 'WhatsApp', to: '/admin/whatsapp' },
      { rotulo: 'Avisos y correos', to: '/admin/avisos' },
    ],
  },
  {
    id: 'ajustes',
    titulo: 'Ajustes',
    descripcion: 'La configuración original, organizada por tema.',
    icono: Settings,
    pestanas: [{ rotulo: 'Ajustes', to: '/admin/ajustes' }],
  },
]

const TODAS = [...PRINCIPALES, ...HERRAMIENTAS]

/** Si `pathname` es la pestaña o una ficha que cuelga de ella (`/admin/cobros/…`). */
export function esDeLaPestana(pathname: string, pestana: PestanaLite): boolean {
  if (pestana.to === '/admin') return pathname === '/admin' || pathname === '/admin/'
  return pathname === pestana.to || pathname.startsWith(`${pestana.to}/`)
}

/** La sección y la pestaña de una ruta del superadmin. */
export function ubicar(pathname: string): { seccion: SeccionLite; pestana: PestanaLite } | null {
  for (const seccion of TODAS) {
    const pestana = seccion.pestanas.find((p) => esDeLaPestana(pathname, p))
    if (pestana) return { seccion, pestana }
  }
  return null
}
