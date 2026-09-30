import type { ReactNode } from 'react'

import { Menu } from '@/components/ui'
import { itemsDeMenu, lineaDeDatos } from './menu'
import type { HuecoDeMenu } from './menu'

/**
 * La cabecera de una ficha: quién o qué es, su estado, la acción principal y
 * el menú «⋯».
 *
 * Las acciones destructivas —bloquear, expulsar, anular, revertir— van en el
 * «⋯» y no a la vista: un botón rojo relleno era lo que más pesaba de toda la
 * ficha, más que lo que se hace cada día. Siguen a dos clics y con su
 * confirmación de siempre.
 */
export function CabeceraDeFicha({
  identidad,
  nombre,
  insignias,
  datos,
  acciones,
  menu,
  etiquetaDelMenu = 'Más acciones',
  children,
}: {
  /** El avatar o el logo. */
  identidad?: ReactNode
  nombre: ReactNode
  /** El estado con su `Badge` e icono, el nivel, las marcas. */
  insignias?: ReactNode
  /** Una línea con los datos que identifican: documento, teléfono, alta. */
  datos?: ReadonlyArray<string | null | undefined | false>
  /** La acción principal (la única en lima) y, si hace falta, una secundaria. */
  acciones?: ReactNode
  /** El «⋯». Sin ítems no se pinta. */
  menu?: ReadonlyArray<HuecoDeMenu>
  etiquetaDelMenu?: string
  /** Debajo de los datos: un enlace, una marca con su motivo. */
  children?: ReactNode
}) {
  const linea = datos ? lineaDeDatos(datos) : ''
  const items = menu ? itemsDeMenu(menu) : []

  return (
    <header className="flex flex-wrap items-start gap-x-4 gap-y-3">
      {identidad}
      <div className="flex min-w-0 flex-1 basis-64 flex-col gap-1.5">
        <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
          <h2 className="min-w-0 type-panel-section text-on-surface">{nombre}</h2>
          {insignias}
        </div>
        {linea && <p className="type-panel-body text-on-surface-variant">{linea}</p>}
        {children}
      </div>
      {(acciones || items.length > 0) && (
        <div className="flex flex-wrap items-start gap-2">
          {acciones}
          {items.length > 0 && <Menu etiqueta={etiquetaDelMenu} items={items} />}
        </div>
      )}
    </header>
  )
}
