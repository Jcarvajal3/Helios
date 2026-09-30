import { Link } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { ScrollText } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import { FiltroFechas } from '@/components/FiltrosDeLista'
import { Paginacion, rangoDePagina } from '@/components/Paginacion'
import type { Column } from '@/components/DataTable'
import {
  Button,
  Callout,
  EmptyState,
  ErrorBox,
  FilterBar,
  Seccion,
  Select,
  SkeletonTable,
  formatDateTime,
} from '@/components/ui'
import {
  FILTROS_BITACORA,
  accionesDelTema,
  describirEvento,
  rotuloDeDestino,
} from '@/features/admin/bitacora'
import type { DestinoBitacora, LineaBitacora } from '@/features/admin/bitacora'
import { fetchAuditLog, fetchTeam } from '@/features/admin/ops'
import type { AuditEntry } from '@/features/admin/ops'
import { useParametros } from '@/features/admin/useParametros'
import { csvInstante } from '@/lib/csv'
import { describeError } from '@/lib/supabase'

export const POR_PAGINA = 100

/** Los filtros de la bitácora, tal como viven en la URL. */
export type FiltrosBitacora = {
  tema?: string
  quien?: string
  desde?: string
  hasta?: string
  pagina?: number
}

type Fila = { entrada: AuditEntry; linea: LineaBitacora }

/** 'límite: €30,00 → €50,00', o solo el par si lo que cambió es el valor de la acción. */
function textoDelCambio(cambio: LineaBitacora['cambio']): string | null {
  if (!cambio) return null
  const par = `${cambio.antes} → ${cambio.despues}`
  return cambio.campo ? `${cambio.campo}: ${par}` : par
}

const ENLACE =
  'rounded-panel-control text-on-surface underline decoration-outline underline-offset-2 transition-colors hover:decoration-on-surface'

/** El enlace a lo que afectó una línea. Una ruta por caso: cada `Link` va tipado. */
function EnlaceDestino({ destino }: { destino: DestinoBitacora }) {
  const texto = rotuloDeDestino(destino)
  switch (destino.que) {
    case 'persona':
      return (
        <Link to="/admin/pacientes/$id" params={{ id: destino.id }} className={ENLACE}>
          {texto}
        </Link>
      )
    case 'local':
      return (
        <Link to="/admin/clinicas/$id" params={{ id: destino.id }} className={ENLACE}>
          {texto}
        </Link>
      )
    case 'consumo':
      return (
        <Link to="/admin/financiamientos/$id" params={{ id: destino.id }} className={ENLACE}>
          {texto}
        </Link>
      )
    case 'pago':
      return (
        <Link to="/admin/cobros/$id" params={{ id: destino.id }} className={ENLACE}>
          {texto}
        </Link>
      )
    case 'transferencia':
      return (
        <Link to="/admin/pagos-clinicas/pago/$id" params={{ id: destino.id }} className={ENLACE}>
          {texto}
        </Link>
      )
    case 'pagos-del-local':
      return (
        <Link to="/admin/pagos-clinicas/$id" params={{ id: destino.id }} className={ENLACE}>
          {texto}
        </Link>
      )
    case 'ajustes':
      return (
        <Link to="/admin/ajustes" search={{ tab: destino.tab }} className={ENLACE}>
          {texto}
        </Link>
      )
    case 'pantalla':
      return (
        <Link {...destino.destino} className={ENLACE}>
          {texto}
        </Link>
      )
  }
}

const COLUMNAS: Array<Column<Fila>> = [
  {
    key: 'cuando',
    header: 'Cuándo',
    cell: ({ entrada }) => (
      <span className="whitespace-nowrap text-on-surface-variant">
        {formatDateTime(entrada.createdAt)}
      </span>
    ),
    sort: ({ entrada }) => entrada.createdAt,
    sortDir: 'desc',
    csv: ({ entrada }) => csvInstante(entrada.createdAt),
  },
  {
    key: 'que',
    header: 'Qué pasó',
    cell: ({ linea }) => (
      <>
        <p className="text-on-surface">{linea.frase}</p>
        {linea.datos.length > 0 && (
          <p className="mt-0.5 max-w-xl whitespace-normal type-panel-caption text-on-surface-variant">
            {linea.datos.map((d) => `${d.label} ${d.valor}`).join(' · ')}
          </p>
        )}
      </>
    ),
    csv: ({ linea }) => linea.frase,
  },
  {
    key: 'afecta',
    header: 'Afecta a',
    info: 'La ficha o la sección de lo que cambió esta acción.',
    cell: ({ linea }) =>
      linea.destino ? (
        <EnlaceDestino destino={linea.destino} />
      ) : (
        <span className="text-on-surface-variant">—</span>
      ),
    csv: ({ linea }) => (linea.destino ? rotuloDeDestino(linea.destino) : null),
  },
  {
    key: 'cambio',
    header: 'Antes y después',
    cell: ({ linea }) => (
      <span className="whitespace-nowrap type-panel-caption text-on-surface-variant">
        {textoDelCambio(linea.cambio) ?? '—'}
      </span>
    ),
    csv: ({ linea }) => textoDelCambio(linea.cambio),
  },
  {
    key: 'motivo',
    header: 'Motivo',
    cell: ({ linea }) => (
      <span className="block max-w-xs whitespace-normal type-panel-caption italic text-on-surface-variant">
        {linea.motivo ?? '—'}
      </span>
    ),
    csv: ({ linea }) => linea.motivo,
  },
  // Solo para el archivo: en pantalla ya van dentro de «Qué pasó».
  {
    key: 'datos',
    header: 'Datos',
    hidden: true,
    cell: ({ linea }) => linea.datos.map((d) => `${d.label} ${d.valor}`).join(' · '),
    csv: ({ linea }) => linea.datos.map((d) => `${d.label} ${d.valor}`).join(' | ') || null,
  },
  {
    key: 'codigo',
    header: 'Código',
    hidden: true,
    info: 'El código con el que la base guarda la acción. Sirve para cruzar una línea con la base.',
    cell: ({ entrada }) => <span className="font-mono type-panel-caption">{entrada.action}</span>,
    csv: ({ entrada }) => entrada.action,
  },
]

