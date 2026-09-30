import {
  Banknote,
  BookA,
  CircleAlert,
  Hash,
  MessageSquareText,
  ReceiptText,
  Store,
  User,
  Zap,
} from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

import { Badge } from '@/components/ui'
import type { Opcion } from './opciones'

/** El icono de cada clase. Las pantallas traen el suyo, el del menú. */
const ICONO: Record<Opcion['clase'], LucideIcon> = {
  pantalla: Hash,
  accion: Zap,
  cifra: Hash,
  termino: BookA,
  persona: User,
  local: Store,
  consumo: ReceiptText,
  pago: Banknote,
  fallo: CircleAlert,
  asistente: MessageSquareText,
}

/**
 * Un resultado de la paleta: una `option` del listbox.
 *
 * No recibe el foco. El foco se queda en la caja de texto (se sigue
 * escribiendo) y la opción señalada se anuncia con `aria-activedescendant`,
 * que es el patrón combobox de ARIA. Por eso el ratón no le quita el foco al
 * pulsar, y señalar con el ratón mueve la misma selección que las flechas.
 */
export function OpcionPaleta({
  opcion,
  id,
  activa,
  desplegada,
  onSenalar,
  onElegir,
}: {
  opcion: Opcion
  id: string
  activa: boolean
  desplegada: boolean
  onSenalar: (clave: string) => void
  onElegir: (opcion: Opcion, nuevaPestana: boolean) => void
}) {
  const { efecto } = opcion
  const Icono = opcion.icono ?? ICONO[opcion.clase]
  const apagada = efecto.tipo === 'apagada'
  const fallo = efecto.tipo === 'reintentar'

  const colorTitulo = fallo ? 'text-error' : apagada ? 'text-on-surface-variant' : 'text-on-surface'

  return (
    <div
      id={id}
      role="option"
      aria-selected={activa}
      aria-disabled={apagada || undefined}
      onMouseMove={() => onSenalar(opcion.clave)}
      onMouseDown={(e) => e.preventDefault()}
      onClick={(e) => onElegir(opcion, e.ctrlKey || e.metaKey)}
      // La rueda del ratón abre en otra pestaña, como en un enlace.
      onAuxClick={(e) => {
        if (e.button === 1 && efecto.tipo === 'abrir') onElegir(opcion, true)
      }}
      className={`flex items-start gap-3 rounded-panel-control px-3 py-2.5 transition-colors duration-[var(--transition-fast)] ${
        apagada ? 'cursor-default' : 'cursor-pointer'
      } ${activa ? 'bg-panel-raised' : ''}`}
    >
      <Icono
        size={16}
        aria-hidden
        className={`mt-0.5 shrink-0 ${fallo ? 'text-error' : 'text-on-surface-variant'}`}
      />

      {/* Cada línea, una sola línea: la lista se recorre con la vista, y la
          definición entera solo sale al desplegar un término. */}
      <span className="min-w-0 flex-1">
        <span className={`block truncate type-panel-body ${colorTitulo}`}>{opcion.titulo}</span>
        {opcion.detalle && (
          <span className="block truncate type-panel-caption text-panel-muted">{opcion.detalle}</span>
        )}
        {opcion.nota && (
          <span className="block truncate type-panel-caption text-panel-muted" title={opcion.nota}>
            {opcion.nota}
          </span>
        )}
        {efecto.tipo === 'apagada' && (
          <span className="block truncate type-panel-caption text-panel-muted">{efecto.motivo}</span>
        )}
        {efecto.tipo === 'desplegar' && desplegada && (
          <span className="mt-2 block type-panel-body text-on-surface">{efecto.definicion}</span>
        )}
      </span>

      {opcion.insignias.length > 0 && (
        <span className="flex shrink-0 flex-wrap justify-end gap-1">
          {opcion.insignias.map((i) => (
            <Badge key={i.texto} tone={i.tono}>
              {i.texto}
            </Badge>
          ))}
        </span>
      )}
    </div>
  )
}
