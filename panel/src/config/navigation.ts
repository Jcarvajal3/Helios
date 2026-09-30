import type { LucideIcon } from 'lucide-react'
import { BarChart3, FilePlus2, FileText, HandCoins, Landmark, UserCog } from 'lucide-react'

import { canSee } from '@/features/auth/permissions'
import type { MerchantSection } from '@/features/auth/permissions'
import type { MerchantRole } from '@/features/auth/session'
import { pantalla } from '@/features/admin/catalogo'
import type { Ambito, IdPantalla } from '@/features/admin/catalogo'

export type NavItem = {
  label: string
  path: string
  icon: LucideIcon
  /** Igual que en el grupo, pero para un ítem suelto dentro de uno mixto. */
  superAdminOnly?: boolean
  /**
   * Solo en el super admin: de qué área es la pantalla. Da el tono de la raya
   * del ítem activo (`data-area`), que así es el de su área y no el de la
   * pantalla en la que se está.
   */
  espacio?: Ambito
  /**
   * La acción principal del panel, pintada como botón y no como enlace. Solo
   * la lleva «Nuevo financiamiento» de la clínica: es lo que se hace veinte
   * veces al día, y tiene que encontrarse sin leer el menú.
   */
  destacado?: boolean
}

/**
 * Un bloque del sidebar. Sin `title` se pinta como una lista suelta — es lo
 * que quiere el panel de la clínica, que tiene seis ítems y ninguno necesita
 * explicación. Con `title`, el rótulo es un botón que pliega el bloque.
 *
 * `superAdminOnly` esconde el grupo al operador: firmar clínicas es del
 * super admin (README §Separación de poderes). Es solo la UI; la barrera de
 * verdad la ponen las RPC contra `is_platform_admin()`.
 */
export type NavGroup = {
  title?: string
  items: NavItem[]
  superAdminOnly?: boolean
  /**
   * Solo en el super admin: el espacio de trabajo, o el bloque fijo, del
   * grupo. Da el punto de color de su cabecera.
   */
  espacio?: Ambito
}

/** Navegación del panel de la clínica: un solo grupo, sin título. */
export const merchantNavGroups: MerchantNavGroup[] = [
  {
    items: [
      // Los nombres son los de la recepción, no los del sistema: se
      // «registra» un financiamiento; lo que Helios le transfiere a la
      // clínica son sus «Pagos». En el orden del trabajo: registrar, mirar
      // lo registrado y lo ganado, y después el dinero de la clínica.
      {
        label: 'Nuevo financiamiento',
        path: '/registrar',
        icon: FilePlus2,
        section: 'registrar',
        destacado: true,
      },
      {
        label: 'Financiamientos',
        path: '/financiamientos',
        icon: FileText,
        section: 'financiamientos',
      },
      {
        label: 'Comisiones',
        path: '/comisiones',
        icon: HandCoins,
        section: 'comisiones',
      },
      {
        label: 'Pagos',
        path: '/pagos',
        icon: Landmark,
        section: 'pagos',
      },
      {
        label: 'Métricas',
        path: '/metricas',
        icon: BarChart3,
        section: 'metricas',
      },
      {
        label: 'Personal',
        path: '/personal',
        icon: UserCog,
        section: 'personal',
      },
      // Cuenta no está en la barra: quién eres y cómo salir viven en el
      // bloque del pie del sidebar. La ruta sigue existiendo.
    ],
  },
]

/** Cada pantalla de la clínica lleva la sección que decide quién la ve. */
type MerchantNavItem = NavItem & { section: MerchantSection }
type MerchantNavGroup = { title?: string; items: MerchantNavItem[] }

/**
 * El sidebar de la clínica solo enseña lo que ese rol puede usar.
 *
 * No es cosmético. Una secretaria que entrara a Pagos no vería un error:
 * vería **cero**, porque la RLS le devuelve una lista vacía. Es el fallo más
 * peligroso que hay — el que parece una respuesta legítima (el mismo que
 * documenta la migración 20260822123000).
 */
export function merchantNavGroupsFor(role: MerchantRole): NavGroup[] {
  return merchantNavGroups
    .map((group) => ({
      ...group,
      items: group.items.filter((i) => canSee(role, i.section)),
    }))
    .filter((group) => group.items.length > 0)
}

