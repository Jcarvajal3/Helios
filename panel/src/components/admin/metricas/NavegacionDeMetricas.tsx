import { Fragment } from 'react'
import { Link } from '@tanstack/react-router'
import type { LucideIcon } from 'lucide-react'

import type { Destino } from '@/features/admin/catalogo'
import type { TonoDePestana } from '@/features/admin/metricas/pestanas'

// ═══════════════════════════════════════════════════════════════════════════
// La jerarquía de Métricas, en tres formas que se nombran sin pensar
// (Javier, 27-09: «que toda la jerarquía de sub tabs/pestañas se entienda
// perfecto»). La regla de siempre: navegar ≠ filtrar ≠ actuar.
//
//   nivel 1  PestanasConTono     texto subrayado sobre una regla, como las
//                                `Tabs` del panel; la activa, subrayada en
//                                el tono de su área y con un brillo que baja
//                                hasta la banda
//   nivel 2  BandaDeSubpestanas  una banda muy suave del mismo tono, colgada
//                                de la regla: nace de la pestaña activa y
//                                las sub-pestañas van DENTRO, como píldoras
//                                de texto (la activa, en neutro elevado y
//                                blanco). Nunca una caja hundida: esa forma
//                                es la de un filtro (`Segmented`)
//   nivel 3  Filtro + Segmented  los filtros de cada pestaña; no son de aquí
//
// Y encima del contenido, `LineaDelLugar`: «Cobros › Calendario — lo que
// contesta».
//
// Son enlaces de verdad (`<Link>` con `aria-current`): se abren en otra
// pestaña del navegador, se copian y «atrás» vuelve. Sirven para cualquier
// pantalla del panel: reciben el destino ya armado (`Destino` del catálogo).
// ═══════════════════════════════════════════════════════════════════════════

/** Un enlace de la navegación, ya armado. */
export type EnlaceDeNivel = {
  clave: string
  rotulo: string
  /** El tono de su área: lo pone el subrayado (nivel 1) o la banda (nivel 2). */
  tono: TonoDePestana
  destino: Destino
  /**
   * El dibujo que va delante del rótulo: el mismo que su entrada de Ctrl K.
   * En la activa se pinta en el tono de su área.
   */
  icono?: LucideIcon
  /**
   * `pagina`: lleva a lo que se ve (`aria-current="page"`). `seccion`: es la
   * pestaña activa, pero lo que se ve es otra de sus sub-pestañas
   * (`aria-current="true"`). `null`: no es donde se está.
   */
  actual: 'pagina' | 'seccion' | null
}

function ariaCurrent(actual: EnlaceDeNivel['actual']): 'page' | 'true' | undefined {
  if (actual === 'pagina') return 'page'
  if (actual === 'seccion') return 'true'
  return undefined
}

// El brillo de la pestaña activa: de nada arriba al tinte de la banda abajo,
// así la banda de debajo se lee como suya. Y el tinte de la banda: muy suave,
// para que no compita con las tarjetas ni parezca un aviso.
const BRILLO_ACTIVA =
  'bg-[linear-gradient(to_bottom,transparent,color-mix(in_oklab,var(--area)_14%,transparent))]'
const FONDO_BANDA = 'bg-[color-mix(in_oklab,var(--area)_7%,transparent)]'
const BORDE_BANDA = 'border-[color-mix(in_oklab,var(--area)_18%,transparent)]'
const SUBRAYADO_AL_PASAR = 'hover:border-[color-mix(in_oklab,var(--area)_45%,transparent)]'
// La píldora activa: fondo neutro elevado, como pide la jerarquía, con un
// aro fino del tono de su pestaña. Es lo que la separa a simple vista de la
// opción activa de un `Segmented`, que es gris del todo.
const ARO_ACTIVA = 'shadow-[inset_0_0_0_1px_color-mix(in_oklab,var(--area)_45%,transparent)]'

/**
 * Nivel 1: las pestañas. Cada una lleva su tono (`data-area`): la activa va
 * subrayada en él, y al pasar por otra se asoma el suyo.
 *
 * `flex-wrap` y no desplazamiento, como las `Tabs`: si no caben, se parten en
 * dos renglones en vez de esconder pestañas sin avisar. Miden 48 px de alto,
 * por encima del táctil, así que en la tablet se aciertan con el dedo; y
 * llevan su icono delante, que se reconoce antes que el rótulo.
 */
