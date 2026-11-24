import { useEffect } from 'react'
import { X } from 'lucide-react'

import type { SeccionListaSimulador } from '@/features/admin/compras/tipos'
import type { Respuesta } from './Burbuja'

/** La hoja que sube desde abajo cuando se pulsa el botón de una lista de WhatsApp. */
export function HojaDeLista({
  titulo,
  secciones,
  onElegir,
  onCerrar,
}: {
  titulo: string
  secciones: SeccionListaSimulador[]
  onElegir: (r: Respuesta) => void
  onCerrar: () => void
}) {
  useEffect(() => {
    function alTeclear(e: KeyboardEvent) {
      if (e.key === 'Escape') onCerrar()
    }
    document.addEventListener('keydown', alTeclear)
    return () => document.removeEventListener('keydown', alTeclear)
  }, [onCerrar])

  return (
    <div className="absolute inset-0 z-10 flex flex-col justify-end bg-black/30">
      <button
        type="button"
        aria-label="Cerrar la lista"
        className="flex-1"
        onClick={onCerrar}
      />
      <div
        role="dialog"
        aria-label={titulo}
        className="max-h-[75%] overflow-y-auto rounded-t-panel-card bg-shell-canvas p-3 shadow-lg"
      >
        <div className="mb-2 flex items-center justify-between">
          <h3 className="type-panel-body font-semibold text-on-surface">
            {titulo}
          </h3>
          <button
            type="button"
            aria-label="Cerrar"
            onClick={onCerrar}
            className="p-1 text-on-surface-variant"
          >
            <X size={16} aria-hidden />
          </button>
        </div>
        {secciones.map((s, i) => (
          <section key={`${s.title}-${i}`} className="mb-2">
            {s.title && (
              <p className="px-1 type-panel-label text-on-surface-variant">
                {s.title}
              </p>
            )}
            <ul>
              {s.rows.map((f) => (
                <li key={f.id}>
                  <button
                    type="button"
                    onClick={() => onElegir({ id: f.id, title: f.title })}
                    className="w-full rounded-panel-control px-2 py-2 text-left hover:bg-panel-control"
                  >
                    <span className="block type-panel-body text-on-surface">
                      {f.title}
                    </span>
                    {f.description && (
                      <span className="block type-panel-caption text-on-surface-variant">
                        {f.description}
                      </span>
                    )}
                  </button>
                </li>
              ))}
            </ul>
          </section>
        ))}
      </div>
    </div>
  )
}
