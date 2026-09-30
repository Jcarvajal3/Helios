import type { ReactNode } from 'react'

import { SelectorDeFechas } from '@/components/ui'
import type { OpcionDeFecha, Paso } from '@/components/ui'

/**
 * Ir de un periodo al anterior o al siguiente: «‹ 📅 14 – 20 sep ›».
 *
 * Es el selector de fechas del panel con lo que se elige ya dado en pasos
 * sueltos: los lunes del paso entre tramos, los años de los feriados. Con
 * `opciones`, el rótulo abre la lista para saltar sin ir de uno en uno.
 */
export function SelectorDePaso({
  rotulo,
  titulo,
  etiqueta,
  anterior,
  siguiente,
  opciones,
  extra,
}: {
  /** Lo que se está mirando, corto: '14 – 20 sep', 'agosto de 2026'. */
  rotulo: string
  titulo?: string
  /** Qué se elige, para el lector de pantalla: 'Semana', 'Mes'. */
  etiqueta: string
  anterior: Paso
  siguiente: Paso
  opciones?: ReadonlyArray<OpcionDeFecha>
  extra?: ReactNode
}) {
  return (
    <SelectorDeFechas
      rotulo={rotulo}
      titulo={titulo}
      etiqueta={etiqueta}
      anterior={anterior}
      siguiente={siguiente}
      opciones={opciones}
      extra={extra}
    />
  )
}
