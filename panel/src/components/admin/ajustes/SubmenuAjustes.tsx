import { useId } from 'react'
import { Link, useNavigate } from '@tanstack/react-router'

import { CLASE_CAMPO, bordeDeCampo } from '@/components/kit/clases'

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
    <>
      <SelectorDeAjustes activa={activa} />
      <nav aria-label="Secciones de ajustes" className="hidden flex-col gap-5 lg:flex">
        {GRUPOS_AJUSTES.map((grupo) => (
          <GrupoDelSubmenu key={grupo.titulo} grupo={grupo} activa={activa} />
        ))}
      </nav>
    </>
  )
}

/**
 * El submenú por debajo de 1024 px, donde no hay columna a la izquierda: un
 * desplegable con los mismos grupos. La lista entera ocupaba 700 px encima de
 * cada sección, y en el teléfono había que bajar una pantalla y media para
 * llegar a lo que se había abierto.
 */
function SelectorDeAjustes({ activa }: { activa: PestanaAjustes }) {
  const navigate = useNavigate()
  const id = useId()

  return (
    <div className="lg:hidden">
      <label htmlFor={id} className="sr-only">
        Sección de ajustes
      </label>
      <select
        id={id}
        value={activa}
        onChange={(e) => void navigate({ to: '/admin/ajustes', search: { tab: e.target.value as PestanaAjustes } })}
        className={`h-panel-control-md appearance-none bg-[length:15px] bg-[position:right_12px_center] bg-no-repeat ${CLASE_CAMPO} ${bordeDeCampo(false)}`}
        style={{
          // El mismo chevron que el `Select` del kit.
          backgroundImage:
            "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='%23B9B9B9'%3E%3Cpath d='M12 15.4 6.6 10l1.4-1.4 4 4 4-4L17.4 10z'/%3E%3C/svg%3E\")",
          paddingRight: 34,
        }}
      >
        {GRUPOS_AJUSTES.map((grupo) => (
          <optgroup key={grupo.titulo} label={grupo.titulo}>
            {grupo.secciones.map((item) => (
              <option key={item.value} value={item.value}>
                {item.label}
              </option>
            ))}
          </optgroup>
        ))}
      </select>
    </div>
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
