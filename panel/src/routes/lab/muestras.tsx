import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useCallback } from 'react'

import { DetalleMuestra } from '@/components/lab/admin/muestras/DetalleMuestra'
import { ListaMuestras } from '@/components/lab/admin/muestras/ListaMuestras'
import type { FiltroMuestras } from '@/features/lab/admin'
import { ROTULO_ESTADO, ROTULO_PAGO } from '@/features/lab/tipos'
import type { EstadoMuestra, EstadoPago } from '@/features/lab/tipos'
import { comoDia, comoEntero, comoTexto, unoDe } from '@/lib/busqueda'

type MuestrasSearch = {
  estado?: EstadoMuestra
  pago?: EstadoPago
  medico?: string
  desde?: string
  hasta?: string
  q?: string
  pagina?: number
  /** La muestra abierta. */
  id?: string
}

const UUID = /^[0-9a-f-]{36}$/i

export const Route = createFileRoute('/lab/muestras')({
  staticData: { title: 'Muestras', width: 'wide' },
  component: MuestrasPage,
  validateSearch: (s: Record<string, unknown>): MuestrasSearch => {
    const desde = comoDia(s.desde)
    const hasta = comoDia(s.hasta)
    const ok = desde !== undefined && hasta !== undefined && desde <= hasta
    return {
      estado: unoDe(Object.keys(ROTULO_ESTADO) as EstadoMuestra[], s.estado),
      pago: unoDe(Object.keys(ROTULO_PAGO) as EstadoPago[], s.pago),
      medico: typeof s.medico === 'string' && UUID.test(s.medico) ? s.medico : undefined,
      desde: ok ? desde : undefined,
      hasta: ok ? hasta : undefined,
      q: comoTexto(s.q),
      pagina: comoEntero(s.pagina, { min: 2, max: 10_000 }),
      id: typeof s.id === 'string' && UUID.test(s.id) ? s.id : undefined,
    }
  },
})

function MuestrasPage() {
  const navigate = useNavigate({ from: '/lab/muestras' })
  const search = Route.useSearch()

  const cambiar = useCallback(
    (patch: Partial<FiltroMuestras>, reemplazar = false) => {
      void navigate({ search: (prev) => ({ ...prev, ...patch }), replace: reemplazar })
    },
    [navigate],
  )

  return (
    <>
      <ListaMuestras
        filtros={search}
        onCambiar={cambiar}
        onAbrir={(id) => void navigate({ search: (prev) => ({ ...prev, id }) })}
      />
      {search.id && (
        <DetalleMuestra
          id={search.id}
          onClose={() => void navigate({ search: (prev) => ({ ...prev, id: undefined }), replace: true })}
        />
      )}
    </>
  )
}