/**
 * Todo lo que hizo el equipo en el panel: quién, qué, cuándo y sobre qué.
 *
 * La tabla es de solo añadir desde el primer día (hay triggers que bloquean
 * UPDATE y DELETE). Los filtros y la página viven en la URL, así que una vista
 * filtrada se puede mandar tal cual; el rango y la paginación los resuelve el
 * servidor.
 */
export function Bitacora({
  filtros,
  onCambiar,
}: {
  filtros: FiltrosBitacora
  /** Cambia la URL. Un cambio de filtro vuelve a la primera página. */
  onCambiar: (siguiente: FiltrosBitacora) => void
}) {
  const pagina = filtros.pagina ?? 1

  const equipo = useQuery({ queryKey: ['admin-team'], queryFn: fetchTeam })
  const parametros = useParametros()

  const query = useQuery({
    queryKey: [
      'admin-audit',
      filtros.tema ?? '',
      filtros.quien ?? '',
      filtros.desde ?? '',
      filtros.hasta ?? '',
      pagina,
      POR_PAGINA,
    ],
    queryFn: () =>
      fetchAuditLog({
        actions: accionesDelTema(filtros.tema),
        actor: filtros.quien ?? null,
        from: filtros.desde ?? null,
        to: filtros.hasta ?? null,
        limit: POR_PAGINA,
        offset: (pagina - 1) * POR_PAGINA,
      }),
  })

  const opcionesActor: Array<{ value: string; label: string }> = [
    { value: '', label: 'Cualquiera' },
    ...(equipo.data ?? []).map((m) => ({
      value: m.userId,
      label: m.fullName ?? m.email ?? 'Sin nombre',
    })),
  ]

  // Quedarse en la página 4 de un filtro que ahora tiene dos resultados
  // enseña una tabla vacía sin explicación.
  function filtrar(cambio: FiltrosBitacora) {
    onCambiar({ ...filtros, ...cambio, pagina: undefined })
  }

  const contexto = { parametros: parametros.data?.filas }
  const filas: Fila[] = (query.data?.rows ?? []).map((entrada) => ({
    entrada,
    linea: describirEvento(entrada, contexto),
  }))
  const total = query.data?.total ?? 0
  const rangoAlReves = filtros.desde && filtros.hasta && filtros.desde > filtros.hasta

  return (
    <Seccion
      titulo="Bitácora"
      info="Todo lo que hizo el equipo en el panel: quién, qué, cuándo y sobre qué. Cada acción sobre dinero, cuentas, reglas o accesos deja una línea, y nada de esto se edita ni se borra."
    >
      <FilterBar>
        <Select
          id="audit-tema"
          label="Acción"
          value={filtros.tema ?? ''}
          options={FILTROS_BITACORA.map((f) => ({ value: f.value, label: f.label }))}
          onChange={(v) => filtrar({ tema: v || undefined })}
          className="min-w-52"
        />
        <Select
          id="audit-actor"
          label="Quién"
          value={filtros.quien ?? ''}
          options={opcionesActor}
          onChange={(v) => filtrar({ quien: v || undefined })}
          className="min-w-52"
        />
        <FiltroFechas
          id="audit-fechas"
          label="Día operativo"
          desde={filtros.desde}
          hasta={filtros.hasta}
          onChange={(rango) => filtrar(rango)}
        />
      </FilterBar>

      {rangoAlReves && (
        <Callout tone="warning" titulo="La fecha de inicio es posterior a la de fin">
          Ninguna línea puede cumplir las dos.
        </Callout>
      )}

      {query.isPending && <SkeletonTable rows={8} columns={5} />}

      {query.isError && (
        <ErrorBox title="No se pudo leer la bitácora" detail={describeError(query.error)} />
      )}

      {query.data && filas.length === 0 && pagina === 1 && (
        <EmptyState
          icon={<ScrollText size={40} />}
          title="Nada con estos filtros"
          description="Cada acción del equipo sobre dinero, cuentas, reglas o accesos deja una línea aquí."
        />
      )}

      {/* Un enlace guardado puede apuntar a una página que ya no existe con
          estos filtros. Eso no es «nada»: es otra página. */}
      {query.data && filas.length === 0 && pagina > 1 && (
        <EmptyState
          icon={<ScrollText size={40} />}
          title={`No hay página ${pagina} con estos filtros`}
          action={
            <Button size="sm" variant="tonal" onClick={() => onCambiar({ ...filtros, pagina: undefined })}>
              Ir a la primera página
            </Button>
          }
        />
      )}

      {filas.length > 0 && (
        <>
          <DataTable
            rows={filas}
            rowKey={({ entrada }) => String(entrada.id)}
            columns={COLUMNAS}
            noun={['línea', 'líneas']}
            total={total}
            summary={rangoDePagina(pagina, POR_PAGINA, total)}
            exportar={{ archivo: `bitacora-pagina-${pagina}` }}
          />

          <Paginacion
            pagina={pagina}
            porPagina={POR_PAGINA}
            total={total}
            onPagina={(p) => onCambiar({ ...filtros, pagina: p > 1 ? p : undefined })}
          />
        </>
      )}
    </Seccion>
  )
}
