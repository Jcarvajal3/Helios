import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'

import { ErrorBox, FilterBar, Filtro, Segmented, Select, Tabs, formatDay } from '@/components/ui'
import { HistoricoTransferencias } from '@/components/admin/caja/HistoricoTransferencias'
import { LoQueSeDebeHoy, OPCIONES_SOLO } from '@/components/admin/caja/LoQueSeDebeHoy'
import type { SoloLocales } from '@/components/admin/caja/LoQueSeDebeHoy'
import { UnCierreDeCaja, estadoDelCierre } from '@/components/admin/caja/UnCierreDeCaja'
import { fetchSettlementRuns } from '@/features/admin/api'
import { METODOS_DE_PAGO } from '@/features/admin/liquidaciones'
import type { PayoutMethod } from '@/features/admin/liquidaciones'
import { comoDia, comoId, unoDe } from '@/lib/busqueda'
import { describeError } from '@/lib/supabase'

type PagosSearch = {
  /** `pagos` es el histórico de transferencias; sin valor, lo que se debe. */
  vista?: 'pagos'
  /** Un cierre concreto (su lunes); sin él, lo que se debe hoy. */
  cierre?: string
  /** Lo que se debe hoy, acotado a los locales con atraso o que cobran este lunes. */
  solo?: SoloLocales
  local?: string
  desde?: string
  hasta?: string
  medio?: PayoutMethod
}

const MEDIOS: readonly PayoutMethod[] = METODOS_DE_PAGO.map((m) => m.value)
const SOLOS: readonly SoloLocales[] = ['atrasados', 'este-cierre']

export const Route = createFileRoute('/admin/pagos-clinicas')({
  staticData: { title: 'Pagos a clínicas', width: 'wide' },
  component: PagosALocales,
  validateSearch: (search: Record<string, unknown>): PagosSearch => ({
    vista: unoDe(['pagos'], search.vista),
    cierre: comoDia(search.cierre),
    solo: unoDe(SOLOS, search.solo),
    local: comoId(search.local),
    desde: comoDia(search.desde),
    hasta: comoDia(search.hasta),
    medio: unoDe(MEDIOS, search.medio),
  }),
})

/*
 * Pagos a locales.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Dos preguntas, dos pestañas, y cada fila abre una página propia.
 *
 *   POR PAGAR      ¿a quién le debo y cuánto? Es la tarea del lunes. Trae el
 *                  selector de cierre, para mirar cualquier semana de caja.
 *   TRANSFERENCIAS ¿qué se les ha pagado a los locales? El histórico
 *                  completo, filtrable por local, fechas y medio.
 */
function PagosALocales() {
  const navigate = useNavigate({ from: '/admin/pagos-clinicas' })
  const search = Route.useSearch()

  function cambiar(patch: Partial<PagosSearch>) {
    void navigate({ search: (prev) => ({ ...prev, ...patch }) })
  }

  return (
    <>
      <Tabs
        options={[
          { value: 'deuda', label: 'Por pagar' },
          { value: 'pagos', label: 'Transferencias' },
        ]}
        value={search.vista === 'pagos' ? 'pagos' : 'deuda'}
        onChange={(v) => cambiar({ vista: v === 'pagos' ? 'pagos' : undefined })}
      />

      {search.vista === 'pagos' ? (
        <HistoricoTransferencias
          filtros={{ local: search.local, desde: search.desde, hasta: search.hasta, medio: search.medio }}
          onCambiar={cambiar}
        />
      ) : (
        <PorPagar cierre={search.cierre} solo={search.solo} onCambiar={cambiar} />
      )}
    </>
  )
}

function PorPagar({
  cierre,
  solo,
  onCambiar,
}: {
  cierre: string | undefined
  solo: SoloLocales | undefined
  onCambiar: (patch: Partial<PagosSearch>) => void
}) {
  const runs = useQuery({
    queryKey: ['settlement-runs'],
    queryFn: fetchSettlementRuns,
    refetchInterval: 60_000,
  })

  const elegido = (runs.data ?? []).find((r) => r.runDate === cierre)

  // Un desplegable y no una tira de pestañas: la lista crece un lunes por
  // semana y para siempre.
  const opciones = [
    { value: '', label: 'Lo que se debe hoy' },
    ...(runs.data ?? []).map((r) => ({
      value: r.runDate,
      label: `Cierre del ${formatDay(r.runDate)} · ${estadoDelCierre(r)}`,
    })),
  ]

  return (
    <>
      <FilterBar>
        <Select
          id="cierre-de-caja"
          label="Cierre de caja"
          value={cierre ?? ''}
          options={opciones}
          onChange={(value) => onCambiar({ cierre: value || undefined, solo: undefined })}
          className="w-full max-w-sm"
        />
        {!elegido && (
          <Filtro label="Clínicas">
            <Segmented
              options={[...OPCIONES_SOLO]}
              value={solo ?? ''}
              onChange={(value) => onCambiar({ solo: value || undefined })}
            />
          </Filtro>
        )}
      </FilterBar>

      {runs.isError && (
        <div className="mb-6">
          <ErrorBox title="No se pudo cargar la lista de cierres" detail={describeError(runs.error)} />
        </div>
      )}

      {elegido ? (
        <UnCierreDeCaja run={elegido} />
      ) : (
        <LoQueSeDebeHoy solo={solo} onSolo={(s) => onCambiar({ solo: s })} />
      )}
    </>
  )
}
