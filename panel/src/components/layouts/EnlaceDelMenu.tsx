import { Link } from '@tanstack/react-router'

import type { NavItem } from '@/config/navigation'
import { tonoDeAmbito } from '@/features/admin/areas'
import { cifraDelContador, rotuloDelContador } from './contadores'
import type { Contador } from './contadores'

/**
 * La raya del ítem activo: 3 px en el tono de su área, pegada al borde
 * izquierdo del menú. Lo activo se dice con esto, con el fondo levantado y
 * con el blanco; ya no con un bloque lima que pesaba más que la página.
 *
 * Va a -12 px del ítem porque el menú deja 12 de margen: así toca el borde.
 */
export function RayaDelActivo() {
  return (
    <span
      aria-hidden
      className="absolute top-1/2 -left-3 h-4 w-0.75 -translate-y-1/2 rounded-r-full bg-area"
    />
  )
}

/** El `data-area` de un ítem: el tono de su área, si es del super admin. */
export function areaDelItem(item: NavItem) {
  return item.espacio ? tonoDeAmbito(item.espacio) : undefined
}

/**
 * La pastilla con cuántos esperan. Neutra casi siempre; roja solo si alguno
 * ya se pasó de plazo. Un cero no pinta nada.
 *
 * Plegada la barra no cabe al lado del icono y se convierte en un punto sobre
 * su esquina: el ítem sigue diciendo que tiene trabajo esperando.
 */
export function ContadorDelMenu({
  contador,
  plegado = false,
}: {
  contador: Contador
  plegado?: boolean
}) {
  if (contador.n <= 0) return null

  return (
    <span
      className={`ml-auto flex h-4.5 min-w-4.5 shrink-0 items-center justify-center rounded-full px-1.25 type-label-small-emphasized ${
        contador.urgente ? 'bg-error/18 text-panel-critico' : 'bg-panel-control text-on-surface'
      } ${
        plegado
          ? `lg:absolute lg:top-1.5 lg:right-1.5 lg:ml-0 lg:size-2 lg:min-w-0 lg:px-0 ${
              contador.urgente ? 'lg:bg-error' : 'lg:bg-on-surface-variant'
            }`
          : ''
      }`}
    >
      <span aria-hidden className={plegado ? 'lg:hidden' : undefined}>
        {cifraDelContador(contador.n)}
      </span>
      <span className="sr-only">{rotuloDelContador(contador)}</span>
    </span>
  )
}

/** Un enlace del menú, con su contador si tiene trabajo esperando. */
export function EnlaceDelMenu({
  item,
  activo,
  plegado,
  contador,
}: {
  item: NavItem
  activo: boolean
  plegado: boolean
  contador?: Contador
}) {
  const Icon = item.icon

  // La acción principal: un botón lleno, con aire debajo, para que se vea
  // antes que el resto del menú. Activa, lleva además la raya como los demás.
  if (item.destacado) {
    return (
      <Link
        to={item.path}
        title={plegado ? item.label : undefined}
        className={`relative mb-2 flex h-panel-control-md items-center gap-2.5 rounded-panel-control bg-primary px-2.5 type-panel-control text-on-primary transition-colors duration-(--transition-fast) hover:bg-primary-bright ${
          plegado ? 'lg:justify-center lg:px-0' : ''
        }`}
      >
        {activo && <RayaDelActivo />}
        <Icon size={18} strokeWidth={2} aria-hidden className="shrink-0" />
        <span className={`min-w-0 truncate ${plegado ? 'lg:hidden' : ''}`}>{item.label}</span>
      </Link>
    )
  }

  return (
    <Link
      to={item.path}
      // `/admin` es prefijo de todo el panel: sin `exact`, Inicio se
      // anunciaría como la página actual desde cualquier pantalla.
      activeOptions={{ exact: item.path === '/admin' }}
      data-area={areaDelItem(item)}
      // Plegada, el nombre solo existe aquí. Sin esto la barra a 64 px es una
      // columna de iconos que hay que adivinar.
      title={plegado ? item.label : undefined}
      className={`relative flex h-panel-control-sm items-center gap-2.5 rounded-panel-control px-2.5 type-panel-control transition-colors duration-(--transition-fast) ${
        plegado ? 'lg:justify-center lg:px-0' : ''
      } ${
        activo
          ? 'bg-panel-raised text-on-surface'
          : 'text-on-surface-variant hover:bg-panel-card hover:text-on-surface'
      }`}
    >
      {activo && <RayaDelActivo />}
      <Icon size={18} strokeWidth={1.75} aria-hidden className="shrink-0" />
      <span className={`min-w-0 truncate ${plegado ? 'lg:hidden' : ''}`}>{item.label}</span>
      {contador && <ContadorDelMenu contador={contador} plegado={plegado} />}
    </Link>
  )
}
