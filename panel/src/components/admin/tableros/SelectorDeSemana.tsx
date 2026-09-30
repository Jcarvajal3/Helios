import { Badge, Button, rangoCorto, sumarDias } from '@/components/ui'
import type { OpcionDeFecha } from '@/components/ui'
import { describirSemana, domingoDe } from '@/features/admin/semana'
import { SelectorDePaso } from './SelectorDePaso'

/** Cuántas semanas hacia atrás ofrece la lista; más lejos se llega con las flechas. */
const SEMANAS_EN_LA_LISTA = 8

/** «Esta semana», «Semana pasada», «Hace 3 semanas», «Semana que viene». */
function nombreDeSemana(atras: number): string {
  if (atras === 0) return 'Esta semana'
  if (atras === 1) return 'Semana pasada'
  if (atras === -1) return 'Semana que viene'
  if (atras < 0) return `Dentro de ${-atras} semanas`
  return `Hace ${atras} semanas`
}

/**
 * La semana que se mira, de lunes a domingo: «‹ 📅 21 – 27 sep ▾ ›».
 *
 * La misma en el Resumen y en Por cobrar. Lo que cambia es hasta dónde se
 * llega: el Resumen no pasa de la semana en curso (el futuro no ha pasado) y
 * Por cobrar sí (lo que vence la semana que viene es justo una pregunta). La
 * semana en curso lleva su marca, y desde otra se vuelve con un botón.
 */
export function SelectorDeSemana({
  lunes,
  lunesHoy,
  onLunes,
  minimo,
  semanasFuturas = 0,
}: {
  lunes: string
  /** El lunes de la semana en curso. */
  lunesHoy: string
  onLunes: (lunes: string) => void
  /** El lunes más viejo que se puede pedir. Sin él, no hay tope. */
  minimo?: string
  /**
   * Cuántas semanas por delante de la en curso salen en la lista. Con cero,
   * la flecha hacia delante se apaga en la semana en curso.
   */
  semanasFuturas?: number
}) {
  const enCurso = lunes === lunesHoy
  const conFuturo = semanasFuturas > 0

  const opciones: OpcionDeFecha[] = []
  for (let atras = -semanasFuturas; atras < SEMANAS_EN_LA_LISTA; atras++) {
    const l = sumarDias(lunesHoy, -7 * atras)
    if (minimo && l < minimo) break
    opciones.push({
      clave: l,
      label: nombreDeSemana(atras),
      detalle: rangoCorto({ from: l, to: domingoDe(l) }),
      puesta: l === lunes,
      onElegir: () => onLunes(l),
    })
  }

  return (
    <SelectorDePaso
      etiqueta="Semana"
      rotulo={rangoCorto({ from: lunes, to: domingoDe(lunes) })}
      titulo={`Semana ${describirSemana(lunes)}`}
      anterior={{
        onClick: () => onLunes(sumarDias(lunes, -7)),
        disabled: minimo !== undefined && sumarDias(lunes, -7) < minimo,
        motivo: 'No se pueden mirar semanas más antiguas desde aquí.',
      }}
      siguiente={{
        onClick: () => onLunes(sumarDias(lunes, 7)),
        disabled: !conFuturo && lunes >= lunesHoy,
        motivo: 'Esta es la semana en curso.',
      }}
      opciones={opciones}
      extra={
        enCurso ? (
          <Badge>En curso</Badge>
        ) : (
          <Button variant="text" size="sm" onClick={() => onLunes(lunesHoy)}>
            Ir a la semana en curso
          </Button>
        )
      }
    />
  )
}
