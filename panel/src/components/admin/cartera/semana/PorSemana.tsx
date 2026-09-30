import { useMemo } from 'react'
import { Link, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { ArrowRight, CalendarX2, PartyPopper } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { columnaDeSenales, columnasCartera } from '@/components/admin/ColumnasCartera'
import { abrirCasoEnCola } from '@/components/admin/ficha-persona/CobranzaCola'
import { CifrasDeLaSemana } from '@/components/admin/metricas/cohortes/CifrasDeLaSemana'
import { TarjetaDeCuota } from '@/components/admin/metricas/cohortes/TarjetaDeCuota'
import { SelectorDeLocal, useLocalesDeMetricas } from '@/components/admin/metricas/SelectorDeLocal'
import {
  Badge,
  EmptyState,
  FilterBar,
  Filtro,
  Segmented,
  SkeletonBlock,
  SkeletonTable,
  estadoDeConsulta,
  formatDay,
  formatUsd,
} from '@/components/ui'
import { desgloseCorto } from '@/features/admin/cobranza/cartera'
import { consultaDeudoresDeLaSemana, consultaTasa } from '@/features/admin/cobranza/consultas'
import {
  ROTULO_ESTADO_QUE_SE_DEBE,
  deLaCuota,
  sumasPorEstado,
} from '@/features/admin/cobranza/deudoresDeLaSemana'
import type { DeudorDeLaSemana, FiltroDeCuota } from '@/features/admin/cobranza/deudoresDeLaSemana'
import { busquedaDeMetricas } from '@/features/admin/metricas/busqueda'
import { consultaDeLaLista, consultaDelDetalle } from '@/features/admin/metricas/cohortes/consultas'
import { nombreDeCohorte, semanaLarga } from '@/features/admin/metricas/cohortes/semanas'
import type { Cohorte } from '@/features/admin/metricas/cohortes/tipos'
import { nombreDelLocal } from '@/features/admin/metricas/opcionesDeLocal'
import { csvDinero } from '@/lib/csv'
import { ListaDeSemanas } from './ListaDeSemanas'

const ENLACE =
  'inline-flex items-center gap-1.5 type-panel-label text-on-surface transition-colors duration-[var(--transition-fast)] hover:text-on-surface-variant'

/**
 * La semana que se abre sin elegir: la más reciente con algo vencido, que es
 * la que hay que cobrar. Si ninguna tiene nada vencido, la más reciente.
 */
export function semanaPorDefecto(cohortes: ReadonlyArray<Cohorte>): string | null {
  const conVencido = cohortes.find((c) => c.aCobrar.estados.vencida.importe.payableUsd > 0)
  if (conVencido) return conVencido.semana
  return cohortes.length > 0 ? cohortes[0].semana : null
}

/**
 * Por cobrar › Cohortes: lo consumido una semana (la cohorte, con su nombre:
 * A1, A2…), seguido hasta cobrar sus dos cuotas, y quién lo debe.
 *
 * A la izquierda todas las semanas de consumo; a la derecha la elegida: el
 * total a cobrar, lo cobrado, lo vencido y lo por vencer (las mismas cuatro
 * cifras de antes en Métricas › Cobros), la cuota 1 y la 2 por estado, y
 * debajo cada persona que debe algo de esa semana, con lo que debe de ella,
 * lo que debe en total y sus señales. Lo que la lista suma por estado es lo
 * de las tarjetas: salen de la misma fuente (`metricas.cuotas`).
 *
 * Todo lo que se cobra lleva el fee, con su desglose a la vista (Javier,
 * 28-09). Comparar esta semana con las demás es de Métricas › Cobros ›
 * Semanas, y se enlaza.
 */
export function PorSemana({
  cohorte,
  local,
  cuota,
  onCohorte,
  onLocal,
  onCuota,
}: {
  /** El lunes elegido; sin él, `semanaPorDefecto`. */
  cohorte: string | undefined
  local: string | null
  cuota: FiltroDeCuota
  onCohorte: (lunes: string) => void
  onLocal: (local: string | null) => void
  onCuota: (cuota: FiltroDeCuota) => void
}) {
  const lista = useQuery(consultaDeLaLista(local))
  // Los nombres (A1, A2…) cuentan desde la primera cohorte de TODOS los
  // locales: la de un local empieza cuando empezó él, y el nombre cambiaría.
  const todas = useQuery(consultaDeLaLista(null))
  const cohortesDeTodos = todas.data?.cohortes
  const primerLunes = cohortesDeTodos && cohortesDeTodos.length > 0 ? cohortesDeTodos[cohortesDeTodos.length - 1].semana : null
  const locales = useLocalesDeMetricas()
  const nombreLocal = local ? (nombreDelLocal(locales.data ?? [], local) ?? null) : null
  const semana = cohorte ?? (lista.data ? semanaPorDefecto(lista.data.cohortes) : null)
  const hoy = lista.data?.hoy ?? ''

  return (
    <div className="@container flex flex-col gap-4">
      <FilterBar>
        <Filtro label="Clínica">
          <SelectorDeLocal local={local} onCambiar={onLocal} />
        </Filtro>
      </FilterBar>

      <div className="grid grid-cols-1 items-start gap-6 @5xl:grid-cols-[18.75rem_minmax(0,1fr)]">
        <ListaDeSemanas
          lista={lista}
          semana={semana ?? ''}
          hoy={hoy}
          local={local}
          nombreLocal={nombreLocal}
          primerLunes={primerLunes}
        />
        {semana ? (
          <DetalleDeLaSemana
            semana={semana}
            local={local}
            nombreLocal={nombreLocal}
            cuota={cuota}
            onCuota={onCuota}
            ultimaConConsumo={lista.data?.cohortes[0] ?? null}
            onCohorte={onCohorte}
            nombre={primerLunes ? nombreDeCohorte(semana, primerLunes) : null}
          />
        ) : lista.isPending ? (
          <SkeletonBlock className="h-96 w-full rounded-panel-card" />
        ) : lista.isError ? null : (
          <EmptyState
            icon={<CalendarX2 size={40} aria-hidden />}
            title={nombreLocal ? `${nombreLocal} todavía no tiene financiamientos` : 'Todavía no hay financiamientos'}
            description="Cuando haya financiamientos, cada semana saldrá aquí con lo que hay que cobrar de ella y quién lo debe."
          />
        )}
      </div>
    </div>
  )
}

function DetalleDeLaSemana({
  semana,
  local,
  nombreLocal,
  cuota,
  onCuota,
  ultimaConConsumo,
  onCohorte,
  nombre,
}: {
  semana: string
  local: string | null
  nombreLocal: string | null
  cuota: FiltroDeCuota
  onCuota: (c: FiltroDeCuota) => void
  ultimaConConsumo: Cohorte | null
  onCohorte: (lunes: string) => void
  /** El nombre de la cohorte (A1, A2…), o `null` mientras no se sabe. */
  nombre: string | null
}) {
  const detalle = useQuery(consultaDelDetalle(semana, local))
  const d = detalle.data
  const cohorte = d?.cohorte ?? null
  const hoy = d?.hoy ?? ''

  return (
    <div
      aria-busy={detalle.isFetching || undefined}
      className={`@container flex min-w-0 flex-col gap-4 transition-opacity duration-[var(--transition-fast)] ${
        detalle.isPlaceholderData ? 'opacity-60' : ''
      }`}
    >
      <div className="flex min-h-9 flex-wrap items-center gap-x-5 gap-y-2">
        <h2 className="type-panel-section text-on-surface">
          {nombre && <span className="mr-2 text-on-surface-variant">{nombre}</span>}
          Lo que se financió {semanaLarga(semana)}
          {nombreLocal ? ` en ${nombreLocal}` : ''}
        </h2>
        <Link
          to="/admin/metricas"
          search={busquedaDeMetricas('cobros', {}, { semana, local: local ?? undefined }, 'calendario')}
          className={`ml-auto ${ENLACE}`}
        >
          Compararla con las otras semanas
          <ArrowRight size={14} aria-hidden />
        </Link>
      </div>

      {detalle.isError ? (
        <ErrorConReintento
          title="No se pudo leer esta semana"
          error={detalle.error}
          onReintentar={() => void detalle.refetch()}
        />
      ) : d && cohorte === null ? (
        <EmptyState
          icon={<CalendarX2 size={40} aria-hidden />}
          title={nombreLocal ? `Esa semana no hubo financiamientos en ${nombreLocal}` : 'Esa semana no hubo financiamientos'}
          description="Elige otra semana en la lista."
          action={
            ultimaConConsumo && ultimaConConsumo.semana !== semana ? (
              <button type="button" onClick={() => onCohorte(ultimaConConsumo.semana)} className={ENLACE}>
                Ir a la última con financiamiento, {semanaLarga(ultimaConConsumo.semana)}
                <ArrowRight size={14} aria-hidden />
              </button>
            ) : undefined
          }
        />
      ) : (
        <>
          <CifrasDeLaSemana
            cohorte={cohorte}
            hoy={hoy}
            estado={estadoDeConsulta(detalle)}
            onReintentar={() => void detalle.refetch()}
          />
          {cohorte ? (
            <div className="grid grid-cols-1 gap-4 @3xl:grid-cols-2">
              {cohorte.cuotas.map((q) => (
                <TarjetaDeCuota key={q.numero} cuota={q} hoy={hoy} />
              ))}
            </div>
          ) : (
            <div aria-hidden className="grid grid-cols-1 gap-4 @3xl:grid-cols-2">
              <SkeletonBlock className="h-72 w-full rounded-panel-card" />
              <SkeletonBlock className="h-72 w-full rounded-panel-card" />
            </div>
          )}
          <QuienDebe semana={semana} local={local} cuota={cuota} onCuota={onCuota} />
        </>
      )}
    </div>
  )
}

/**
 * Una pastilla por cuota y estado: dos consumos de la misma semana dan dos
 * cuotas 1 con el mismo vencimiento, y se leen «C1 · vencida · 3 d ×2».
 */
function pastillasDeCuotas(
  cuotas: DeudorDeLaSemana['cuotas'],
): Array<{ texto: string; tono: 'warning' | 'error' | 'neutral' }> {
  const cuenta = new Map<string, { texto: string; tono: 'warning' | 'error' | 'neutral'; n: number }>()
  for (const q of cuotas) {
    const cola = q.estado === 'vencida' ? ` · ${q.diasAtraso} d` : q.estado === 'por_vencer' ? ` · ${formatDay(q.vence)}` : ''
    const texto = `C${q.numero} · ${ROTULO_ESTADO_QUE_SE_DEBE[q.estado].toLowerCase()}${cola}`
    const previa = cuenta.get(texto)
    if (previa) previa.n += 1
    else cuenta.set(texto, { texto, tono: q.estado === 'vencida' ? 'warning' : q.estado === 'perdida' ? 'error' : 'neutral', n: 1 })
  }
  return [...cuenta.values()].map((p) => ({ texto: p.n > 1 ? `${p.texto} ×${p.n}` : p.texto, tono: p.tono }))
}

/** La tabla de quién debe de la semana, con su filtro de cuota. */
function QuienDebe({
  semana,
  local,
  cuota,
  onCuota,
}: {
  semana: string
  local: string | null
  cuota: FiltroDeCuota
  onCuota: (c: FiltroDeCuota) => void
}) {
  const navigate = useNavigate()
  const deudores = useQuery(consultaDeudoresDeLaSemana(semana, local))
  const tasa = useQuery(consultaTasa())
  const d = deudores.data
  const filas = useMemo(() => (d ? deLaCuota(d.filas, cuota) : []), [d, cuota])
  function apuntarCola(enPantalla: DeudorDeLaSemana[]) {
    abrirCasoEnCola({ lista: 'cobranza', tramo: 'todos' }, enPantalla.map((f) => f.userId))
  }

  const columnas = useMemo((): Array<Column<DeudorDeLaSemana>> => {
    if (!d) return []
    const ahora = new Date()
    const ctx = {
      hoy: d.hoy,
      cortes: null,
      tasa: tasa.data?.rate ?? null,
      ahora,
      diasBaja: d.demotionDays,
      alAbrirCaso: apuntarCola as (enPantalla: unknown[]) => void,
    }
    const base = columnasCartera(ctx)
    const de = (clave: string) => base.find((c) => c.key === clave) as Column<DeudorDeLaSemana> | undefined
    return [
      de('persona'),
      de('telefono'),
      {
        key: 'semana',
        header: 'De esta semana (financiamiento + fee)',
        type: 'number',
        sortDir: 'desc',
        info: 'Lo que debe de lo financiado esta semana, cuota a cuota: vencida, por vencer o dada por perdida. Financiamiento + service fee, con sus dos partes debajo.',
        sort: (r: DeudorDeLaSemana) => r.deLaSemana.payableUsd,
        csv: (r: DeudorDeLaSemana) => csvDinero(r.deLaSemana.payableUsd),
        cell: (r: DeudorDeLaSemana) => (
          <>
            <span className="font-semibold">{formatUsd(r.deLaSemana.payableUsd)}</span>
            <span className="mt-0.5 block whitespace-nowrap type-panel-caption text-on-surface-variant">
              {desgloseCorto(r.deLaSemana)}
            </span>
            <span className="mt-1 flex flex-wrap gap-1">
              {pastillasDeCuotas(r.cuotas).map((p) => (
                <Badge key={p.texto} tone={p.tono}>
                  {p.texto}
                </Badge>
              ))}
            </span>
          </>
        ),
      },
      {
        key: 'total',
        header: 'Debe en total (financiamiento + fee)',
        type: 'number',
        sortDir: 'desc',
        info: `Todo lo que debe, de esta y de otras semanas: lo vencido y lo que vence en los próximos ${d.horizonteDias} días. Financiamiento + service fee.`,
        sort: (r: DeudorDeLaSemana) => r.overdueUsd + r.upcomingUsd,
        csv: (r: DeudorDeLaSemana) => csvDinero(r.overdueUsd + r.upcomingUsd),
        cell: (r: DeudorDeLaSemana) => (
          <>
            <span>{formatUsd(r.overdueUsd + r.upcomingUsd)}</span>
            {r.overdueUsd > 0 && (
              <span className="mt-0.5 block whitespace-nowrap type-panel-caption text-on-surface-variant">
                {formatUsd(r.overdueUsd)} vencido
              </span>
            )}
          </>
        ),
      },
      columnaDeSenales<DeudorDeLaSemana>(ctx),
      de('contacto'),
      de('acciones'),
    ].filter((c): c is Column<DeudorDeLaSemana> => c !== undefined)
    // Las señales se leen contra la hora de cuando llegaron los datos, que se
    // refrescan cada minuto.
  }, [d, tasa.data])

  const sumas = sumasPorEstado(filas)

  return (
    <section aria-labelledby="quien-debe" className="flex flex-col gap-2">
      <div className="flex flex-wrap items-end gap-x-4 gap-y-2">
        <h3 id="quien-debe" className="type-panel-section text-on-surface">
          Quién debe de esta semana
        </h3>
        <div className="ml-auto">
          <Filtro label="Cuota">
            <Segmented
              options={[
                { value: 'todas', label: 'Las dos' },
                { value: '1', label: 'Cuota 1' },
                { value: '2', label: 'Cuota 2' },
              ]}
              value={cuota}
              onChange={onCuota}
            />
          </Filtro>
        </div>
      </div>

      {deudores.isError ? (
        <ErrorConReintento
          title="No se pudo leer quién debe de esta semana"
          error={deudores.error}
          onReintentar={() => void deudores.refetch()}
        />
      ) : !d ? (
        <SkeletonTable rows={6} columns={6} />
      ) : filas.length === 0 ? (
        <EmptyState
          icon={<PartyPopper size={40} aria-hidden />}
          title="Nadie debe nada de esta semana"
          description={cuota === 'todas' ? 'Todo lo financiado esa semana está cobrado.' : `Todas las cuotas ${cuota} están cobradas.`}
        />
      ) : (
        <DataTable
          rows={filas}
          rowKey={(f) => f.userId}
          columns={columnas}
          noun={['paciente', 'pacientes']}
          summary={
            <span>
              {(
                [
                  ['vencida', 'vencido'],
                  ['por_vencer', 'por vencer'],
                  ['perdida', 'perdido'],
                ] as const
              )
                .filter(([e]) => sumas[e].importe.payableUsd > 0)
                .map(([e, rotulo]) => `${formatUsd(sumas[e].importe.payableUsd)} ${rotulo} de ${sumas[e].personas}`)
                .join(' · ')}{' '}
              (financiamiento + fee)
            </span>
          }
          exportar={{ archivo: `por-cobrar-semana-${semana}${cuota === 'todas' ? '' : `-cuota-${cuota}`}` }}
          onRowClick={(f, enPantalla) => {
            apuntarCola(enPantalla)
            void navigate({ to: '/admin/pacientes/$id', params: { id: f.userId }, search: { tab: 'cobranza' } })
          }}
        />
      )}
    </section>
  )
}
