import { Paperclip, X } from 'lucide-react'

import { DataLabel } from '@/components/ui'

/**
 * El comprobante de una transferencia a un local.
 *
 * Va a un bucket privado: es un papel con datos bancarios de un tercero. No es
 * obligatorio (hay noches en que se paga en efectivo y no hay papel), pero
 * cuando existe es lo único que resuelve un «yo eso no lo recibí».
 */
export function AdjuntarComprobante({
  id,
  file,
  onChange,
}: {
  id: string
  file: File | null
  onChange: (file: File | null) => void
}) {
  return (
    <div>
      <DataLabel>Comprobante (opcional)</DataLabel>
      <div className="mt-shell-gap-stack flex h-panel-control-md items-center gap-2 rounded-panel-control bg-panel-control px-panel-pad-control">
        {file ? (
          <>
            <Paperclip size={14} className="shrink-0 text-on-surface-variant" aria-hidden />
            <span className="flex-1 truncate type-panel-body text-on-surface">{file.name}</span>
            <button
              type="button"
              onClick={() => onChange(null)}
              aria-label="Quitar el comprobante"
              className="shrink-0 text-on-surface-variant hover:text-on-surface"
            >
              <X size={14} />
            </button>
          </>
        ) : (
          <label
            htmlFor={id}
            className="flex w-full cursor-pointer items-center gap-2 type-panel-body text-on-surface-variant hover:text-on-surface"
          >
            <Paperclip size={14} aria-hidden /> Adjuntar imagen o PDF
          </label>
        )}
        <input
          id={id}
          type="file"
          accept="image/*,application/pdf"
          className="hidden"
          onChange={(e) => onChange(e.target.files?.[0] ?? null)}
        />
      </div>
    </div>
  )
}
