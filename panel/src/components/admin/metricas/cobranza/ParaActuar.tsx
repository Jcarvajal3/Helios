import { Link } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { ArrowRight } from 'lucide-react'
import type { ReactNode } from 'react'

import { consultaAlertasPendientes, consultaPromesas } from '@/features/admin/metricas/cobranza/api'

const CLASE_ENLACE =
  'inline-flex h-9 items-center gap-1.5 rounded-panel-control bg-panel-raised px-3 type-panel-label text-on-surface transition-colors duration-[var(--transition-fast)] hover:bg-panel-control'

/** La cifra de un enlace, si ya se leyó y es de lo mismo que abre. */
function Cuantos({ n }: { n: number | undefined }) {
  if (n === undefined) return null
  return <span className="tabular-nums text-on-surface-variant">· {n}</span>
}

function Enlace({ children }: { children: ReactNode }) {
  return (
    <>
      {children}
      <ArrowRight size={14} aria-hidden />
    </>
  )
}

/**
 * Para actuar: a quién llamar primero (la cola de Por cobrar, con lo
 * vencido), las promesas que vencen hoy y las alertas sin revisar. Es de HOY,
 * sea cual sea la semana elegida: la cola se trabaja hoy.
 *
 * La cola va sin cifra: Por cobrar también lista la deuda ya dada por
 * perdida, y su número no sería el de «Vencido en cartera». Promesas y
 * Alertas no se filtran por local, así que con un local elegido van sin
 * cifra: una cifra del local que abre una lista de todos no cuadraría.
 */
export function ParaActuar({
  local,
}: {
  local: string | null
}) {
  const promesas = useQuery({ ...consultaPromesas(null), enabled: local === null })
  const alertas = useQuery({ ...consultaAlertasPendientes(), enabled: local === null })

  const conCifras = local === null
  const alertasSinRevisar = alertas.data ? alertas.data.pendientesAltas + alertas.data.pendientesMedias : undefined

  return (
    <nav aria-label="Para actuar" className="flex flex-wrap items-center gap-2.5">
      <span className="type-panel-caption text-panel-muted">Para actuar, hoy:</span>
      <Link to="/admin/cobranza" search={{ tramo: 'plazo_vencido' }} className={CLASE_ENLACE}>
        <Enlace>A quién llamar primero, en Por cobrar</Enlace>
      </Link>
      <Link to="/admin/cobranza" search={{ vista: 'promesas' }} className={CLASE_ENLACE}>
        <Enlace>
          Promesas que vencen hoy <Cuantos n={conCifras ? promesas.data?.recuento.vence_hoy : undefined} />
        </Enlace>
      </Link>
      <Link to="/admin/alertas" className={CLASE_ENLACE}>
        <Enlace>
          Alertas sin revisar <Cuantos n={conCifras ? alertasSinRevisar : undefined} />
        </Enlace>
      </Link>
    </nav>
  )
}
