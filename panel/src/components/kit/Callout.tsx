import { CircleAlert, CircleCheck, Info, TriangleAlert } from 'lucide-react'
import type { LucideIcon } from 'lucide-react'
import type { ReactNode } from 'react'

export type TonoDeCallout = 'info' | 'warning' | 'error' | 'success'

const ESTILO: Record<TonoDeCallout, { caja: string; color: string; Icono: LucideIcon }> = {
  // `info` no es un estado: va en gris, sin color que avise.
  info: { caja: 'border-panel-hairline bg-panel-raised', color: 'text-on-surface-variant', Icono: Info },
  warning: { caja: 'border-warning/28 bg-warning/7', color: 'text-warning', Icono: TriangleAlert },
  error: { caja: 'border-error/28 bg-error/7', color: 'text-error', Icono: CircleAlert },
  success: { caja: 'border-success/28 bg-success/7', color: 'text-success', Icono: CircleCheck },
}

/**
 * Un aviso con forma: icono, título, una línea y, si hace falta, la acción
 * que lo resuelve.
 *
 * Sustituye las cajas `border-warning/40 bg-warning/10` que cada pantalla
 * hacía a mano, cada una con su borde, su relleno y su tamaño de letra. Lo que
 * no cabe en una línea va a `detalles`, plegado: el aviso se lee de un vistazo
 * y el porqué se abre si se quiere.
 *
 * Un error se anuncia al lector de pantalla en cuanto aparece (`alert`); los
 * demás esperan a que termine de hablar (`status`).
 */
export function Callout({
  tone,
  titulo,
  children,
  accion,
  detalles,
  className = '',
}: {
  tone: TonoDeCallout
  titulo: string
  /** Una línea. Lo que no quepa va a `detalles`. */
  children?: ReactNode
  /** El botón que lo resuelve: «Importar», «Reintentar». */
  accion?: ReactNode
  /** Plegado bajo «Detalles». */
  detalles?: ReactNode
  className?: string
}) {
  const { caja, color, Icono } = ESTILO[tone]

  return (
    <div
      role={tone === 'error' ? 'alert' : 'status'}
      className={`flex flex-wrap items-start gap-x-3 gap-y-2 rounded-panel-card border p-3.5 ${caja} ${className}`}
    >
      <Icono size={18} aria-hidden className={`mt-px shrink-0 ${color}`} />
      <div className="flex min-w-0 flex-1 basis-48 flex-col gap-1">
        <p className="type-panel-body font-semibold text-on-surface">{titulo}</p>
        {children && <div className="type-panel-body text-on-surface-variant">{children}</div>}
        {detalles && (
          <details className="mt-1">
            <summary className="cursor-pointer type-panel-caption font-semibold text-on-surface-variant transition-colors hover:text-on-surface">
              Detalles
            </summary>
            <div className="mt-2 type-panel-body text-on-surface-variant">{detalles}</div>
          </details>
        )}
      </div>
      {accion && <div className="shrink-0 self-center">{accion}</div>}
    </div>
  )
}
