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
 * propuesta del rediseño. Cada pestaña es una ruta de Pro: un enlace copiado
 * en una versión abre lo mismo en la otra.
 *
 * Casi todas son pantallas de Lite, con la estructura de la maqueta; la
 * bandeja de WhatsApp es la de Pro, con el vestido de Lite. Cada ruta elige
 * su versión con `conLite` (`espacio.tsx`).
 *
 * Lo que la propuesta tenía y no se trae: «AI SEO», que era una foto fija sin
 * fuente de datos en el panel, y «Equipo», que no existe en la base.
 */
/**
 * Una pestaña: una ruta de Pro y, si la ruta tiene varias vistas, la suya
 * (`?vista=`): Avisos de hoy, Correos y Plantillas son la misma ruta.
 */
export type PestanaLite = { rotulo: string; to: string; vista?: string }

export type SeccionLite = {
  id: string
  titulo: string
  descripcion: string
  icono: LucideIcon
  /**
   * La pantalla pinta su propia cabecera (Resumen, Resultados, Agenda: son
   * pantallas de Lite, con la estructura de la maqueta). Las demás llevan la
   * del marco, encima de la pantalla de Pro.
   */
  cabeceraPropia?: boolean
  /** La primera es a la que lleva el menú. */
  pestanas: ReadonlyArray<PestanaLite>
}

export const PRINCIPALES: ReadonlyArray<SeccionLite> = [
  {
    id: 'resumen',
    cabeceraPropia: true,
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
      { rotulo: 'Clics por médico (Ads)', to: '/admin/directorio' },
      { rotulo: 'Pacientes', to: '/admin/pacientes' },
      { rotulo: 'Órdenes', to: '/admin/financiamientos' },
      { rotulo: 'Seguimiento', to: '/admin/seguimiento' },
    ],
  },
  {
    id: 'resultados',
    cabeceraPropia: true,
    titulo: 'Resultados',
    descripcion: 'Negocio, cobranza y caja, con sus periodos.',
    icono: BarChart3,
    pestanas: [{ rotulo: 'Resultados', to: '/admin/metricas' }],
  },
]

export const HERRAMIENTAS: ReadonlyArray<SeccionLite> = [
  {
    id: 'agenda',
    cabeceraPropia: true,
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
      { rotulo: 'Avisos de hoy', to: '/admin/avisos' },
      { rotulo: 'Correos', to: '/admin/avisos', vista: 'correos' },
      { rotulo: 'Plantillas', to: '/admin/avisos', vista: 'plantillas' },
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

/** Si `pathname` es la ruta de la pestaña o una ficha que cuelga de ella (`/admin/cobros/…`). */
function esDeLaRuta(pathname: string, pestana: PestanaLite): boolean {
  if (pestana.to === '/admin') return pathname === '/admin' || pathname === '/admin/'
  return pathname === pestana.to || pathname.startsWith(`${pestana.to}/`)
}

/**
 * Si se está en esa pestaña. Entre las que comparten ruta, gana la de la
 * `vista` de la dirección; sin vista (o con una que no tiene pestaña), la que
 * no tiene vista.
 */
export function esDeLaPestana(pathname: string, vista: string | undefined, pestana: PestanaLite, hermanas: ReadonlyArray<PestanaLite>): boolean {
  if (!esDeLaRuta(pathname, pestana)) return false
  const conSuVista = hermanas.some((p) => p.vista !== undefined && p.vista === vista && esDeLaRuta(pathname, p))
  return conSuVista ? pestana.vista === vista : pestana.vista === undefined
}

/** La sección y la pestaña de una ruta del superadmin. */
export function ubicar(
  pathname: string,
  vista?: string,
): { seccion: SeccionLite; pestana: PestanaLite } | null {
  for (const seccion of TODAS) {
    const pestana = seccion.pestanas.find((p) => esDeLaPestana(pathname, vista, p, seccion.pestanas))
    if (pestana) return { seccion, pestana }
  }
  return null
}
