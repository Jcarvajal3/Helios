import { SelectorDeFechas } from './SelectorDeFechas'
import { atajosDeRango, describirRango, rangoCorto, rangoDeAlLado } from './rango'
import type { Rango } from './rango'

/**
 * El periodo de una pantalla: «‹ 📅 27 ago – 25 sep ▾ ›». Las flechas van al
 * rango anterior y al siguiente; el botón abre los atajos y un rango propio.
 *
 * Puede estar vacío (`rango` a `null`): en una lista acotar por fechas es
 * opcional, y el botón dice entonces «Cualquier fecha», sin flechas porque no
 * hay nada de lo que ir al lado. Con `onQuitar` sale una equis que vuelve a
 * vaciarlo.
 */
export function Periodo({
  rango,
  hoy,
  onChange,
  atajos,
  maximo,
  rotuloVacio = 'Cualquier fecha',
  onQuitar,
}: {
  /** `null`: sin fechas. */
  rango: Rango | null
  /** El día operativo de hoy: de él salen los atajos. */
  hoy: string
  onChange: (rango: Rango) => void
  /** Por defecto, `atajosDeRango(hoy)`. */
  atajos?: ReadonlyArray<{ label: string; rango: Rango }>
  /** El último día elegible. Por defecto, hoy. */
  maximo?: string
  /** Lo que dice el botón sin rango. */
  rotuloVacio?: string
  /** Vacía el periodo. Con él aparece la equis; sin él, no se puede quitar. */
  onQuitar?: () => void
}) {
  const tope = maximo ?? hoy
  const lista = atajos ?? atajosDeRango(hoy)

  return (
    <SelectorDeFechas
      etiqueta="Periodo"
      rotulo={rango ? rangoCorto(rango) : rotuloVacio}
      titulo={rango ? describirRango(rango) : undefined}
      anterior={rango ? { onClick: () => onChange(rangoDeAlLado(rango, -1, tope)) } : undefined}
      siguiente={
        rango
          ? {
              onClick: () => onChange(rangoDeAlLado(rango, 1, tope)),
              disabled: rango.to >= tope,
              motivo: 'Ya llega hasta hoy.',
            }
          : undefined
      }
      opciones={lista.map((a) => ({
        clave: a.label,
        label: a.label,
        detalle: rangoCorto(a.rango),
        puesta: rango !== null && a.rango.from === rango.from && a.rango.to === rango.to,
        onElegir: () => onChange(a.rango),
      }))}
      rangoPropio={{ inicial: rango, maximo: tope, hoy, alAplicar: onChange }}
      onQuitar={rango ? onQuitar : undefined}
    />
  )
}