export function PestanasConTono({
  etiqueta,
  enlaces,
  className = '',
}: {
  /** El nombre de la navegación para el lector de pantalla: «Pestañas de Métricas». */
  etiqueta: string
  enlaces: ReadonlyArray<EnlaceDeNivel>
  className?: string
}) {
  return (
    <nav aria-label={etiqueta} className={className}>
      <ul className="flex flex-wrap gap-x-1 border-b border-panel-hairline sm:gap-x-1.5">
        {enlaces.map((e) => {
          const activa = e.actual !== null
          const Icono = e.icono
          return (
            // `-mb-px`: el subrayado tapa la regla de abajo, como en `Tabs`.
            <li key={e.clave} data-area={e.tono} className="-mb-px flex">
              <Link
                {...e.destino}
                // Lo activo lo decide `actual`; sin `exact`, TanStack daría
                // por activa la pestaña Semana en todas (su búsqueda está vacía).
                activeOptions={{ exact: true }}
                aria-current={ariaCurrent(e.actual)}
                className={`group inline-flex h-12 items-center gap-2 whitespace-nowrap rounded-t-panel-control border-b-2 px-3 type-panel-body sm:px-4 text-[0.9375rem] font-semibold transition-colors duration-(--transition-fast) motion-reduce:transition-none ${
                  activa
                    ? `border-area text-on-surface ${BRILLO_ACTIVA}`
                    : `border-transparent text-panel-muted hover:text-on-surface ${SUBRAYADO_AL_PASAR}`
                }`}
              >
                {Icono && (
                  <Icono
                    size={18}
                    strokeWidth={2}
                    aria-hidden
                    className={`shrink-0 transition-colors duration-(--transition-fast) ${
                      activa ? 'text-area' : 'text-panel-muted group-hover:text-on-surface-variant'
                    }`}
                  />
                )}
                {e.rotulo}
              </Link>
            </li>
          )
        })}
      </ul>
    </nav>
  )
}

/**
 * Nivel 2: las sub-pestañas de la pestaña activa, en una banda del tono de
 * esa pestaña colgada de la regla de las pestañas. Sin sub-pestañas no pinta
 * nada.
 *
 * Píldoras sueltas, con su icono y sin caja alrededor: la activa con fondo
 * neutro elevado, texto blanco e icono en el tono del área; las otras en gris
 * que se aclara al pasar. En la tablet crecen al alto táctil.
 */
export function BandaDeSubpestanas({
  etiqueta,
  tono,
  enlaces,
}: {
  /** «Sub-pestañas de Cobros». */
  etiqueta: string
  tono: TonoDePestana
  enlaces: ReadonlyArray<EnlaceDeNivel>
}) {
  if (enlaces.length === 0) return null
  return (
    <nav
      aria-label={etiqueta}
      data-area={tono}
      className={`rounded-b-panel-card border-x border-b px-3 py-2.5 ${BORDE_BANDA} ${FONDO_BANDA}`}
    >
      <ul className="flex flex-wrap gap-1.5">
        {enlaces.map((e) => {
          const activa = e.actual !== null
          const Icono = e.icono
          return (
            <li key={e.clave} className="flex">
              <Link
                {...e.destino}
                activeOptions={{ exact: true }}
                aria-current={ariaCurrent(e.actual)}
                className={`group inline-flex h-9 items-center gap-1.5 whitespace-nowrap rounded-panel-pill px-4 type-panel-control transition-colors duration-(--transition-fast) motion-reduce:transition-none pointer-coarse:h-11 pointer-coarse:px-5 ${
                  activa
                    ? `bg-panel-control text-on-surface ${ARO_ACTIVA}`
                    : 'text-panel-muted hover:bg-panel-raised hover:text-on-surface'
                }`}
              >
                {Icono && (
                  <Icono
                    size={15}
                    strokeWidth={2}
                    aria-hidden
                    className={`shrink-0 transition-colors duration-(--transition-fast) ${
                      activa ? 'text-area' : 'text-panel-muted group-hover:text-on-surface-variant'
                    }`}
                  />
                )}
                {e.rotulo}
              </Link>
            </li>
          )
        })}
      </ul>
    </nav>
  )
}

/**
 * Dónde se está y qué contesta, en una línea encima del contenido:
 * «● Cobros › Calendario — Todas las semanas de consumo comparadas…». El
 * punto va en el tono del área, junto a su nombre.
 *
 * Es el título (`h2`) de lo que hay debajo; la descripción, una línea que
 * baja a la siguiente si no cabe.
 */
export function LineaDelLugar({
  ruta,
  descripcion,
  tono,
  className = '',
}: {
  /** De fuera adentro: `['Cobros', 'Calendario']`. */
  ruta: ReadonlyArray<string>
  descripcion: string
  tono: TonoDePestana
  className?: string
}) {
  return (
    <div data-area={tono} className={`flex flex-wrap items-baseline gap-x-2 gap-y-1 ${className}`}>
      <h2 className="type-panel-section text-on-surface">
        <span aria-hidden className="mr-2 inline-block size-2 rounded-full bg-area align-middle" />
        {ruta.map((parte, i) => (
          <Fragment key={parte}>
            {i > 0 && (
              <>
                <span aria-hidden className="mx-1.5 text-panel-muted">
                  ›
                </span>
                <span className="sr-only">, </span>
              </>
            )}
            {parte}
          </Fragment>
        ))}
      </h2>
      <p className="type-panel-body text-on-surface-variant">
        <span aria-hidden>— </span>
        {descripcion}
      </p>
    </div>
  )
}
