import { useState } from 'react'
import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import {
  AlarmClock,
  Banknote,
  CircleAlert,
  CircleCheck,
  MessageCircle,
  NotebookPen,
  Phone,
  Store,
} from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

import { EstadoBadge } from '@/components/admin/EstadoBadge'
import { Badge, Button, formatDateTime, formatDay, formatUsd } from '@/components/ui'
import { textoDeDesgloseCorto } from '@/features/admin/metricas/formato'
import { desgloseDelPago } from './desgloseDelPago'
import type { Canal } from '@/features/admin/cobranza/gestion'
import { ROTULO_CANAL } from '@/features/admin/cobranza/gestion'
import type { Suceso } from '@/features/admin/cobranza/lineaDeTiempo'
import { InsigniaPromesa, InsigniaResultado } from './CobranzaInsignias'

/** Cuántos sucesos se ven de entrada, y cuántos más con cada «Ver más». */
const TANDA = 15

/**
 * La línea de tiempo del caso, lo último arriba.
 *
 * No tiene tope silencioso: se ve una tanda y «Ver más» enseña la siguiente,
 * con el recuento de lo que queda escrito en el botón.
 */
export function LineaDeTiempo({ sucesos }: { sucesos: ReadonlyArray<Suceso> }) {
  const [visibles, setVisibles] = useState(TANDA)
  const quedan = sucesos.length - visibles

  if (sucesos.length === 0) {
    return (
      <p className="type-panel-body text-on-surface-variant">
        Este paciente no tiene nada en su historial de cobranza.
      </p>
    )
  }

  return (
    <div>
      <ol className="flex flex-col">
        {sucesos.slice(0, visibles).map((s) => (
          <li key={s.id}>
            <FilaDeSuceso suceso={s} />
          </li>
        ))}
      </ol>

      {quedan > 0 && (
        <Button
          size="sm"
          variant="text"
          className="mt-2"
          onClick={() => setVisibles((v) => v + TANDA)}
        >
          Ver más ({quedan} {quedan === 1 ? 'queda' : 'quedan'})
        </Button>
      )}
    </div>
  )
}

const ICONO_CANAL: Record<Canal, LucideIcon> = {
  whatsapp: MessageCircle,
  llamada: Phone,
  en_local: Store,
  otro: NotebookPen,
}

type Tono = 'neutral' | 'warning' | 'error' | 'success'

const PUNTO: Record<Tono, string> = {
  neutral: 'bg-panel-control text-on-surface-variant',
  warning: 'bg-warning/14 text-warning',
  error: 'bg-error/14 text-panel-critico',
  success: 'bg-success/14 text-success',
}

/** Un suceso: el icono en su carril, lo que pasó y cuándo. */
function Paso({
  icono: Icono,
  tono = 'neutral',
  titulo,
  cuando,
  children,
}: {
  icono: LucideIcon
  tono?: Tono
  titulo: ReactNode
  cuando: string
  children?: ReactNode
}) {
  return (
    <div className="grid grid-cols-[2rem_1fr] gap-x-3">
      {/* El carril: el icono y la línea que baja hasta el siguiente. */}
      <div className="flex flex-col items-center">
        <span className={`grid size-8 shrink-0 place-items-center rounded-full ${PUNTO[tono]}`}>
          <Icono size={15} aria-hidden />
        </span>
        <span aria-hidden className="w-px flex-1 bg-panel-hairline-strong" />
      </div>

      <div className="min-w-0 pb-5 pt-1">
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1 type-panel-body text-on-surface">
          {titulo}
        </div>
        {children && (
          <div className="mt-1 flex flex-col gap-0.5 type-panel-caption text-on-surface-variant">
            {children}
          </div>
        )}
        <p className="mt-1 type-panel-caption tabular-nums text-on-surface-variant">
          {formatDateTime(cuando)}
        </p>
      </div>
    </div>
  )
}

