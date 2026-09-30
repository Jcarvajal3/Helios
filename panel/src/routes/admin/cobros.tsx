import type { ReactNode } from 'react'
import { Link, createFileRoute, redirect, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { Inbox, Upload } from 'lucide-react'

import { EstadoBadge } from '@/components/admin/EstadoBadge'
import { COLA_PAGOS_REPORTADOS } from '@/components/admin/FichaCobro'
import { ImportarBanco } from '@/components/admin/ImportarBanco'
import { BotonRegistrarPago } from '@/components/admin/pagos/RegistrarPago'
import { abrirEnCola } from '@/components/admin/ModoCola'
import { AvisoExtracto } from '@/components/admin/caja/AvisoExtracto'
import { PestanaAbonos, VALORES_ESTADO_ABONOS } from '@/components/admin/caja/PestanaAbonos'
import type { EstadoAbonos } from '@/components/admin/caja/PestanaAbonos'
import { consultaAbonosSinDueno, consultaPagosPorAprobar } from '@/components/admin/inicio/consultas'
import { BuscadorEnUrl, FiltroFechas } from '@/components/FiltrosDeLista'
import { DataTable, ENLACE_EN_CELDA } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import {
  Badge,
  Button,
  EmptyState,
  ErrorBox,
  FilterBar,
  Filtro,
  Modal,
  Segmented,
  Select,
  SkeletonTable,
  Tabs,
  formatDateTime,
  formatDocument,
  formatUsd,
  formatPhone,
  formatVes,
  diaOperativo,
  formatWaiting,
  hoyCaracas,
} from '@/components/ui'
import { fetchPaymentQueue } from '@/features/admin/api'
import type { QueueItem } from '@/features/admin/api'
import { BANKS } from '@/features/admin/banks'
import {
  ESTADOS_DE_LA_COLA,
  ESTADOS_POR_COLA,
  bancosParaElFiltro,
  colaDe,
  enElExtracto,
  filtrarPagos,
  leerFiltrosPagos,
} from '@/features/admin/colaDePagos'
import type { EstadoCola, FiltrosPagos } from '@/features/admin/colaDePagos'
import { estadoDePagoReportado } from '@/features/admin/estados'
import { lineaDeSumandos, sumandosDeLosPagos } from '@/features/admin/sumandosDelPago'
import { comoBooleano, comoId, unoDe } from '@/lib/busqueda'
import { csvDinero, csvInstante } from '@/lib/csv'
import { describeError } from '@/lib/supabase'

/**
 * Las dos pestañas: lo que dice la persona (pagos reportados) y lo que dice
 * el banco (abonos sin dueño). Sin `vista`, los reportados.
 */
type Vista = 'reportados' | 'abonos'

const VALORES_VISTA: readonly Vista[] = ['reportados', 'abonos']

/**
 * Pestañas que ya no existen y se aceptan solo para redirigir: `sin-dueno` es
 * ahora la pestaña de abonos e `importar` es el parámetro de abajo. Tienen que
 * pasar por `validateSearch`, porque `beforeLoad` recibe la búsqueda ya
 * validada: sin ellas aquí, la redirección nunca las ve.
 */
type TabVieja = 'sin-dueno' | 'importar'

const TABS_VALIDAS: ReadonlyArray<EstadoCola | TabVieja> = [
  'pendientes',
  'aprobados',
  'rechazados',
  'sin-dueno',
  'importar',
]

/**
 * El estado de la pantalla, entero en la URL. Cada pestaña tiene sus
 * parámetros y no se pisan, así que al volver a una sigue como se dejó:
 *
 *   reportados  `tab` (el estado de la cola, con los nombres de siempre, que
 *               enlazan desde Inicio), `q`, `banco`, `desde` y `hasta`.
 *   abonos      `abonos` (sin él, los pendientes) y `asignar`, el abono que
 *               se está asignando.
 *
 * `importar` abre la ventana de importar el extracto, en las dos.
 */
type CobrosSearch = Omit<FiltrosPagos, 'tab'> & {
  vista?: Vista
  tab?: EstadoCola | TabVieja
  abonos?: EstadoAbonos
  asignar?: string
  importar?: true
}

export const Route = createFileRoute('/admin/cobros')({
  staticData: { title: 'Pagos reportados', width: 'wide' },
  component: CobrosPage,
  beforeLoad: ({ search }) => {
    if (search.tab === 'sin-dueno') {
      throw redirect({ to: '/admin/cobros', search: { vista: 'abonos' } })
    }
    if (search.tab === 'importar') {
      throw redirect({ to: '/admin/cobros', search: { importar: true } })
    }
  },
  validateSearch: (search: Record<string, unknown>): CobrosSearch => ({
    ...leerFiltrosPagos(search),
    vista: unoDe(VALORES_VISTA, search.vista),
    tab: unoDe(TABS_VALIDAS, search.tab),
    abonos: unoDe(VALORES_ESTADO_ABONOS, search.abonos),
    asignar: comoId(search.asignar),
    importar: comoBooleano(search.importar),
  }),
})

/**
 * Pagos reportados: el dinero que entra, en dos pestañas.
 *
 * «Pagos reportados» son los pagos que la gente dice haber hecho: una lista
 * con tres estados, y cada pago abre su ficha. «Abonos sin dueño» es el dinero
 * que entró al banco y nadie reclamó. Las dos viven del extracto del banco, y
 * por eso el aviso de extracto viejo y el botón de importarlo están en las
 * dos: el botón cierra la fila de filtros de cada pestaña.
 */
function CobrosPage() {
  const navigate = useNavigate({ from: '/admin/cobros' })
  const search = Route.useSearch()
  const vista: Vista = search.vista ?? 'reportados'

  function cambiar(patch: Partial<CobrosSearch>, reemplazar = false) {
    void navigate({ search: (prev) => ({ ...prev, ...patch }), replace: reemplazar })
  }

  // Los recuentos de las pestañas: las mismas claves que las insignias del
  // menú y que las colas de Inicio, así que no cuestan otra llamada.
  const porAprobar = useQuery({ ...consultaPagosPorAprobar(), select: (d) => d.length })
  const sinDueno = useQuery({ ...consultaAbonosSinDueno(), select: (d) => d.length })

  const importar = (
    <Button size="sm" variant="tonal" onClick={() => cambiar({ importar: true })}>
      <Upload size={14} aria-hidden /> Importar el extracto
    </Button>
  )

  return (
    <>
      <Tabs
        options={[
          { value: 'reportados', label: 'Pagos reportados', insignia: porAprobar.data },
          { value: 'abonos', label: 'Abonos sin dueño', insignia: sinDueno.data },
        ]}
        value={vista}
        // El abono abierto no sobrevive al cambio de pestaña; los filtros de
        // cada una, sí.
        onChange={(v) => cambiar({ vista: v === 'abonos' ? 'abonos' : undefined, asignar: undefined })}
      />

      <AvisoExtracto onImportar={() => cambiar({ importar: true })} />

      {vista === 'reportados' ? (
        <PagosReportados
          search={search}
          cambiar={cambiar}
          accion={
            // El paciente paga y manda la captura por WhatsApp: el equipo lo
            // registra aquí y el pago cae en esta misma cola (plan §7.1).
            <div className="flex flex-wrap gap-2">
              <BotonRegistrarPago variante="filled" />
              {importar}
            </div>
          }
        />
      ) : (
        <PestanaAbonos
          estado={search.abonos ?? 'pendientes'}
          asignar={search.asignar}
          onEstado={(e) =>
            cambiar({ abonos: e === 'descartados' ? 'descartados' : undefined, asignar: undefined })
          }
          onAsignar={(asignar) => cambiar({ asignar }, asignar === undefined)}
          accion={importar}
        />
      )}

      {search.importar === true && (
        <Modal
          title="Importar el extracto del banco"
          width="lg"
          onClose={() => cambiar({ importar: undefined }, true)}
        >
          <ImportarBanco />
        </Modal>
      )}
    </>
  )
}

// ── La pestaña de pagos reportados ─────────────────────────────────────────

/**
 * Los pagos reportados: una sola lista con tres estados. Al abrir uno, la
 * lista apunta su orden (modo cola) para recorrer los demás desde la ficha sin
 * volver aquí.
 */
function PagosReportados({
  search,
  cambiar,
  accion,
}: {
  search: CobrosSearch
  cambiar: (patch: Partial<CobrosSearch>, reemplazar?: boolean) => void
  /** La acción de la pantalla: cierra la fila de filtros. */
  accion: ReactNode
}) {
  const navigate = useNavigate({ from: '/admin/cobros' })
  const cola = colaDe(search.tab)
  const filtros: FiltrosPagos = {
    tab: cola === 'pendientes' ? undefined : cola,
    q: search.q,
    banco: search.banco,
    desde: search.desde,
    hasta: search.hasta,
  }

  // Las fechas solo acotan los resueltos, y las acota la base: sin bajarse el
  // historial entero para filtrarlo aquí. Los pendientes comparten clave con
  // Inicio y con la insignia del menú.
  const resueltosEntre = cola === 'pendientes' ? {} : { desde: search.desde, hasta: search.hasta }
  const query = useQuery({
    queryKey:
      cola === 'pendientes'
        ? ['payment-queue', cola]
        : ['payment-queue', cola, search.desde ?? null, search.hasta ?? null],
    queryFn: () => fetchPaymentQueue(ESTADOS_POR_COLA[cola], resueltosEntre),
    // Los pagos los registra el equipo mientras se mira la pantalla. Con la
    // pestaña oculta no se pregunta; al volver, se repregunta en el acto.
    refetchInterval: cola === 'pendientes' ? 30_000 : false,
    refetchOnWindowFocus: true,
  })

  const bancos = bancosParaElFiltro(
    BANKS.map((b) => b.name),
    query.data ?? [],
  )

  return (
    <>
      <FilterBar>
        <Filtro label="Estado">
          <Segmented
            options={[...ESTADOS_DE_LA_COLA]}
            value={cola}
            onChange={(value) => cambiar({ tab: value === 'pendientes' ? undefined : value })}
          />
        </Filtro>
        <BuscadorEnUrl
          id="pagos-buscar"
          valor={search.q}
          onBuscar={(q) => cambiar({ q }, true)}
          placeholder="Paciente, cédula, teléfono o referencia"
          className="w-72"
        />
        <Select
          id="pagos-banco"
          label="Banco"
          value={search.banco ?? ''}
          options={[{ value: '', label: 'Todos los bancos' }, ...bancos.map((b) => ({ value: b, label: b }))]}
          onChange={(value) => cambiar({ banco: value || undefined })}
          className="w-56"
        />
        {cola !== 'pendientes' && (
          <FiltroFechas
            id="pagos-fechas"
            // El día operativo en que se aprobó o se rechazó, que es por lo
            // que filtra la base.
            label={cola === 'aprobados' ? 'Aprobado entre' : 'Rechazado entre'}
            desde={search.desde}
            hasta={search.hasta}
            max={diaOperativo()}
            onChange={(rango) => cambiar(rango)}
          />
        )}
        <div className="ml-auto">{accion}</div>
      </FilterBar>

      {query.isPending && <SkeletonTable rows={6} columns={5} />}

      {query.isError && (
        <ErrorBox title="No se pudo cargar la lista de pagos" detail={describeError(query.error)} />
      )}

      {query.data && (
        <Lista
          items={query.data}
          filtros={filtros}
          cola={cola}
          onQuitarFiltros={() =>
            cambiar({ q: undefined, banco: undefined, desde: undefined, hasta: undefined })
          }
          onAbrir={(visibles, pago) => {
            // Los ids en el orden en que se ven: es la cola que se recorre.
            abrirEnCola(
              COLA_PAGOS_REPORTADOS,
              visibles.map((p) => p.reportId),
            )
            void navigate({ to: '/admin/cobros/$id', params: { id: pago.reportId }, search: filtros })
          }}
        />
      )}
    </>
  )
}

// ── La lista ───────────────────────────────────────────────────────────────

function Lista({
  items,
  filtros,
  cola,
  onQuitarFiltros,
  onAbrir,
}: {
  items: QueueItem[]
  filtros: FiltrosPagos
  cola: EstadoCola
  onQuitarFiltros: () => void
  onAbrir: (visibles: QueueItem[], pago: QueueItem) => void
}) {
  const visibles = filtrarPagos(items, filtros, cola)

  if (visibles.length === 0) {
    // Las fechas ya las aplicó la base: `items` son los de esas fechas, y lo
    // que queda por quitar aquí es la búsqueda y el banco.
    const conFechas = cola !== 'pendientes' && (filtros.desde !== undefined || filtros.hasta !== undefined)
    if (items.length > 0 || conFechas) {
      return (
        <EmptyState
          icon={<Inbox size={48} />}
          title="Ningún pago con estos filtros"
          description={
            items.length > 0
              ? `Hay ${items.length} ${items.length === 1 ? 'pago' : 'pagos'} en esta lista sin la búsqueda ni el banco.`
              : 'Ningún pago se resolvió en esas fechas.'
          }
          action={
            <Button size="md" variant="tonal" onClick={onQuitarFiltros}>
              Quitar los filtros
            </Button>
          }
        />
      )
    }
    return (
      <EmptyState
        icon={<Inbox size={48} />}
        title={
          cola === 'pendientes'
            ? 'No hay pagos por aprobar'
            : cola === 'aprobados'
              ? 'Todavía no se ha aprobado ningún pago'
              : 'No se ha rechazado ningún pago'
        }
        description={
          cola === 'pendientes'
            ? 'Cuando el equipo registre un pago de un paciente, aparecerá aquí para aprobarlo.'
            : 'Los pagos resueltos se quedan en esta lista para poder consultarlos después.'
        }
      />
    )
  }

  const total = visibles.reduce((sum, p) => sum + p.amountUsd, 0)
  // Lo reportado lleva el service fee dentro: va con sus sumandos (regla del fee).
  const sumandos = lineaDeSumandos(sumandosDeLosPagos(visibles), formatUsd)

  return (
    <DataTable
      rows={visibles}
      rowKey={(p) => p.reportId}
      columns={COLUMNAS}
      noun={['pago', 'pagos']}
      summary={`${formatUsd(total)} reportados: ${sumandos ?? 'cuotas con fee y cargos por atraso'}`}
      exportar={{ archivo: `pagos-reportados-${cola}-${hoyCaracas()}` }}
      // Una referencia repetida no es prueba de fraude (con seis dígitos se
      // repiten solas), pero es lo único de esta lista que hay que ver antes
      // de leerla.
      rowTone={(p) => (p.referenceCollisions > 0 ? 'warning' : undefined)}
      // La cola sigue el orden que ve la persona, también si ordena por columna.
      onRowClick={(p, enPantalla) => onAbrir(enPantalla, p)}
    />
  )
}

// ── Las columnas ───────────────────────────────────────────────────────────

/**
 * Lo que hace falta para decidir si abrir un pago. El desglose, el cotejo fino
 * con el extracto y los botones viven en su ficha, que es donde se decide.
 */
const COLUMNAS: Array<Column<QueueItem>> = [
  {
    key: 'persona',
    header: 'Paciente',
    identity: true,
    sort: (p) => p.fullName,
    csv: (p) => p.fullName,
    cell: (p) => (
      <>
        <Link
          to="/admin/pacientes/$id"
          params={{ id: p.userId }}
          className={ENLACE_EN_CELDA}
        >
          {p.fullName ?? 'Sin nombre'}
        </Link>
        <p className="mt-0.5 type-panel-caption tabular-nums text-on-surface-variant">
          {formatPhone(p.phone)}
          {p.userDocument && ` · ${formatDocument(p.userDocument)}`}
        </p>
      </>
    ),
  },
  {
    key: 'telefono',
    header: 'Teléfono',
    hidden: true,
    csv: (p) => p.phone,
    cell: (p) => formatPhone(p.phone),
  },
  {
    key: 'cedula',
    header: 'Cédula',
    hidden: true,
    csv: (p) => p.userDocument,
    cell: (p) => formatDocument(p.userDocument),
  },
  {
    key: 'reportado',
    header: 'Reportado',
    sort: (p) => p.createdAt,
    sortDir: 'desc',
    csv: (p) => csvInstante(p.createdAt),
    cell: (p) => (
      <span className="block whitespace-nowrap">
        {formatDateTime(p.createdAt)}
        {(p.status === 'reported' || p.status === 'in_review') && (
          <span className="mt-0.5 block type-panel-caption text-on-surface-variant">
            esperando desde hace{' '}
            {formatWaiting(Math.floor((Date.now() - new Date(p.createdAt).getTime()) / 1000))}
          </span>
        )}
        {p.reviewedAt && p.status !== 'reported' && p.status !== 'in_review' && (
          <span className="mt-0.5 block type-panel-caption text-on-surface-variant">
            revisado el {formatDateTime(p.reviewedAt)}
            {p.reviewedByName ? ` por ${p.reviewedByName}` : ''}
          </span>
        )}
      </span>
    ),
  },
  {
    key: 'estado',
    header: 'Estado',
    sort: (p) => p.status,
    csv: (p) => estadoDePagoReportado(p.status).label,
    cell: (p) => <EstadoBadge tipo="pago" valor={p.status} />,
  },
  {
    key: 'referencia',
    header: 'Referencia',
    sort: (p) => p.reference,
    csv: (p) => p.reference,
    cell: (p) => (
      <span className="block">
        <span className="tabular-nums text-on-surface">{p.reference ?? '—'}</span>
        <span className="mt-0.5 block type-panel-caption text-on-surface-variant">
          {p.bank ?? 'Sin banco'}
          {p.referenceCollisions > 0 &&
            ` · ${p.referenceCollisions} ${p.referenceCollisions === 1 ? 'reporte más' : 'reportes más'} con esta referencia`}
        </span>
      </span>
    ),
  },
  {
    key: 'banco',
    header: 'Banco',
    hidden: true,
    sort: (p) => p.bank,
    csv: (p) => p.bank,
    cell: (p) => p.bank ?? '—',
  },
  {
    key: 'monto',
    header: 'Monto reportado (con fee)',
    info: 'Lo que el paciente dice haber transferido: las cuotas que salda (financiado + service fee + IVA) más los cargos por atraso, si hay. Debajo, en bolívares a la tasa BCV del dólar del día de su cotización.',
    type: 'number',
    sort: (p) => p.amountUsd,
    sortDir: 'desc',
    csv: (p) => csvDinero(p.amountUsd),
    cell: (p) => (
      <>
        <span className="font-semibold">{formatUsd(p.amountUsd)}</span>
        <span className="mt-0.5 block type-panel-caption font-normal text-on-surface-variant">
          {formatVes(p.amountVes)}
        </span>
      </>
    ),
  },
  {
    key: 'monto-ves',
    header: 'Monto reportado en bolívares',
    info: 'A la tasa BCV del dólar del día de la cotización.',
    type: 'number',
    hidden: true,
    csv: (p) => csvDinero(p.amountVes),
    cell: (p) => formatVes(p.amountVes),
  },
  {
    key: 'extracto',
    header: 'En el extracto',
    info: 'Si la referencia y el monto del reporte aparecen en el extracto importado. «No aparece» puede ser un pago que no existió o un extracto sin importar; la ficha distingue los dos casos. «Ya usado»: el movimiento ya respalda otro pago. Un pago aprobado con su movimiento ligado sale «Encontrado» aunque la referencia no case.',
    sort: (p) => (p.statementLine !== null ? 1 : p.statementMatchesAvailable),
    csv: (p) => enElExtracto(p),
    cell: (p) => {
      const texto = enElExtracto(p)
      const tono = texto === 'Encontrado' ? 'success' : texto === 'No aparece' ? 'neutral' : 'warning'
      return (
        <Badge tone={tono} icono={tono !== 'neutral'}>
          {texto}
        </Badge>
      )
    },
  },
  {
    key: 'cuotas',
    header: 'Qué salda',
    hidden: true,
    sort: (p) => p.installmentCount,
    csv: (p) => p.installmentCount,
    cell: (p) => (
      <span className="text-on-surface-variant">
        {p.installmentCount} {p.installmentCount === 1 ? 'cuota' : 'cuotas'}
        {p.lateFeeUsd > 0 && ` y ${formatUsd(p.lateFeeUsd)} en cargos por atraso`}
      </span>
    ),
  },
]
