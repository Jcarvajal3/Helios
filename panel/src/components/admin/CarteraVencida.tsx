import { useMemo, useState } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { ChevronRight, PartyPopper, Play, X } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import { columnasCartera } from '@/components/admin/ColumnasCartera'
import { BarraDeLaCartera } from '@/components/admin/cartera/BarraDeLaCartera'
import { abrirCasoEnCola } from '@/components/admin/ficha-persona/CobranzaCola'
import {
  Button,
  Callout,
  EmptyState,
  FilterBar,
  Filtro,
  InfoDot,
  Input,
  Segmented,
  Select,
  SkeletonBlock,
  SkeletonTable,
  diaOperativo,
  formatUsd,
} from '@/components/ui'
import {
  HORIZONTE_TODO,
  desgloseCorto,
  pasaElFiltro,
  pasaElPerfil,
  recuentoPorFiltro,
  rotuloDeFiltro,
  sumasDeCartera,
  totalPorCobrar,
} from '@/features/admin/cobranza/cartera'
import type { CollectionRow, FiltroCartera } from '@/features/admin/cobranza/cartera'
import {
  GRUPOS_DE_COLA,
  ORDENES_DE_COLA,
  QUE_ES_EL_GRUPO,
  ROTULO_GRUPO,
  ROTULO_ORDEN,
  grupoDe,
  ordenarPorAtraso,
} from '@/features/admin/cobranza/senales'
import type { GrupoDeCola, OrdenDeCola } from '@/features/admin/cobranza/senales'
import { ROTULO_PERFIL } from '@/features/admin/metricas/cobranza/perfiles'
import type { PerfilDeudor } from '@/features/admin/metricas/cobranza/perfiles'
import { consultaCartera, consultaPlantillas, consultaTasa } from '@/features/admin/cobranza/consultas'
import { cortesDeTramo } from '@/features/admin/tramos'
import { useParametros } from '@/features/admin/useParametros'
import { describeError } from '@/lib/supabase'

/** El punto de color de cada grupo: el rojo para lo que corre más prisa. */
const PUNTO: Record<GrupoDeCola, string> = {
  primero: 'bg-error',
  despues: 'bg-warning',
  recordar: 'bg-area',
  vigilar: 'bg-panel-muted',
}

/** Los que empiezan plegados: lo que no corre prisa. */
const PLEGADO_AL_EMPEZAR: ReadonlySet<GrupoDeCola> = new Set(['vigilar'])

const TODOS_LOS_LOCALES = 'todos'

/**
 * Por cobrar › Lista: la cola de cobro, a quién escribir hoy y en qué orden.
 *
 * Arriba, la barra de la cartera: cuánto hay por cobrar y cuánto lleva
 * cuánto tiempo vencido. Debajo, la cola, de dos formas (`orden`): por días
 * de atraso, una sola tabla de quien más lleva a quien menos (la de por
 * defecto), o por prioridad, en cuatro grupos (Llamar primero · Después ·
 * Recordar · Vigilar, `senales.ts`), cada uno en su tabla. En cada persona,
 * sus señales: lo que hizo antes de que le escribas.
 *
 * No hay filtros de plazo, tramo ni perfil: los grupos los sustituyen. Los
 * enlaces que llegan con uno (`?tramo=` desde Inicio o el catálogo, `?perfil=`
 * desde Métricas) siguen acotando la lista, y se ven como una etiqueta que se
 * quita.
 *
 * El estado automático aplica las consecuencias solo (congela, pone el cargo,
 * baja de nivel, expulsa). Esta lista existe para que alguien hable con la
 * persona antes de que eso pase. Cada fila abre su caso en modo cola.
 */
