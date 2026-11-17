import { useMemo, useState } from 'react'
import { Link, createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import type { UseQueryResult } from '@tanstack/react-query'
import { FileDown, Inbox, Plus, Store } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import { RevisarSolicitud, columnasSolicitudes } from '@/components/admin/directorio/Solicitudes'
import { BuscadorEnUrl } from '@/components/FiltrosDeLista'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import { columnasLocales } from '@/components/admin/directorio/columnasLocales'
import type { Deuda, PorPagar } from '@/components/admin/directorio/columnasLocales'
import {
  Button,
  EmptyState,
  ErrorBox,
  FilterBar,
  Filtro,
  NoSePudoLeer,
  Segmented,
  SkeletonTable,
  Stat,
  StatGrid,
  estadoDeConsulta,
  claseDeBoton,
  formatUsd,
} from '@/components/ui'
import { fetchMerchantPayables, fetchMerchants } from '@/features/admin/api'
import type { MerchantPayable, MerchantRow } from '@/features/admin/api'
import { consultaSolicitudes } from '@/features/admin/clinicas/api'
import type { SolicitudDeAfiliacion } from '@/features/admin/clinicas/clinicas'
import { useDatosDeContrato } from '@/features/admin/clinicas/useDatosDeContrato'
import { filtrarLocales, normalizarTexto } from '@/features/admin/directorio/locales'
import { SOLO_QUIEN_AFILIA, useEsCapacitador, usePuedeAfiliar } from '@/features/admin/role'
import { comoTexto, unoDe } from '@/lib/busqueda'
import { ESTADOS_LOCAL, VALORES_ESTADO_LOCAL } from '@/features/admin/estados'
import type { EstadoLocal } from '@/features/admin/estados'
import { ClinicasLite } from '@/lite/PersonasLite'
import { conLite } from '@/lite/espacio'

/** `pendiente`: las solicitudes de afiliación de la portada, que aún no son clínicas. */
type EstadoDeLista = EstadoLocal | 'pendiente'

type LocalesSearch = {
  q?: string
  estado?: EstadoDeLista
}

export const Route = createFileRoute('/admin/clinicas')({
  staticData: { title: 'Clínicas', width: 'wide' },
  // En Helios Lite, «Médicos y centros» de la maqueta (`lite/PersonasLite`).
  component: conLite(LocalesPage, ClinicasLite),
  validateSearch: (search: Record<string, unknown>): LocalesSearch => ({
    q: comoTexto(search.q),
    estado: unoDe([...VALORES_ESTADO_LOCAL, 'pendiente'] as const, search.estado),
  }),
})

/** Los estados de la lista; «Pendientes» lleva la cuenta de solicitudes. */
function filtrosEstado(pendientes: number): Array<{ value: EstadoDeLista | ''; label: string }> {
  return [
    { value: '', label: 'Todos' },
    {
      value: 'pendiente',
      label: pendientes > 0 ? `Pendientes (${pendientes})` : 'Pendientes',
    },
    ...VALORES_ESTADO_LOCAL.map((v) => ({
      value: v,
      label: ESTADOS_LOCAL[v].plural,
    })),
  ]
}

/**
 * Locales: la lista de los locales aliados. Cómo le va a cada uno (lo que
 * era la pestaña Rendimiento) es Métricas › Locales: lo que es análisis vive
 * en Métricas.
 */
function LocalesPage() {
  return <ListaDeLocales />
}

/**
 * La lista de todos los locales aliados.
 *
 * La lista es corta y viene entera, así que la búsqueda (nombre, razón social,
 * titular o RIF) y el estado filtran en el navegador; los dos viven en la URL. El
 * alta cierra la fila de filtros y abre una ventana.
 */
function ListaDeLocales() {
  const navigate = useNavigate({ from: '/admin/clinicas' })
  const search = Route.useSearch()
  // El capacitador afilia, pero no ve dinero: ni lo que se le debe a cada
  // clínica ni los datos de alta (con su cuenta de cobro).
  const puedeAfiliar = usePuedeAfiliar()
  const sinDinero = useEsCapacitador()
  const [revisando, setRevisando] = useState<SolicitudDeAfiliacion | null>(null)
  const datosDeAlta = useDatosDeContrato()

  const merchants = useQuery({
    queryKey: ['merchants'],
    queryFn: fetchMerchants,
  })
  const solicitudes = useQuery(consultaSolicitudes())
  const pendientes = solicitudes.data?.length ?? 0
  const viendoPendientes = search.estado === 'pendiente'

  // Lo que se le debe a cada local sale de la misma llamada que usa Pagos a
  // locales.
  const payables = useQuery({
    queryKey: ['merchant-payables'],
    queryFn: fetchMerchantPayables,
    enabled: !sinDinero,
  })

  const porPagar = useMemo<PorPagar>(() => {
    if (payables.isError) return { estado: 'error' }
    if (!payables.data) return { estado: 'cargando' }
    const porLocal = new Map<string, Deuda>()
    for (const p of payables.data) {
      porLocal.set(p.merchantId, {
        total: p.totalPendingUsd,
        atrasado: p.overdueUsd,
      })
    }
    return { estado: 'listo', porLocal }
  }, [payables.data, payables.isError])

  const columnas = useMemo(
    () => columnasLocales(porPagar).filter((c) => !sinDinero || !COLUMNAS_CON_DINERO.has(c.key)),
    [porPagar, sinDinero],
  )

  const filas = filtrarLocales(merchants.data ?? [], {
    texto: search.q,
    estado: search.estado === 'pendiente' ? undefined : search.estado,
  })
  const filasSolicitudes = filtrarSolicitudes(solicitudes.data ?? [], search.q)

  /** Un filtro es un paso del historial; una búsqueda que se teclea, no. */
  function cambiar(patch: Partial<LocalesSearch>, replace = false) {
    void navigate({ search: (prev) => ({ ...prev, ...patch }), replace })
  }

  return (
    <>
      {/* El resumen de la maqueta aprobada (2026-11-12): cuatro cifras arriba.
          El capacitador no ve dinero: solo las activas y las solicitudes. */}
      <ResumenEnCifras
        merchants={merchants}
        payables={payables}
        pendientes={pendientes}
        solicitudes={solicitudes}
        sinDinero={sinDinero}
      />

      <FilterBar>
        <BuscadorEnUrl
          id="buscar-local"
          valor={search.q}
          placeholder="Médico, consultorio, razón social o RIF"
          onBuscar={(q) => cambiar({ q }, true)}
        />
        <Filtro label="Estado">
          <Segmented
            options={filtrosEstado(pendientes)}
            value={search.estado ?? ''}
            onChange={(value) => cambiar({ estado: value || undefined })}
          />
        </Filtro>

        {/* La acción de la pantalla cierra la fila de filtros. El motivo de
            un botón apagado va en el globo: escrito debajo, lo sacaría de la
            línea de los demás controles. */}
        <div className="ml-auto">
          {/* Una página y no una ventana: se llena sobre todo desde el móvil. */}
          {puedeAfiliar ? (
            <Link to="/admin/clinicas/alta" className={claseDeBoton('filled', 'sm')}>
              <Plus size={14} aria-hidden /> Dar de alta una clínica
            </Link>
          ) : (
            <Button size="sm" disabled title={SOLO_QUIEN_AFILIA}>
              <Plus size={14} aria-hidden /> Dar de alta una clínica
            </Button>
          )}
        </div>
      </FilterBar>

      {viendoPendientes ? (
        <ListaDeSolicitudes estado={solicitudes} filas={filasSolicitudes} onAbrir={setRevisando} />
      ) : (
        <>
          {merchants.isPending && <SkeletonTable rows={6} columns={6} />}

          {merchants.isError && (
            <SeccionSinLeer
              titulo="No se pudo leer la lista de clínicas"
              error={merchants.error}
              onReintentar={() => void merchants.refetch()}
            />
          )}

          {merchants.isSuccess && merchants.data.length === 0 && (
            <EmptyState
              icon={<Store size={48} />}
              title="Todavía no hay clínicas"
              description="Sin una clínica no se puede generar ningún cobro. Da de alta el primero con «Dar de alta una clínica»."
            />
          )}

          {merchants.isSuccess && merchants.data.length > 0 && filas.length === 0 && (
            <EmptyState
              icon={<Store size={40} />}
              title="Ninguna clínica coincide"
              description="Prueba con otra parte del nombre o con el RIF sin guiones, o quita el filtro de estado."
            />
          )}

          {datosDeAlta.error && (
            <ErrorBox title="No se pudieron bajar los datos de alta" detail={datosDeAlta.error} />
          )}

          {filas.length > 0 && (
            <DataTable
              rows={filas}
              rowKey={(m) => m.id}
              columns={columnas}
              noun={['clínica', 'clínicas']}
              summary={
                sinDinero ? undefined : (
                <ResumenLocales
                  filas={filas}
                  payables={payables.data}
                  error={payables.isError}
                  onReintentar={() => void payables.refetch()}
                />
                )
              }
              exportar={{ archivo: 'locales' }}
              acciones={
                sinDinero ? undefined : (
                <Button
                  size="sm"
                  variant="text"
                  disabled={datosDeAlta.pendiente}
                  title="Los datos de alta de las clínicas que se ven, con su médico titular y su cuenta de pago, para redactar el contrato"
                  onClick={() => datosDeAlta.descargar({ de: 'lista', ids: filas.map((m) => m.id) })}
                >
                  <FileDown size={15} aria-hidden />
                  {datosDeAlta.pendiente ? 'Leyendo…' : 'Datos de alta'}
                </Button>
                )
              }
              onRowClick={(m) =>
                void navigate({
                  to: '/admin/clinicas/$id',
                  params: { id: m.id },
                })
              }
            />
          )}
        </>
      )}

      {revisando && <RevisarSolicitud solicitud={revisando} onClose={() => setRevisando(null)} />}
    </>
  )
}

/**
 * Las columnas que el capacitador no ve: lo financiado, lo que se le debe y
 * el personal (la base no le enseña el personal de cada clínica).
 */
const COLUMNAS_CON_DINERO = new Set(['ventas', 'consumos-30', 'por-pagar', 'personal'])

/** La búsqueda de la lista también filtra las solicitudes: consultorio, médico o cédula. */
function filtrarSolicitudes(lista: Array<SolicitudDeAfiliacion>, q: string | undefined) {
  const aguja = normalizarTexto(q ?? '')
  if (!aguja) return lista
  return lista.filter((s) =>
    [s.alta.clinicName, s.alta.ownerName, s.alta.ownerDocument, s.alta.taxId].some((v) =>
      normalizarTexto(v).includes(aguja),
    ),
  )
}

/** Las solicitudes de la portada que esperan a que un super admin las revise. */
function ListaDeSolicitudes({
  estado,
  filas,
  onAbrir,
}: {
  estado: UseQueryResult<Array<SolicitudDeAfiliacion>>
  filas: Array<SolicitudDeAfiliacion>
  onAbrir: (s: SolicitudDeAfiliacion) => void
}) {
  if (estado.isPending) return <SkeletonTable rows={4} columns={5} />
  if (estado.isError) {
    return (
      <SeccionSinLeer
        titulo="No se pudieron leer las solicitudes"
        error={estado.error}
        onReintentar={() => void estado.refetch()}
      />
    )
  }
  if (estado.data.length === 0) {
    return (
      <EmptyState
        icon={<Inbox size={48} />}
        title="No hay solicitudes pendientes"
        description="Las que manden los médicos desde «Quiero afiliarme» en la portada aparecen aquí para aprobarlas."
      />
    )
  }
  if (filas.length === 0) {
    return (
      <EmptyState
        icon={<Inbox size={40} />}
        title="Ninguna solicitud coincide"
        description="Prueba con otra parte del nombre del consultorio, del médico o con la cédula."
      />
    )
  }
  return (
    <DataTable
      rows={filas}
      rowKey={(s) => s.id}
      columns={columnasSolicitudes}
      noun={['solicitud', 'solicitudes']}
      exportar={{ archivo: 'solicitudes-de-afiliacion' }}
      onRowClick={onAbrir}
    />
  )
}

/**
 * Cuántos de los que se ven están activos y cuánto se les debe. Lo que se les
 * debe enlaza a Pagos a locales. Los locales de prueba se ven, pero no suman.
 */
function ResumenLocales({
  filas,
  payables,
  error,
  onReintentar,
}: {
  filas: Array<MerchantRow>
  payables: Array<MerchantPayable> | undefined
  error: boolean
  onReintentar: () => void
}) {
  const reales = filas.filter((m) => !m.isTest)
  const activos = reales.filter((m) => m.status === 'active').length
  const ids = new Set(reales.map((m) => m.id))
  const debido = (payables ?? []).filter((p) => ids.has(p.merchantId)).reduce((s, p) => s + p.totalPendingUsd, 0)

  return (
    <>
      {activos} {activos === 1 ? 'activo' : 'activos'} ·{' '}
      {error ? (
        <>
          por pagar: <NoSePudoLeer onReintentar={onReintentar} />
        </>
      ) : payables ? (
        <Link
          to="/admin/pagos-clinicas"
          className="text-on-surface underline decoration-panel-muted underline-offset-2 hover:decoration-on-surface"
        >
          {formatUsd(debido)} por pagar a clínicas
        </Link>
      ) : (
        'leyendo lo que se les debe…'
      )}
    </>
  )
}

/**
 * Las cuatro cifras de arriba: cuántas clínicas están activas, lo financiado
 * en 30 días, lo que se les debe y las solicitudes por aprobar. Salen de las
 * mismas consultas que la lista; las de prueba no suman.
 */
function ResumenEnCifras({
  merchants,
  payables,
  pendientes,
  solicitudes,
  sinDinero,
}: {
  merchants: UseQueryResult<Array<MerchantRow>>
  payables: UseQueryResult<Array<MerchantPayable>>
  pendientes: number
  solicitudes: UseQueryResult<Array<SolicitudDeAfiliacion>>
  sinDinero: boolean
}) {
  const reales = (merchants.data ?? []).filter((m) => !m.isTest)
  const activas = reales.filter((m) => m.status === 'active').length
  const financiado = reales.reduce((s, m) => s + m.financed30d, 0)
  const ids = new Set(reales.map((m) => m.id))
  const deuda = (payables.data ?? []).filter((p) => ids.has(p.merchantId))
  const porPagar = deuda.reduce((s, p) => s + p.totalPendingUsd, 0)
  const atrasado = deuda.reduce((s, p) => s + p.overdueUsd, 0)

  return (
    <StatGrid cols={sinDinero ? 2 : 4} className="mb-shell-gap-block">
      <Stat
        label="Clínicas activas"
        value={String(activas)}
        hint={`de ${reales.length} ${reales.length === 1 ? 'clínica' : 'clínicas'}`}
        estado={estadoDeConsulta(merchants)}
        onReintentar={() => void merchants.refetch()}
      />
      {!sinDinero && (
        <Stat
          label="Financiado sin comisión · 30 días"
          value={formatUsd(financiado)}
          estado={estadoDeConsulta(merchants)}
          onReintentar={() => void merchants.refetch()}
        />
      )}
      {!sinDinero && (
        <Stat
          label="Por pagar a clínicas"
          value={formatUsd(porPagar)}
          senal={atrasado > 0 ? { tone: 'warning', texto: `${formatUsd(atrasado)} con atraso` } : undefined}
          link={{ to: '/admin/pagos-clinicas' }}
          estado={estadoDeConsulta(payables)}
          onReintentar={() => void payables.refetch()}
        />
      )}
      <Stat
        label="Solicitudes por aprobar"
        value={String(pendientes)}
        senal={pendientes > 0 ? { tone: 'warning', texto: 'Revisar ahora' } : undefined}
        link={{ to: '/admin/clinicas', search: { estado: 'pendiente' } }}
        estado={estadoDeConsulta(solicitudes)}
        onReintentar={() => void solicitudes.refetch()}
      />
    </StatGrid>
  )
}
