import type { TarjetaSimulador } from '@/features/admin/compras/tipos'
import { ConNegritas } from './Burbuja'
import type { Respuesta } from './Burbuja'

/** Carrusel de tarjetas de WhatsApp: imagen, texto y un botón por tarjeta. */
export function Carrusel({
  tarjetas,
  ocupado,
  onResponder,
}: {
  tarjetas: TarjetaSimulador[]
  ocupado: boolean
  onResponder: (r: Respuesta) => void
}) {
  return (
    <ul
      aria-label="Opciones del carrusel"
      className="-mx-1 flex snap-x snap-mandatory gap-2 overflow-x-auto px-1 pb-1"
    >
      {tarjetas.map((t) => (
        <li
          key={t.button.id}
          className="flex w-56 shrink-0 snap-start flex-col overflow-hidden rounded-panel-card border border-panel-hairline bg-panel-raised"
        >
          <img
            src={t.imageUrl}
            alt=""
            loading="lazy"
            className="h-32 w-full object-cover"
          />
          <p className="flex-1 whitespace-pre-wrap p-2.5 type-panel-caption text-on-surface">
            <ConNegritas texto={t.body} />
          </p>
          <button
            type="button"
            disabled={ocupado}
            onClick={() => onResponder(t.button)}
            className="border-t border-panel-hairline px-3 py-2 type-panel-control text-primary hover:bg-shell-inset disabled:opacity-50"
          >
            {t.button.title}
          </button>
        </li>
      ))}
    </ul>
  )
}