export function CarteraVencida({
  filtro,
  onFiltro,
  perfil,
  onPerfil,
  orden,
  onOrden,
}: {
  filtro: FiltroCartera
  onFiltro: (f: FiltroCartera) => void
  perfil?: PerfilDeudor
  onPerfil: (p: PerfilDeudor | undefined) => void
  orden: OrdenDeCola
  onOrden: (o: OrdenDeCola) => void
}) {
  const navigate = useNavigate()
  // La cola entera: el total de arriba es el «Por cobrar» de Métricas › Global.
  const cartera = useQuery(consultaCartera(undefined, HORIZONTE_TODO))
  const parametros = useParametros()
  const plantillas = useQuery(consultaPlantillas())
  const tasa = useQuery(consultaTasa())
  const [buscar, setBuscar] = useState('')
  const [local, setLocal] = useState(TODOS_LOS_LOCALES)
  const [plegados, setPlegados] = useState<ReadonlySet<GrupoDeCola>>(PLEGADO_AL_EMPEZAR)

  const cortes = cortesDeTramo(parametros.data)
  // Se recalcula en cada pintura: la cartera se refresca cada minuto y así
  // «Vence mañana» cambia solo a las 10:00.
  const ahora = new Date()
  const hoy = diaOperativo(ahora)

  const todas = cartera.data?.rows
  // El local acota a quien debe algo de ese local, con todo lo que debe: la
  // cola es por persona, como `admin_collections` con `p_merchant_id`.
  const delLocal = useMemo(
    () => (todas ?? []).filter((f) => local === TODOS_LOS_LOCALES || f.merchants.includes(local)),
    [todas, local],
  )
  const locales = useMemo(
    () => [...new Set((todas ?? []).flatMap((f) => f.merchants))].sort((a, b) => a.localeCompare(b, 'es')),
    [todas],
  )
  const filas = useMemo(() => {
    const q = buscar.trim().toLowerCase()
    const digitos = q.replace(/\D/g, '')
    return delLocal.filter(
      (f) =>
        pasaElFiltro(f, filtro, { hoy, cortes }) &&
        pasaElPerfil(f, perfil) &&
        (q === '' ||
          (f.fullName ?? '').toLowerCase().includes(q) ||
          (digitos.length >= 3 && (f.phone ?? '').includes(digitos))),
    )
  }, [delLocal, filtro, hoy, cortes, perfil, buscar])

  const grupos = useMemo(() => {
    const por: Record<GrupoDeCola, CollectionRow[]> = { primero: [], despues: [], recordar: [], vigilar: [] }
    for (const f of filas) por[grupoDe(f, hoy)].push(f)
    // Dentro de cada grupo, el orden de la base (la prioridad del perfil) y,
    // a igualdad, el más atrasado y el que más debe.
    for (const g of GRUPOS_DE_COLA) {
      por[g].sort(
        (a, b) =>
          (a.orden ?? Number.MAX_SAFE_INTEGER) - (b.orden ?? Number.MAX_SAFE_INTEGER) ||
          b.daysOverdue - a.daysOverdue ||
          b.overdueUsd + b.upcomingUsd - (a.overdueUsd + a.upcomingUsd),
      )
    }
    return por
  }, [filas, hoy])

  const porAtraso = useMemo(() => ordenarPorAtraso(filas), [filas])

  const recuento = recuentoPorFiltro(todas ?? [], { hoy, cortes })
  const diasBaja = cartera.data?.demotionDays ?? 0

  /**
   * La cola sigue el orden en que se ven las filas. Por atraso, el de la
   * tabla; por prioridad, los grupos de arriba abajo y, en el grupo de la
   * fila pulsada, el orden de su tabla.
   */
  function colaDesde(grupo: GrupoDeCola | null, enPantalla: CollectionRow[] | null): string[] {
    if (orden === 'atraso') return (enPantalla ?? porAtraso).map((f) => f.userId)
    return GRUPOS_DE_COLA.flatMap((g) => (g === grupo && enPantalla ? enPantalla : grupos[g])).map((f) => f.userId)
  }

  function abrirCaso(fila: CollectionRow | undefined, grupo: GrupoDeCola | null, enPantalla: CollectionRow[] | null) {
    if (!fila) return
    abrirCasoEnCola({ lista: 'cobranza', tramo: filtro }, colaDesde(grupo, enPantalla))
    void navigate({ to: '/admin/pacientes/$id', params: { id: fila.userId }, search: { tab: 'cobranza' } })
  }

  function columnasDe(grupo: GrupoDeCola | null) {
    return columnasCartera({
      hoy,
      cortes,
      tasa: tasa.data?.rate ?? null,
      ahora,
      diasBaja,
      horizonteDias: HORIZONTE_TODO,
      alAbrirCaso: (enPantalla) =>
        abrirCasoEnCola({ lista: 'cobranza', tramo: filtro }, colaDesde(grupo, enPantalla)),
    })
  }

  if (cartera.isPending) {
    return (
      <div className="flex flex-col gap-4">
        <SkeletonBlock className="h-24 w-full rounded-panel-card" />
        <SkeletonTable rows={8} columns={6} />
      </div>
    )
  }

  if (cartera.isError) {
    return (
      <Callout
        tone="error"
        titulo="No se pudo leer la cartera"
        accion={
          <Button size="sm" variant="tonal" onClick={() => void cartera.refetch()}>
            Reintentar
          </Button>
        }
      >
        {describeError(cartera.error)}
      </Callout>
    )
  }

  // El primero de la cola: el de arriba de la tabla, o del primer grupo con gente.
  const cola = orden === 'atraso' ? porAtraso : GRUPOS_DE_COLA.flatMap((g) => grupos[g])
  const acotada = filtro !== 'todos' || perfil !== undefined || buscar.trim() !== '' || local !== TODOS_LOS_LOCALES

  return (
    <>
      {cortes ? (
        <BarraDeLaCartera filas={delLocal} cortes={cortes} />
      ) : parametros.isError ? null : (
        <SkeletonBlock className="mb-5 h-24 w-full rounded-panel-card" />
      )}

      <FilterBar>
        <Input
          id="cartera-buscar"
          label="Buscar"
          placeholder="Nombre o teléfono"
          value={buscar}
          onChange={setBuscar}
          className="w-72"
        />
        <Filtro label="Ordenar">
          <Segmented
            options={ORDENES_DE_COLA.map((o) => ({ value: o, label: ROTULO_ORDEN[o] }))}
            value={orden}
            onChange={onOrden}
          />
        </Filtro>
        {locales.length > 1 && (
          <Select
            id="cartera-local"
            label="Clínica"
            value={local}
            options={[
              { value: TODOS_LOS_LOCALES, label: 'Todas las clínicas' },
              ...locales.map((l) => ({ value: l, label: l })),
            ]}
            onChange={setLocal}
            className="w-56"
          />
        )}
        {filtro !== 'todos' && (
          <Filtro label="Solo">
            <EtiquetaQuitable
              texto={`${rotuloDeFiltro(filtro, cortes)} · ${recuento[filtro]}`}
              onQuitar={() => onFiltro('todos')}
            />
          </Filtro>
        )}
        {perfil && (
          <Filtro label="Perfil">
            <EtiquetaQuitable texto={ROTULO_PERFIL[perfil]} onQuitar={() => onPerfil(undefined)} />
          </Filtro>
        )}
        <div className="ml-auto">
          <Button
            size="sm"
            disabled={cola.length === 0}
            title={cola.length === 0 ? 'No hay nadie en esta lista.' : undefined}
            onClick={() => abrirCaso(cola[0], null, null)}
          >
            <Play size={14} aria-hidden /> Empezar por el primero
          </Button>
        </div>
      </FilterBar>

      {plantillas.isError && (
        <Callout
          tone="warning"
          titulo="No se pudieron leer las plantillas de WhatsApp"
          accion={
            <Button size="sm" variant="tonal" onClick={() => void plantillas.refetch()}>
              Reintentar
            </Button>
          }
          className="mb-4"
        >
          El botón de WhatsApp queda apagado hasta que carguen.
        </Callout>
      )}

      {filas.length === 0 ? (
        <EmptyState
          icon={<PartyPopper size={40} />}
          title={acotada ? 'Nadie en esta lista' : 'Nadie por cobrar'}
          description={
            acotada
              ? 'Quita la búsqueda, la clínica o la etiqueta para ver a los demás.'
              : 'Ningún paciente tiene cuotas vencidas ni por vencer.'
          }
        />
      ) : orden === 'atraso' ? (
        <DataTable
          rows={porAtraso}
          rowKey={(f) => f.userId}
          columns={columnasDe(null)}
          noun={['paciente', 'pacientes']}
          summary={<ResumenDeCola filas={porAtraso} />}
          exportar={{ archivo: 'por-cobrar-por-atraso' }}
          onRowClick={(f, enPantalla) => abrirCaso(f, null, enPantalla)}
        />
      ) : (
        <div className="flex flex-col gap-6">
          {GRUPOS_DE_COLA.filter((g) => grupos[g].length > 0).map((g) => {
            const del = grupos[g]
            const plegado = plegados.has(g)
            const sumas = sumasDeCartera(del)
            const vencido = g === 'primero' || g === 'despues'
            const importe = vencido ? sumas.vencidoUsd : sumas.porVencerUsd
            const partes = vencido ? sumas.vencidoDesglose : sumas.porVencerDesglose
            return (
              <section key={g} aria-labelledby={`grupo-${g}`} className="flex flex-col gap-2">
                <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
                  <button
                    type="button"
                    aria-expanded={!plegado}
                    onClick={() =>
                      setPlegados((p) => {
                        const n = new Set(p)
                        if (n.has(g)) n.delete(g)
                        else n.add(g)
                        return n
                      })
                    }
                    className="inline-flex items-center gap-2 rounded-panel-control text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary"
                  >
                    <ChevronRight
                      size={16}
                      aria-hidden
                      className={`text-panel-muted transition-transform duration-[var(--transition-fast)] ${plegado ? '' : 'rotate-90'}`}
                    />
                    <span aria-hidden className={`size-2 rounded-full ${PUNTO[g]}`} />
                    <h3 id={`grupo-${g}`} className="type-panel-section text-on-surface">
                      {ROTULO_GRUPO[g]}
                    </h3>
                  </button>
                  <span className="inline-flex opacity-60 hover:opacity-100">
                    <InfoDot title={ROTULO_GRUPO[g]} what={QUE_ES_EL_GRUPO[g]} />
                  </span>
                  {/* Abierto, las cifras las dice la tabla; plegado, aquí. */}
                  {plegado && (
                    <span className="type-panel-caption tabular-nums text-panel-muted">
                      {del.length} {del.length === 1 ? 'paciente' : 'pacientes'} · {formatUsd(importe)}{' '}
                      {vencido ? 'vencido' : 'por vencer'}
                      {partes && importe > 0 ? ` (${desgloseCorto(partes)})` : ''}
                    </span>
                  )}
                </div>
                {!plegado && (
                  <DataTable
                    rows={del}
                    rowKey={(f) => f.userId}
                    columns={columnasDe(g)}
                    noun={['paciente', 'pacientes']}
                    summary={<ResumenDeCola filas={del} />}
                    exportar={{ archivo: `por-cobrar-${g}` }}
                    onRowClick={(f, enPantalla) => abrirCaso(f, g, enPantalla)}
                  />
                )}
              </section>
            )
          })}
        </div>
      )}
    </>
  )
}

