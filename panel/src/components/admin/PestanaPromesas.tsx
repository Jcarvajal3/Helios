import { useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { Handshake, Play } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import { columnasPromesas } from '@/components/admin/ColumnasPromesas'
import { abrirCasoEnCola } from '@/components/admin/ficha-persona/CobranzaCola'
import {
  Button,
  Callout,
  EmptyState,
  FilterBar,
  Filtro,
  InfoDot,
  Segmented,
  SkeletonTable,
  formatDay,
  formatPct,
} from '@/components/ui'
import { consultaPromesas } from '@/features/admin/cobranza/consultas'
import { promesasDelEstado, tasaDeCumplimiento } from '@/features/admin/cobranza/promesas'
import type { Promesa } from '@/features/admin/cobranza/promesas'
import { VALORES_ESTADO_PROMESA, ESTADOS_PROMESA } from '@/features/admin/estados'
import type { EstadoPromesa } from '@/features/admin/estados'
import { describeError } from '@/lib/supabase'

/**
 * La pestaña «Promesas» de Por cobrar: las promesas de pago anotadas en las
 * gestiones, por estado. Las de los últimos 30 días operativos y todas las
 * futuras; una promesa rota más vieja se persigue desde la lista.
 */
export function PestanaPromesas({
  estado,
  onEstado,
}: {
  estado: EstadoPromesa
  onEstado: (estado: EstadoPromesa) => void
}) {
  const navigate = useNavigate()
  const promesas = useQuery(consultaPromesas())

  if (promesas.isPending) return <SkeletonTable rows={6} columns={6} />

  if (promesas.isError) {
    return (
      <Callout
        tone="error"
        titulo="No se pudieron leer las promesas"
        accion={
          <Button size="sm" variant="tonal" onClick={() => void promesas.refetch()}>
            Reintentar
          </Button>
        }
      >
        {describeError(promesas.error)}
      </Callout>
    )
  }

  const d = promesas.data
  const filas = promesasDelEstado(d.filas, estado)
  const tasa = tasaDeCumplimiento(d.recuento)
  // La cola sigue el orden en que se ven las filas, también si la persona
  // ordena por otra columna.
  function apuntarCola(enPantalla: Promesa[]) {
    abrirCasoEnCola({ lista: 'promesas', estado }, enPantalla.map((p) => p.userId))
  }

  function abrirCaso(p: Promesa | undefined, enPantalla: Promesa[] = filas) {
    if (!p) return
    apuntarCola(enPantalla)
    void navigate({ to: '/admin/pacientes/$id', params: { id: p.userId }, search: { tab: 'cobranza' } })
  }

  return (
    <>
      <FilterBar>
        <Filtro label="Estado">
          <Segmented
            options={VALORES_ESTADO_PROMESA.map((e) => ({
              value: e,
              label: `${ESTADOS_PROMESA[e].plural} · ${d.recuento[e]}`,
            }))}
            value={estado}
            onChange={onEstado}
          />
        </Filtro>

        <div className="ml-auto">
          <Button
            size="sm"
            disabled={filas.length === 0}
            title="No hay promesas en esta lista."
            onClick={() => abrirCaso(filas[0])}
          >
            <Play size={14} aria-hidden /> Empezar por la primera
          </Button>
        </div>
      </FilterBar>

      {filas.length === 0 ? (
        <EmptyState
          icon={<Handshake size={40} />}
          title={`Ninguna promesa ${ESTADOS_PROMESA[estado].label.toLowerCase()}`}
          description="Las promesas se anotan con «Anotar una gestión», en la lista o en el caso de cada paciente."
        />
      ) : (
        <DataTable
          rows={filas}
          rowKey={(p) => p.gestionId}
          columns={columnasPromesas(apuntarCola)}
          noun={['promesa', 'promesas']}
          summary={
            <span className="inline-flex flex-wrap items-center gap-1">
              Promesas cumplidas desde el {formatDay(d.desde)}:{' '}
              {tasa.pct === null
                ? 'sin promesas resueltas todavía'
                : `${formatPct(tasa.pct, 0)} (${tasa.cumplidas} de ${tasa.resueltas} resueltas)`}
              <InfoDot
                title="Promesas cumplidas (%)"
                what="Cumplidas ÷ (cumplidas + rotas), de las promesas con fecha prometida desde esa fecha. Las pendientes y las que vencen hoy todavía no cuentan."
              />
            </span>
          }
          exportar={{ archivo: `promesas-${estado}` }}
          onRowClick={abrirCaso}
        />
      )}
    </>
  )
}
