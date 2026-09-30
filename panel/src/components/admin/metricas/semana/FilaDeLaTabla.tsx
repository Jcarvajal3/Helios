import { Link, useNavigate } from '@tanstack/react-router'

import { NoSeParte } from '@/components/admin/metricas/kit'
import { Tooltip } from '@/components/ui'
import type { BusquedaComun } from '@/features/admin/metricas/busqueda'
import type { Delta } from '@/features/admin/metricas/formato'
import {
  ayudaDeFila,
  busquedaDeDestino,
  cambioDeFila,
  escribir,
  motivoDeRaya,
  nombreDelDestino,
} from '@/features/admin/metricas/semana/filas'
import type { DefinicionDeFila } from '@/features/admin/metricas/semana/filas'
import type { CifrasDePeriodo, SemanaConCifras } from '@/features/admin/metricas/semana/tipos'

/** El color del cambio: verde si es buena noticia, rojo si es mala, gris si no es ninguna. */
const COLOR_DEL_CAMBIO: Record<Delta['tono'], string> = {
  bueno: 'text-success',
  malo: 'text-panel-critico',
  neutro: 'text-on-surface-variant',
}

/** La columna de la semana elegida: un paso por encima de la tarjeta, como en la cabecera. */
export const CLASE_ELEGIDA = 'bg-panel-raised'

/**
 * Una fila de «Semana a semana»: el nombre (que lleva a la pestaña que la
 * explica), una celda por semana y el cambio frente a la anterior.
 *
 * Toda la fila se pulsa; el nombre es además un enlace de verdad, para el
 * teclado y para abrirlo en otra pestaña. Un sumando (el consumo o el
 * service fee de lo que se paga en cuotas) va más pequeño, sangrado y sin
 * cambio propio. Con un local elegido, lo que no se parte por local ocupa la
 * fila entera con `NoSeParte`.
 *
 * La ayuda de la fila sale en el globo del kit (`Tooltip`) al señalar el
 * nombre, con el ratón o con el teclado, y no en el `title` del navegador,
 * que tarda en salir y no se puede leer ordenado. Las celdas no llevan
 * `title`: el cambio largo y el motivo de una raya van en texto para el
 * lector de pantalla.
 */
export function FilaDeLaTabla({
  fila,
  semanas,
  anterior,
  comun,
  local,
}: {
  fila: DefinicionDeFila
  semanas: ReadonlyArray<SemanaConCifras>
  /** Las cifras con las que se compara la elegida (la última de `semanas`). */
  anterior: CifrasDePeriodo
  comun: BusquedaComun
  local: string | null
}) {
  const navigate = useNavigate()
  const busqueda = busquedaDeDestino(fila.destino, comun)
  const elegida = semanas.at(-1)
  const sinPartir = local !== null && fila.soloSinLocal === true
  const cambio = elegida && !sinPartir ? cambioDeFila(fila, elegida.cifras, anterior) : null
  const alto = fila.sumando ? 'h-7' : 'h-9'

  return (
    <tr
      onClick={() => void navigate({ to: '/admin/metricas', search: busqueda })}
      className={`group cursor-pointer border-t border-panel-hairline transition-colors duration-[var(--transition-fast)] hover:bg-panel-raised ${alto}`}
    >
      <th
        scope="row"
        className={`sticky left-0 z-10 bg-panel-card py-0 pr-4 text-left font-normal transition-colors duration-[var(--transition-fast)] group-hover:bg-panel-raised ${
          fila.sumando ? 'pl-4' : 'pl-0'
        }`}
      >
        <Tooltip contenido={ayudaDeFila(fila)}>
          <Link
            to="/admin/metricas"
            search={busqueda}
            aria-label={`${fila.nombre}${fila.unidad ? `, ${fila.unidad}` : ''}: ver en ${nombreDelDestino(fila.destino)}`}
            onClick={(event) => event.stopPropagation()}
            className={`inline-flex items-baseline gap-1.5 whitespace-nowrap hover:underline hover:underline-offset-2 ${
              fila.sumando ? 'type-panel-caption text-panel-muted' : 'type-panel-body font-medium text-on-surface'
            }`}
          >
            {fila.sumando ? `de ello, ${fila.nombre}` : fila.nombre}
            {fila.unidad && <span className="type-panel-caption text-panel-muted">{fila.unidad}</span>}
          </Link>
        </Tooltip>
      </th>

      {sinPartir ? (
        <td colSpan={semanas.length + 1} className="py-0 pl-2">
          <NoSeParte />
        </td>
      ) : (
        <>
          {semanas.map((s, i) => (
            <Celda
              key={s.desde}
              valor={fila.valor(s.cifras)}
              fila={fila}
              elegida={i === semanas.length - 1}
            />
          ))}
          <td
            className={`py-0 pr-1 pl-3 text-right type-panel-caption font-bold whitespace-nowrap ${
              cambio ? COLOR_DEL_CAMBIO[cambio.tono] : 'text-panel-muted'
            }`}
          >
            {fila.sumando ? '' : <Cambio cambio={cambio} />}
          </td>
        </>
      )}
    </tr>
  )
}

function Celda({ valor, fila, elegida }: { valor: number | null; fila: DefinicionDeFila; elegida: boolean }) {
  const texto = escribir(valor, fila.formato)
  // Un cero se escribe, pero apagado: se ve de un vistazo qué semanas no tuvieron nada.
  const tono = elegida
    ? 'font-bold text-on-surface'
    : valor === null || valor === 0
      ? 'text-panel-muted'
      : 'text-on-surface-variant'
  const tamano = fila.sumando ? 'type-panel-caption' : 'type-panel-body'

  return (
    <td
      className={`py-0 pr-3 pl-3 text-right whitespace-nowrap tabular-nums ${tamano} ${tono} ${
        elegida ? CLASE_ELEGIDA : ''
      }`}
    >
      {valor === null ? (
        // La raya se ve; por qué va en raya lo dice la ayuda de la fila, y
        // aquí se le lee al lector de pantalla.
        <>
          <span aria-hidden>{texto}</span>
          <span className="sr-only">{motivoDeRaya(fila)}</span>
        </>
      ) : (
        texto
      )}
    </td>
  )
}

/**
 * El cambio frente a la anterior: corto a la vista («▲ 12 %») y entero para
 * el lector de pantalla («12 % más»). Sin cambio, una raya.
 */
function Cambio({ cambio }: { cambio: Delta | null }) {
  if (!cambio) return <>—</>
  return (
    <>
      <span aria-hidden>{cambio.corto}</span>
      <span className="sr-only">{cambio.texto}</span>
    </>
  )
}
