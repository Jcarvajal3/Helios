import type { ReactNode } from 'react'

/**
 * La ficha a dos columnas: lo que se lee a la izquierda y, a la derecha, un
 * carril de 320 px con el resumen y las acciones.
 *
 * A 960 px la ficha dejaba 240 vacíos a la derecha y las cifras clave iban en
 * la cabecera y otra vez en la pestaña Resumen. Ahora las cifras viven en el
 * carril, que se ve desde cualquier pestaña, y la pestaña no las repite.
 *
 * Por debajo de `lg` el carril baja debajo de la cabecera: va antes que el
 * contenido en el documento, así que también se lee primero con el lector de
 * pantalla. `carrilFijo` lo deja pegado al desplazar (la decisión de un pago);
 * solo para un carril corto, que quepa en la pantalla.
 */
export function MarcoDeFicha({
  cabecera,
  carril,
  children,
  carrilFijo = false,
  etiquetaDelCarril = 'Resumen y acciones',
}: {
  /** Encima de las dos columnas: `CabeceraDeFicha`, o la barra de la cola. */
  cabecera?: ReactNode
  carril: ReactNode
  children: ReactNode
  carrilFijo?: boolean
  etiquetaDelCarril?: string
}) {
  return (
    <div className="flex flex-col gap-6">
      {cabecera}
      <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem] lg:items-start">
        <aside
          aria-label={etiquetaDelCarril}
          // Pegado bajo la barra de arriba, que también es fija: sin su alto
          // en el cálculo, el carril se metería debajo de ella.
          className={`flex min-w-0 flex-col gap-4 lg:col-start-2 lg:row-start-1 ${
            carrilFijo ? 'lg:sticky lg:top-[calc(var(--topbar-height)+--spacing(6))]' : ''
          }`}
        >
          {carril}
        </aside>
        <div className="flex min-w-0 flex-col gap-6 lg:col-start-1 lg:row-start-1">{children}</div>
      </div>
    </div>
  )
}