/**
 * Qué pantallas lleva cada bloque del menú del super admin, en orden.
 *
 * Solo ids: el rótulo, la ruta y el icono salen del catálogo
 * (`features/admin/catalogo`), así que cada nombre se escribe en un solo
 * sitio. Un id que no existe no compila.
 *
 * Arriba y sueltas, las dos puertas de todos: Inicio (lo que hay que hacer
 * hoy) y Métricas (cómo va el negocio; todas las cifras en una pantalla).
 * Debajo, el trabajo de cada día en dos bloques: «Cobranza y riesgo» (a quién
 * cobrar, qué pagó, qué avisos mandar y qué alerta mirar) y «Caja y
 * contabilidad». Al final, Directorio y Ajustes. Gerencia y Riesgo ya no son
 * bloques: su análisis vive en Métricas y su trabajo diario en «Cobranza y
 * riesgo». Los tonos siguen siendo los de cada pantalla (Alertas, en el de
 * Riesgo); el punto del bloque es el de su `espacio`.
 *
 * No son permisos: **los dos roles ven todas las pantallas**. Lo que separa a
 * los roles es qué botones puede pulsar dentro; el corte de verdad lo ponen
 * las RPC contra `is_platform_admin()`, y cada pantalla apaga con una
 * explicación lo que ese rol no puede hacer.
 *
 * El orden es el mismo para todo el mundo. Cada bloque con título se pliega a
 * mano desde su rótulo, y eso es lo único que cada persona cambia.
 */
const MENU_ADMIN: ReadonlyArray<{
  /** El punto de color del rótulo y la clave con la que se recuerda plegado. */
  espacio: Ambito
  /** Sin título, el bloque es una lista suelta que no se pliega. */
  titulo?: string
  pantallas: ReadonlyArray<IdPantalla>
}> = [
  // Inicio es por donde se entra, y desde ella se salta a lo que toca.
  // Métricas, justo debajo: es la otra pregunta de cada mañana.
  { espacio: 'inicio', pantallas: ['inicio', 'metricas'] },
  // El dinero que entra, de punta a punta, y a quién se le da crédito.
  // Promesas es una pestaña de Por cobrar, y Abonos sin dueño una de Pagos
  // reportados.
  {
    espacio: 'cobranza',
    titulo: 'Cobranza y riesgo',
    pantallas: ['cartera-vencida', 'pagos-reportados', 'avisos', 'alertas'],
  },
  {
    espacio: 'caja',
    titulo: 'Caja y contabilidad',
    pantallas: ['pagos-a-locales', 'libro-y-cierre'],
  },
  // Lo que se busca: un directorio. Se entra con un nombre o un teléfono en
  // la cabeza, no con una tarea.
  { espacio: 'directorio', titulo: 'Directorio', pantallas: ['personas', 'locales', 'consumos'] },
  { espacio: 'ajustes', titulo: 'Ajustes', pantallas: ['ajustes'] },
]

/**
 * Lo que va al pie del menú, junto a la cuenta y fuera de los bloques. Hoy
 * nada.
 */
const PIE_ADMIN: ReadonlyArray<IdPantalla> = []

/** Un ítem del menú a partir de su pantalla del catálogo. */
function itemDePantalla(id: IdPantalla): NavItem {
  const p = pantalla(id)
  return { label: p.titulo, path: p.destino.to, icon: p.icono, espacio: p.espacio }
}

/** Navegación del super admin (el equipo de Helios), un bloque por fila de `MENU_ADMIN`. */
export const superAdminNavGroups: NavGroup[] = MENU_ADMIN.map((bloque) => ({
  espacio: bloque.espacio,
  title: bloque.titulo,
  items: bloque.pantallas.map(itemDePantalla),
}))

/** El pie del menú del super admin. */
export const superAdminNavPie: NavItem[] = PIE_ADMIN.map(itemDePantalla)

/**
 * Quita del sidebar lo que este rol no puede usar.
 *
 * Hoy no esconde nada del super admin —los dos roles entran a todas las
 * pestañas— y se queda por el panel de la clínica y por si vuelve a hacer
 * falta: esconder una pantalla es más barato que descubrirla vacía.
 */
export function visibleGroups(
  groups: NavGroup[],
  isSuperAdmin: boolean,
): NavGroup[] {
  if (isSuperAdmin) return groups

  return groups
    .filter((group) => !group.superAdminOnly)
    .map((group) => ({
      ...group,
      items: group.items.filter((i) => !i.superAdminOnly),
    }))
    .filter((group) => group.items.length > 0)
}
