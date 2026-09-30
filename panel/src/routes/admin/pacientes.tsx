import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { keepPreviousData, useQuery } from '@tanstack/react-query'
import { Users } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import type { OrdenDeTabla } from '@/components/DataTable'
import { BuscadorEnUrl } from '@/components/FiltrosDeLista'
import { Paginacion } from '@/components/Paginacion'
import { sumandosDeDeuda, vencidoDelPadron } from '@/features/admin/directorio/padron'
import { COLUMNAS_PERSONAS } from '@/components/admin/directorio/columnasPersonas'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import {
  Checkbox,
  EmptyState,
  FilterBar,
  Filtro,
  Select,
  SkeletonTable,
  formatUsd,
} from '@/components/ui'
import {
  ESTADOS_PERSONA,
  VALORES_ESTADO_PERSONA,
  opcionesDeEstado,
} from '@/features/admin/estados'
import { fetchLevelConfig } from '@/features/admin/ops'
import { ORDENES_DEL_PADRON, fetchPaginaDeUsuarios } from '@/features/admin/users'
import type { OrdenDelPadron, ProfileStatus, UserRow } from '@/features/admin/users'
import { comoBooleano, comoEntero, comoTexto, unoDe } from '@/lib/busqueda'

/**
 * Cuántas personas por página. El servidor filtra y cuenta: la página es solo
 * cuántas se pintan a la vez, y el padrón entero se recorre con las flechas.
 */
const POR_PAGINA = 50

type PersonasSearch = {
  q?: string
  estado?: ProfileStatus
  /** El nivel de la cuenta: lo usan las filas de Riesgo › Cupos. */
  nivel?: number
  marca?: true
  prueba?: true
  /** Desde 1. La primera no se escribe. */
  pagina?: number
  /** La columna por la que se ordena el padrón entero, en la base. */
  orden?: OrdenDelPadron
  /** Sin él, ascendente. */
  dir?: 'desc'
}

export const Route = createFileRoute('/admin/pacientes')({
  staticData: { title: 'Pacientes', width: 'wide' },
  component: PersonasPage,
  validateSearch: (search: Record<string, unknown>): PersonasSearch => ({
    q: comoTexto(search.q),
    estado: unoDe(VALORES_ESTADO_PERSONA, search.estado),
    nivel: comoEntero(search.nivel, { min: 0, max: 99 }),
    marca: comoBooleano(search.marca),
    prueba: comoBooleano(search.prueba),
    pagina: comoEntero(search.pagina, { min: 2, max: 100_000 }),
    orden: unoDe(ORDENES_DEL_PADRON, search.orden),
    dir: unoDe(['desc'], search.dir),
  }),
})

const FILTROS_ESTADO = opcionesDeEstado(VALORES_ESTADO_PERSONA, ESTADOS_PERSONA)

/**
 * Personas: todas las cuentas de usuario. Es el directorio: se entra con un
 * nombre, un teléfono o una cédula en la cabeza, desde cualquier equipo.
 * Todo lo que se elige vive en la URL: el enlace que se pega en un chat abre
 * lo mismo.
 *
 * Cómo es esa gente junta, sin nombres (el Perfil), es Métricas › Gente ›
 * Perfil: lo que es análisis vive en Métricas.
 */
function PersonasPage() {
  return <ListaDePersonas />
}

