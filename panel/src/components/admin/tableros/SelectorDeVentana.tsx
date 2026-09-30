import { SelectorDeFechas, rangoCorto, sumarDias } from '@/components/ui'

/**
 * «Los últimos N días»: «📅 Últimos 30 días ▾».
 *
 * Para las lecturas que la base solo sabe hacer hasta hoy (`p_days`): no hay
 * un periodo anterior que mirar, así que no lleva flechas ni rango propio.
 * Es el mismo botón que el resto de selectores de fechas, para que se elija
 * igual en todas las pantallas; la lista dice qué fechas cubre cada opción.
 */
export function SelectorDeVentana<T extends string | number>({
  valor,
  opciones,
  hoy,
  onChange,
}: {
  valor: T
  /** Cada opción y cuántos días cubre. */
  opciones: ReadonlyArray<{ valor: T; dias: number }>
  /** El último día de la ventana: el operativo de hoy, casi siempre. */
  hoy: string
  onChange: (valor: T) => void
}) {
  const puesta = opciones.find((o) => o.valor === valor)
  const rango = (dias: number) => ({ from: sumarDias(hoy, -(dias - 1)), to: hoy })

  return (
    <SelectorDeFechas
      etiqueta="Ventana"
      rotulo={puesta ? `Últimos ${puesta.dias} días` : String(valor)}
      titulo={puesta ? rangoCorto(rango(puesta.dias)) : undefined}
      opciones={opciones.map((o) => ({
        clave: String(o.valor),
        label: `Últimos ${o.dias} días`,
        detalle: rangoCorto(rango(o.dias)),
        puesta: o.valor === valor,
        onElegir: () => onChange(o.valor),
      }))}
    />
  )
}
