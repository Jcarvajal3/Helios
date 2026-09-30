import type { LucideIcon } from 'lucide-react'

import type { BadgeTone } from '@/components/ui'

import { TINTE_DE_TONO } from './tonos'

/**
 * El cuadradito con el icono del área: la cabecera de una tarjeta de Inicio,
 * de una cola, de una sección de otro equipo.
 *
 * Lee el tono de `data-area` —el de la pantalla, o el que ponga la tarjeta
 * sobre sí misma—, así que no hay que decirle de qué área es. Con un `tone`
 * de estado (los bloqueos de Inicio) lleva el color de ese estado: ahí lo que
 * importa ya no es de quién es, sino que algo está mal.
 *
 * Decorativo: siempre va junto al nombre del área o de lo que rotula.
 */
export function IconoDeArea({
  icon: Icono,
  tamano = 'md',
  tone,
}: {
  icon: LucideIcon
  /** sm = 28, md = 32. */
  tamano?: 'sm' | 'md'
  tone?: BadgeTone
}) {
  const color = tone === undefined ? 'bg-area-tinte text-area' : TINTE_DE_TONO[tone]

  return (
    <span
      aria-hidden
      className={`inline-flex shrink-0 items-center justify-center rounded-panel-control ${
        tamano === 'sm' ? 'size-7' : 'size-8'
      } ${color}`}
    >
      <Icono size={tamano === 'sm' ? 15 : 16} />
    </span>
  )
}
