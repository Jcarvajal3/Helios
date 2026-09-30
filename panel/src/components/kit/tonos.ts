import { Check, CircleAlert, TriangleAlert } from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

import type { BadgeTone } from '@/components/ui'

// ═══════════════════════════════════════════════════════════════════════════
// El color de cada tono, en un solo sitio.
//
// Lo usan la pastilla (`Badge`, `Tendencia`), el cuadradito del icono
// (`IconoDeArea`) y el medidor (`Meter`). Si cada pieza escribiera sus clases,
// el mismo «Alerta» saldría con dos ámbares.
//
// `brand` se pinta como neutral: era violeta y chocaba con el tono de Riesgo.
// El color de un estado solo sale cuando algo ESTÁ bien, en alerta o crítico.
// ═══════════════════════════════════════════════════════════════════════════

/** Fondo tintado y texto: la pastilla y el cuadradito del icono. */
export const TINTE_DE_TONO: Record<BadgeTone, string> = {
  neutral: 'bg-panel-control text-on-surface-variant',
  brand: 'bg-panel-control text-on-surface-variant',
  success: 'bg-success/14 text-success',
  warning: 'bg-warning/14 text-warning',
  error: 'bg-error/14 text-panel-critico',
}

/** Relleno sólido: la barra de un medidor. `area` es el tono de la pantalla. */
export const RELLENO_DE_TONO: Record<BadgeTone | 'area', string> = {
  area: 'bg-area',
  neutral: 'bg-panel-muted',
  brand: 'bg-panel-muted',
  success: 'bg-success',
  warning: 'bg-warning',
  error: 'bg-error',
}

/**
 * El icono de cada estado. Un estado se tiene que leer también sin color:
 * quien no distingue el rojo del verde ve la forma.
 */
export const ICONO_DE_TONO: Partial<Record<BadgeTone, LucideIcon>> = {
  success: Check,
  warning: TriangleAlert,
  error: CircleAlert,
}