/** La lista de cuentas, con sus filtros en la URL. */
function ListaDePersonas() {
  const navigate = useNavigate({ from: '/admin/pacientes' })
  const search = Route.useSearch()

  const soloMarcadas = search.marca === true
  const soloPrueba = search.prueba === true
  const nivel = search.nivel
  const pagina = search.pagina ?? 1
  const orden: { key: OrdenDelPadron; dir: 'asc' | 'desc' } | undefined = search.orden
    ? { key: search.orden, dir: search.dir ?? 'asc' }
    : undefined

  const query = useQuery({
    queryKey: [
      'admin-users',
      'pagina',
      search.q ?? '',
      search.estado ?? '',
      nivel ?? '',
      soloMarcadas,
      soloPrueba,
      pagina,
      POR_PAGINA,
      orden?.key ?? '',
      orden?.dir ?? '',
    ],
    queryFn: () =>
      fetchPaginaDeUsuarios({
        search: search.q,
        status: search.estado ?? null,
        level: nivel,
        soloMarcadas,
        soloPrueba,
        pagina,
        porPagina: POR_PAGINA,
        orden,
      }),
    // Al pasar de página se queda la anterior a la vista hasta que llega la
    // nueva: la tabla no salta a un esqueleto en cada clic.
    placeholderData: keepPreviousData,
  })

  // Los nombres de los niveles, con la misma clave que Niveles y la ficha.
  const niveles = useQuery({ queryKey: ['admin-levels'], queryFn: fetchLevelConfig })

  const filas = query.data?.filas ?? []
  const total = query.data?.total ?? 0

  /**
   * Un filtro es un paso del historial; una búsqueda que se teclea, no. Todo
   * cambio de filtro vuelve a la primera página: quedarse en la 4 de un
   * filtro que ahora tiene dos resultados enseña una tabla vacía.
   */
  function cambiar(patch: Partial<PersonasSearch>, replace = false) {
    void navigate({ search: (prev) => ({ ...prev, ...patch, pagina: undefined }), replace })
  }

  /** Cambiar el orden reordena el padrón entero y vuelve a la primera página. */
  function ordenar(nuevo: OrdenDeTabla | null) {
    const key = ORDENES_DEL_PADRON.find((k) => k === nuevo?.key)
    void navigate({
      search: (prev) => ({
        ...prev,
        orden: key,
        dir: key && nuevo?.dir === 'desc' ? 'desc' : undefined,
        pagina: undefined,
      }),
    })
  }

  function irAPagina(p: number) {
    void navigate({ search: (prev) => ({ ...prev, pagina: p > 1 ? p : undefined }) })
  }

  const hayFiltros = !!(search.q || search.estado || soloMarcadas || soloPrueba || nivel !== undefined)

  // Si los niveles no se leen, el que viene en la URL sigue a la vista: un
  // filtro puesto no puede quedar escondido.
  const opcionesDeNivel =
    niveles.data?.map((n) => ({ value: String(n.level), label: `Nivel ${n.level} · ${n.label}` })) ??
    (nivel === undefined ? [] : [{ value: String(nivel), label: `Nivel ${nivel}` }])

  return (
    <>
      <FilterBar>
        <BuscadorEnUrl
          id="buscar-persona"
          valor={search.q}
          placeholder="Teléfono, nombre o cédula"
          onBuscar={(q) => cambiar({ q }, true)}
        />

        <Select
          id="personas-estado"
          label="Estado"
          value={search.estado ?? ''}
          options={FILTROS_ESTADO}
          onChange={(value) => cambiar({ estado: value || undefined })}
          className="w-52"
        />

        <Select
          id="personas-nivel"
          label="Nivel"
          value={nivel === undefined ? '' : String(nivel)}
          placeholder="Todos los niveles"
          options={opcionesDeNivel}
          onChange={(valor) => cambiar({ nivel: valor === '' ? undefined : Number(valor) })}
          className="w-56"
        />

        {/* Las dos casillas son un filtro más: llevan su rótulo y se alinean
            con los otros por abajo. */}
        <Filtro label="Solo">
          <div className="flex h-panel-control-md flex-wrap items-center gap-4">
            <Checkbox
              id="personas-solo-marca"
              label="Con marca interna"
              checked={soloMarcadas}
              onChange={(v) => cambiar({ marca: v || undefined })}
            />
            <Checkbox
              id="personas-solo-prueba"
              label="Cuentas de prueba"
              checked={soloPrueba}
              onChange={(v) => cambiar({ prueba: v || undefined })}
            />
          </div>
        </Filtro>
      </FilterBar>

      {query.isPending && <SkeletonTable rows={8} columns={6} />}

      {query.isError && (
        <SeccionSinLeer
          titulo="No se pudo leer la lista de pacientes"
          error={query.error}
          onReintentar={() => void query.refetch()}
        />
      )}

      {query.isSuccess && filas.length === 0 && (
        <EmptyState
          icon={<Users size={40} />}
          title="Ninguna cuenta coincide"
          description={
            search.q
              ? 'Prueba con el teléfono completo o con la cédula sin puntos.'
              : hayFiltros
                ? 'Quita algún filtro para ver más cuentas.'
                : 'Cuando una clínica registre su primer financiamiento, el paciente aparecerá aquí.'
          }
        />
      )}

      {query.isSuccess && filas.length > 0 && (
        <DataTable
          rows={filas}
          rowKey={(u) => u.userId}
          columns={COLUMNAS_PERSONAS}
          noun={['cuenta', 'cuentas']}
          total={total}
          ordenEnServidor={{ orden: orden ?? null, claves: ORDENES_DEL_PADRON, onOrden: ordenar }}
          summary={
            <Resumen
              filas={filas}
              rango={total > POR_PAGINA ? rangoSinTotal(pagina, POR_PAGINA, total) : undefined}
            />
          }
          exportar={{ archivo: pagina > 1 ? `usuarios-pagina-${pagina}` : 'pacientes' }}
          // Sin nombre extraído, la fila entera en ámbar: es una cuenta que
          // pasó la verificación sin que se supiera quién es.
          rowTone={(u) => (u.fullName ? undefined : 'warning')}
          onRowClick={(u) =>
            void navigate({ to: '/admin/pacientes/$id', params: { id: u.userId } })
          }
        />
      )}

      {query.isSuccess && (
        <Paginacion pagina={pagina} porPagina={POR_PAGINA} total={total} onPagina={irAPagina} />
      )}
    </>
  )
}

/** «51 a 100»: qué filas se ven. El total ya va delante, en «203 cuentas». */
function rangoSinTotal(pagina: number, porPagina: number, total: number): string {
  const n = (x: number) => x.toLocaleString('es-VE')
  return `${n((pagina - 1) * porPagina + 1)} a ${n(Math.min(pagina * porPagina, total))}`
}

/**
 * Qué parte del padrón se ve y lo que deben esos usuarios. Con más de una
 * página, lo vencido es de la página y lo dice: el de todos está en Por
 * cobrar y en Métricas › Riesgo. Las cuentas de prueba se ven en la lista, con
 * su etiqueta, pero no suman. Lo vencido lleva el fee dentro: va con sus dos
 * partes, cuando la base las manda.
 */
function Resumen({ filas, rango }: { filas: Array<UserRow>; rango?: string }) {
  const { usuarios, vencidoUsd, partes } = vencidoDelPadron(filas)

  return (
    <>
      {rango ? `en esta página (${rango}): ` : ''}
      {usuarios} {usuarios === 1 ? 'paciente' : 'pacientes'} con deuda vencida ·{' '}
      {formatUsd(vencidoUsd)} vencido
      {partes && vencidoUsd > 0 && ` (${sumandosDeDeuda(partes)})`}
    </>
  )
}
