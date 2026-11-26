import { ArrowLeft, Boxes, ClipboardList, Coins, FlaskConical, LayoutGrid, Route, Settings, Tags, Truck } from 'lucide-react'

import type { NavGroup, NavItem } from '@/config/navigation'

/**
 * El menú de Helios Lab (docs/09-HELIOS-LAB.md §6.2), en este orden. Los
 * enlaces apuntan a `/lab/<x>`; cada pantalla vive en su ruta. El resumen es
 * la raíz del marco, así que solo se enciende con la ruta exacta.
 */
const RESUMEN: NavItem = { label: 'Resumen', path: '/lab', icon: LayoutGrid, exacto: true }
const MUESTRAS: NavItem = { label: 'Muestras', path: '/lab/muestras', icon: FlaskConical }
const COBROS: NavItem = { label: 'Cobros', path: '/lab/cobros', icon: ClipboardList }
const INVENTARIO: NavItem = { label: 'Inventario', path: '/lab/inventario', icon: Boxes }
const LOGISTICA: NavItem = { label: 'Logística', path: '/lab/logistica', icon: Truck }
const RUTA: NavItem = { label: 'Ruta', path: '/lab/ruta', icon: Route }
const GANANCIA: NavItem = { label: 'Ganancia', path: '/lab/ganancia', icon: Coins }
const CATALOGO: NavItem = { label: 'Catálogo', path: '/lab/catalogo', icon: Tags }
const AJUSTES: NavItem = { label: 'Ajustes', path: '/lab/ajustes', icon: Settings }

/** Super admin y operador: todo. */
export const menuDelEquipoLab: NavGroup[] = [
  { items: [RESUMEN, MUESTRAS, COBROS, INVENTARIO, LOGISTICA, RUTA, GANANCIA, CATALOGO, AJUSTES] },
]

/** El driver: la ruta del día y nada más. */
export const menuDelDriver: NavGroup[] = [{ items: [RUTA] }]

/** Al pie, para quien viene del panel: de vuelta a él. El driver no tiene panel. */
export const pieDelEquipoLab: NavItem[] = [{ label: 'Volver al panel', path: '/admin', icon: ArrowLeft }]