function FilaDeSuceso({ suceso: s }: { suceso: Suceso }) {
  switch (s.tipo) {
    case 'gestion': {
      const g = s.gestion
      return (
        <Paso
          icono={ICONO_CANAL[g.channel]}
          titulo={
            <>
              <span>
                {ROTULO_CANAL[g.channel]} · {g.actorName}
              </span>
              <InsigniaResultado resultado={g.outcome} />
            </>
          }
          cuando={s.cuando}
        >
          {g.note && <p className="italic">«{g.note}»</p>}
          {g.promiseDate && (
            <p className="flex flex-wrap items-center gap-2">
              Prometió pagar el {formatDay(g.promiseDate)}
              <InsigniaPromesa estado={g.promiseStatus} />
            </p>
          )}
          {g.nextActionOn && <p>Volver a llamar el {formatDay(g.nextActionOn)}</p>}
          {g.template && <p>Plantilla «{g.template}»</p>}
        </Paso>
      )
    }

    case 'pago': {
      const p = s.pago
      return (
        <Paso
          icono={Banknote}
          tono={p.status === 'reconciled' ? 'success' : p.status === 'rejected' ? 'error' : 'neutral'}
          titulo={
            <>
              <Link
                to="/admin/cobros/$id"
                params={{ id: p.id }}
                className="text-on-surface underline decoration-panel-hairline-strong underline-offset-2 hover:decoration-on-surface"
              >
                Reportó un pago de {formatUsd(p.amountUsd)}
              </Link>
              <EstadoBadge tipo="pago" valor={p.status} />
            </>
          }
          cuando={s.cuando}
        >
          <p>
            {p.bank ?? p.method}
            {p.reference && ` · referencia ${p.reference}`}
          </p>
          {p.partes && <p>{desgloseDelPago(p.partes)}</p>}
          {p.rejectionNote && <p>{p.rejectionNote}</p>}
        </Paso>
      )
    }

    case 'vencio': {
      const c = s.cuota
      return (
        <Paso
          icono={CircleAlert}
          tono={c.paidAt ? 'warning' : 'error'}
          titulo={
            <span>
              Venció la cuota {c.sequence} de {c.merchantName}: {formatUsd(c.amountUsd)} (
              {textoDeDesgloseCorto({ financedUsd: c.financedUsd, feeUsd: c.amountUsd - c.financedUsd })})
            </span>
          }
          cuando={s.cuando}
        >
          <p>
            {c.orderNumber !== null && `Orden #${c.orderNumber} · `}
            {c.paidAt ? `La pagó el ${formatDateTime(c.paidAt)}` : 'Sigue sin pagarse'}
          </p>
        </Paso>
      )
    }

    case 'pagada': {
      const c = s.cuota
      return (
        <Paso
          icono={CircleCheck}
          tono="success"
          titulo={
            <>
              <span>
                Pagó la cuota {c.sequence} de {c.merchantName}: {formatUsd(c.amountUsd)} (
                {textoDeDesgloseCorto({ financedUsd: c.financedUsd, feeUsd: c.amountUsd - c.financedUsd })})
              </span>
              {s.conAtraso && (
                <Badge tone="warning" icono>
                  Cobrada con atraso
                </Badge>
              )}
            </>
          }
          cuando={s.cuando}
        >
          {c.orderNumber !== null && <p>Orden #{c.orderNumber}</p>}
        </Paso>
      )
    }

    case 'cargo': {
      const f = s.cargo
      const condonado = f.status === 'written_off' && f.waivedAt !== null
      return (
        <Paso
          icono={AlarmClock}
          tono={f.status === 'pending' ? 'warning' : 'neutral'}
          titulo={
            <>
              <span>Cargo por atraso de {formatUsd(f.amountUsd)}</span>
              <Badge tone={f.status === 'pending' ? 'warning' : f.status === 'paid' ? 'success' : 'neutral'}>
                {f.status === 'pending'
                  ? 'Pendiente'
                  : f.status === 'paid'
                    ? 'Cobrado'
                    : condonado
                      ? 'Condonado'
                      : 'Perdido'}
              </Badge>
            </>
          }
          cuando={s.cuando}
        >
          {f.sequence !== null && (
            <p>
              Sobre la cuota {f.sequence}
              {f.merchantName && ` de ${f.merchantName}`}
              {f.dueDate && `, que vencía el ${formatDay(f.dueDate)}`}
            </p>
          )}
          {condonado && f.waiveReason && <p>Motivo: {f.waiveReason}</p>}
        </Paso>
      )
    }
  }
}
