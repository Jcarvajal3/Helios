import { Fragment } from 'react'
import { CheckCheck } from 'lucide-react'
import type { ReactNode } from 'react'

import { VerCaptura } from '@/components/admin/caja/VerCaptura'
import { hora } from '@/components/admin/whatsapp/horas'
import type {
  BotonSimulador,
  MensajeSimulador,
  SeccionListaSimulador,
} from '@/features/admin/compras/tipos'

export type Respuesta = { id: string; title: string }

export type HojaAbierta = { button: string; sections: SeccionListaSimulador[] }

/** El `*negrita*` de WhatsApp; el resto del texto va tal cual, sin interpretar nada más. */
export function ConNegritas({ texto }: { texto: string }): ReactNode {
  return texto
    .split(/(\*[^*\n]+\*)/g)
    .map((t, i) =>
      t.length > 2 && t.startsWith('*') && t.endsWith('*') ? (
        <strong key={i}>{t.slice(1, -1)}</strong>
      ) : (
        <Fragment key={i}>{t}</Fragment>
      ),
    )
}

const CLASE_BOTON =
  'rounded-panel-control bg-panel-control px-3 py-2 text-center type-panel-control text-primary hover:bg-shell-inset disabled:opacity-50'

/** Una burbuja de la conversación, en una de las formas canónicas del contrato. */
export function Burbuja({
  m,
  ocupado,
  onResponder,
  onAbrirLista,
}: {
  m: MensajeSimulador
  ocupado: boolean
  onResponder: (r: Respuesta) => void
  onAbrirLista: (h: HojaAbierta) => void
}) {
  const c = m.contenido
  const delMedico = m.direction === 'in'
  const botones: BotonSimulador[] = c.kind === 'buttons' ? c.buttons : []

  return (
    <div
      className={`flex max-w-[min(32rem,88%)] flex-col gap-1.5 ${delMedico ? 'self-end' : 'self-start'}`}
    >
      <div
        className={`rounded-panel-card px-3 py-2 ${delMedico ? 'bg-primary/14' : 'bg-panel-raised'}`}
      >
        {c.kind === 'image' && (
          <VerCaptura ruta={c.receiptPath} rotulo="Ver captura enviada" />
        )}
        {m.body && (
          <p className="whitespace-pre-wrap type-panel-body text-on-surface [overflow-wrap:anywhere]">
            <ConNegritas texto={m.body} />
          </p>
        )}
        <p className="mt-1 flex items-center justify-end gap-1 type-panel-caption tabular-nums text-panel-muted">
          {hora(new Date(m.createdAt).getTime())}
          {delMedico && <CheckCheck size={12} aria-label="Enviado" />}
        </p>
      </div>

      {botones.map((b) => (
        <button
          key={b.id}
          type="button"
          disabled={ocupado}
          onClick={() => onResponder(b)}
          className={CLASE_BOTON}
        >
          {b.title}
        </button>
      ))}

      {c.kind === 'list' && (
        <button
          type="button"
          disabled={ocupado}
          onClick={() =>
            onAbrirLista({ button: c.button, sections: c.sections })
          }
          className={CLASE_BOTON}
        >
          {c.button}
        </button>
      )}
    </div>
  )
}
