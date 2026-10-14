import { useId } from 'react'
import { Link } from '@tanstack/react-router'

import { GRUPOS_AJUSTES } from '@/features/admin/ajustesNavegacion'
import type { GrupoAjustes, PestanaAjustes } from '@/features/admin/ajustesNavegacion'

/**
 * El submenú de Ajustes: siete grupos y doce secciones.
 *
 * El activo se dice como en el menú lateral —fondo levantado, texto en blanco
 * y una raya de 3 px— pero en neutro: Ajustes no es de ningún área, y el
 * bloque lima de antes pesaba más que la sección que se estaba leyendo.
 */
export function SubmenuAjustes({ activa }: { activa: PestanaAjustes }) {
  return (
    <nav aria-label="Secciones de ajustes" className="flex flex-col gap-5">
      {GRUPOS_AJUSTES.map((grupo) => (
        <GrupoDelSubmenu key={grupo.titulo} grupo={grupo} activa={activa} />
      ))}
    </nav>
  )
}

/**
 * Un grupo con su rótulo. Emergencia lleva el rótulo en rojo y nada más: su
 * ítem se comporta como los demás, y así el rojo marca dónde está el freno
 * sin gritar cada vez que se abre Ajustes.
 */
function GrupoDelSubmenu({ grupo, activa }: { grupo: GrupoAjustes; activa: PestanaAjustes }) {
  const idRotulo = useId()

  return (
    <div role="group" aria-labelledby={idRotulo} className="flex flex-col gap-0.5">
      <p
        id={idRotulo}
        className={`mb-1 px-3 type-panel-label ${
          grupo.tono === 'error' ? 'text-error' : 'text-panel-muted'
        }`}
      >
        {grupo.titulo}
      </p>
      {grupo.secciones.map((item) => (
        <ItemDelSubmenu
          key={item.value}
          valor={item.value}
          rotulo={item.label}
          activo={item.value === activa}
        />
      ))}
    </div>
  )
}

function ItemDelSubmenu({
  valor,
  rotulo,
  activo,
}: {
  valor: PestanaAjustes
  rotulo: string
  activo: boolean
}) {
  return (
    <Link
      to="/admin/ajustes"
      search={{ tab: valor }}
      aria-current={activo ? 'page' : undefined}
      className={`relative flex min-h-panel-control-sm items-center rounded-panel-control px-3 py-1.5 text-left type-panel-control transition-colors duration-(--transition-fast) ${
        activo
          ? 'bg-panel-raised text-on-surface'
          : 'text-on-surface-variant hover:bg-panel-card hover:text-on-surface'
      }`}
    >
      {/* La raya va dentro del ítem y no en el borde de la columna, como en
          el menú lateral: aquí no hay un borde al que pegarla. */}
      {activo && (
        <span
          aria-hidden
          className="absolute top-1/2 left-0 h-4 w-0.75 -translate-y-1/2 rounded-r-full bg-on-surface"
        />
      )}
      {rotulo}
    </Link>
  )
}
