import { useEffect, useRef, useState } from 'react'

import { Filtro, Periodo, SearchInput, diaOperativo, rangoCorto } from '@/components/ui'
import type { Rango } from '@/components/ui'

// ═══════════════════════════════════════════════════════════════════════════
// Los filtros de una lista cuyo valor vive en la URL: el buscador de texto y
// el rango de fechas.
//
// La URL es la que manda: recargar, volver atrás o pegar el enlace en un chat
// deja la lista como estaba. Antes había tres piezas para esto repartidas por
// Caja y Directorio, y dos de ellas hacían lo mismo con reglas distintas para
// el texto que llega de fuera.
// ═══════════════════════════════════════════════════════════════════════════

/** Lo que se espera desde la última tecla antes de escribir en la URL. */
const RETARDO_MS = 300

/** Lo que se escribe en la URL: recortado, y vacío como «sin búsqueda». */
export function textoParaUrl(texto: string): string | undefined {
  const limpio = texto.trim()
  return limpio === '' ? undefined : limpio
}

/**
 * Si el campo tiene que tomar lo que dice la URL. No, si la URL dice lo mismo
 * que ya está escrito: sin esa excepción, el espacio de «maría |» se borraría
 * mientras se escribe, porque la URL guarda el texto recortado.
 */
export function campoSigueALaUrl(enUrl: string | undefined, texto: string): boolean {
  return (enUrl ?? '') !== texto.trim()
}

/**
 * Un texto que vive en la URL sin escribir en ella a cada tecla.
 *
 *   const [texto, setTexto] = useTextoEnUrl(search.q, (q) =>
 *     void navigate({ search: (prev) => ({ ...prev, q }), replace: true }),
 *   )
 *
 * El campo responde al momento con su estado local y la URL se actualiza tras
 * una pausa (`retardo`); quien escribe en la URL usa `replace`, para que
 * «atrás» no recorra cada letra. Si la URL cambia por fuera —«Quitar los
 * filtros», el botón de atrás, un enlace—, manda la URL. Vacío se escribe como
 * `undefined`: la URL no guarda `?q=`.
 *
 * Para el caso normal, un buscador con su rótulo, está `BuscadorEnUrl`.
 */
export function useTextoEnUrl(
  enUrl: string | undefined,
  escribir: (valor: string | undefined) => void,
  retardo = RETARDO_MS,
): readonly [string, (texto: string) => void] {
  const [texto, setTexto] = useState(enUrl ?? '')
  const [previa, setPrevia] = useState(enUrl)

  // Lo que llega de fuera gana, salvo que sea lo mismo que ya está escrito.
  if (enUrl !== previa) {
    setPrevia(enUrl)
    if (campoSigueALaUrl(enUrl, texto)) setTexto(enUrl ?? '')
  }

  const escribirRef = useRef(escribir)
  useEffect(() => {
    escribirRef.current = escribir
  }, [escribir])

  useEffect(() => {
    const limpio = textoParaUrl(texto)
    if (limpio === enUrl) return
    const espera = setTimeout(() => escribirRef.current(limpio), retardo)
    return () => clearTimeout(espera)
  }, [texto, enUrl, retardo])

  return [texto, setTexto] as const
}

/**
 * El buscador de una lista, con lo buscado en la URL.
 *
 * Escribir en la URL en cada tecla dispararía una consulta por letra, así que
 * el campo lleva su propio texto y lo pasa a la URL al dejar de teclear (ver
 * `useTextoEnUrl`). `onBuscar` escribe con `replace`: una búsqueda no es un
 * paso del historial.
 */
export function BuscadorEnUrl({
  id,
  label = 'Buscar',
  valor,
  placeholder,
  onBuscar,
  className = 'w-full sm:w-80',
}: {
  id: string
  label?: string
  /** Lo que dice la URL ahora. */
  valor: string | undefined
  placeholder?: string
  /** Escribe en la URL. `undefined` es «sin búsqueda». */
  onBuscar: (texto: string | undefined) => void
  className?: string
}) {
  const [texto, setTexto] = useTextoEnUrl(valor, onBuscar)

  return (
    <SearchInput
      id={id}
      label={label}
      value={texto}
      onChange={setTexto}
      placeholder={placeholder}
      className={className}
    />
  )
}

/**
 * El rango que puede pintar `Periodo`, o `null` si no hay uno completo.
 *
 * Con las dos fechas, esas. Con solo «desde», hasta hoy: aquí se buscan pagos
 * y transferencias, que no existen en el futuro, así que es la misma lista.
 * Con solo «hasta» no hay rango que dibujar sin inventarse el principio.
 */
export function rangoDelFiltro(
  desde: string | undefined,
  hasta: string | undefined,
  hoy: string,
): Rango | null {
  if (desde !== undefined && hasta !== undefined) return { from: desde, to: hasta }
  if (desde !== undefined) return { from: desde, to: desde > hoy ? desde : hoy }
  return null
}

/** Lo que dice el botón cuando no hay rango completo: «Cualquier fecha» o «Hasta el 25 sep». */
export function rotuloSinRango(hasta: string | undefined): string {
  return hasta === undefined ? 'Cualquier fecha' : `Hasta el ${rangoCorto({ from: hasta, to: hasta })}`
}

/**
 * Un rango de fechas dentro de un `Filtro` de una `FilterBar`.
 *
 * Es el `Periodo` del kit, lleno o vacío: con fechas, el rango escrito en
 * castellano («27 ago – 25 sep»); sin ellas, «Cualquier fecha». Los dos abren
 * los mismos atajos y el rango propio, y la equis quita las fechas. Vacío es
 * «sin límite»: aquí se busca un pago o una transferencia concreta, no se mira
 * una tendencia, y una lista acotada por defecto escondería lo viejo.
 */
export function FiltroFechas({
  id,
  label,
  desde,
  hasta,
  max,
  onChange,
}: {
  id: string
  label: string
  desde: string | undefined
  hasta: string | undefined
  /** El último día elegible, normalmente hoy. Sin él, el día operativo de hoy. */
  max?: string
  onChange: (rango: { desde: string | undefined; hasta: string | undefined }) => void
}) {
  const hoy = max ?? diaOperativo()
  const rango = rangoDelFiltro(desde, hasta, hoy)
  const hayFechas = desde !== undefined || hasta !== undefined

  return (
    <Filtro label={label}>
      <div id={id} className="flex items-center">
        <Periodo
          rango={rango}
          hoy={hoy}
          maximo={hoy}
          rotuloVacio={rotuloSinRango(hasta)}
          onChange={(r) => onChange({ desde: r.from, hasta: r.to })}
          onQuitar={hayFechas ? () => onChange({ desde: undefined, hasta: undefined }) : undefined}
        />
      </div>
    </Filtro>
  )
}