/**
 * Lo vencido (sin lo perdido) y lo por vencer de unas filas, cada uno con su
 * desglose, y lo perdido aparte si lo hay: va junto al recuento de la tabla.
 * Suman lo mismo que la barra de arriba.
 */
function ResumenDeCola({ filas }: { filas: ReadonlyArray<CollectionRow> }) {
  const sumas = sumasDeCartera(filas)
  const t = totalPorCobrar(filas)
  const vencido = t.usd - sumas.porVencerUsd
  const vencidoPartes =
    t.partes && sumas.porVencerDesglose
      ? {
          financedUsd: t.partes.financedUsd - sumas.porVencerDesglose.financedUsd,
          feeUsd: t.partes.feeUsd - sumas.porVencerDesglose.feeUsd,
        }
      : null
  return (
    <span>
      {formatUsd(vencido)} vencido
      {vencidoPartes && vencido > 0 && ` (${desgloseCorto(vencidoPartes)})`} · {formatUsd(sumas.porVencerUsd)} por vencer
      {sumas.porVencerDesglose && sumas.porVencerUsd > 0 && ` (${desgloseCorto(sumas.porVencerDesglose)})`}
      {t.perdido.usd > 0 && ` · ${formatUsd(t.perdido.usd)} dado por perdido`}
    </span>
  )
}

/**
 * Un recorte que llegó por la URL y que se quita con un clic. Tiene la forma
 * de una píldora encendida, no la de un botón de acción: no hace nada más que
 * dejar de filtrar.
 */
function EtiquetaQuitable({ texto, onQuitar }: { texto: string; onQuitar: () => void }) {
  return (
    <button
      type="button"
      onClick={onQuitar}
      aria-label={`Quitar el filtro «${texto}»`}
      className="inline-flex h-panel-control-sm items-center gap-2 whitespace-nowrap rounded-panel-control bg-on-surface px-3.5 type-panel-control text-shell-canvas transition-opacity duration-[var(--transition-fast)] hover:opacity-85"
    >
      {texto}
      <X size={14} aria-hidden />
    </button>
  )
}
