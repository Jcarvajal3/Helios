import { useMemo, useState } from 'react'
import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { UseQueryResult } from '@tanstack/react-query'
import { Check, Copy, ExternalLink, MessageCircle, Stethoscope } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { BuscadorEnUrl } from '@/components/FiltrosDeLista'
import { useToast } from '@/components/Toast'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import { FichaDelDirectorio } from '@/components/admin/directorio-de-medicos/FichaDelDirectorio'
import { columnasDelDirectorio } from '@/components/admin/directorio-de-medicos/columnas'
import { columnasDeInteresados } from '@/components/admin/directorio-de-medicos/columnasDeInteresados'
import { BarChart } from '@/components/charts/barras'
import { PageAction } from '@/components/layouts/PageAction'
import {
  Button,
  Callout,
  EmptyState,
  ErrorBox,
  FilterBar,
  Filtro,
  Segmented,
  SkeletonStats,
  SkeletonTable,
  Stat,
  StatGrid,
  formatDateTime,
  formatDayShort,
  formatTime,
} from '@/components/ui'
import { SITIO_URL } from '@/config/sitio'
import {
  RELECTURA_MS,
  TOPE_DE_INTERESADOS,
  consultaDirectorio,
  consultaInteresados,
  guardarTarjeta,
  refrescarDirectorio,
} from '@/features/admin/directorioDeMedicos/api'
import {
  VALORES_QUE_SE_VE,
  VISTAS_DEL_DIRECTORIO,
  cambioFrenteAlAnterior,
  filtrarInteresados,
  filtrarMedicos,
  parteDe,
} from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import type {
  InteresadoDelDirectorio,
  MedicoEnElDirectorio,
  QueSeVe,
  VistaDelDirectorio,
} from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import { FUENTES_DE_LA_PORTADA } from '@/lib/fuentes'
import { comoId, comoTexto, unoDe } from '@/lib/busqueda'
import { describeError } from '@/lib/supabase'

/** La vista, el filtro, la búsqueda y la ficha abierta: todo en la URL. */
type DirectorioSearch = {
  /** Sin escribir, la de médicos. */
  vista?: VistaDelDirectorio
  ver?: QueSeVe
  q?: string
  /** La clínica cuya ficha está abierta. */
  medico?: string
}

export const Route = createFileRoute('/admin/directorio')({
  staticData: { title: 'Directorio de médicos', width: 'wide' },
  // La vista previa de la tarjeta lleva la letra de la portada.
  head: () => ({ links: [FUENTES_DE_LA_PORTADA] }),
  component: DirectorioPage,
  validateSearch: (search: Record<string, unknown>): DirectorioSearch => ({
    vista: unoDe(VISTAS_DEL_DIRECTORIO, search.vista),
    ver: unoDe(VALORES_QUE_SE_VE, search.ver),
    q: comoTexto(search.q),
    medico: comoId(search.medico),
  }),
})

const OPCIONES_VISTA: Array<{ value: VistaDelDirectorio; label: string }> = [
  { value: 'medicos', label: 'Médicos' },
  { value: 'interesados', label: 'Interesados' },
]

const OPCIONES_VER: Array<{ value: QueSeVe; label: string }> = [
  { value: 'todos', label: 'Todos' },
  { value: 'visibles', label: 'Visibles' },
  { value: 'ocultos', label: 'Ocultos' },
]

const URL_PUBLICA = `${SITIO_URL}/directorio`
const cuenta = (n: number) => String(Math.round(n))

/**
 * Directorio de médicos: quién sale en `/directorio` (la página pública, que
 * no se enlaza desde la portada), con qué datos y cuántos pacientes le
 * escriben a cada uno.
 *
 * Arriba, el embudo de los últimos 30 días (clics → interesados →
 * pacientes) y los clics día a día. Debajo, dos vistas. «Médicos», una fila
 * por clínica: el interruptor publica u oculta al momento, y la fila abre la
 * ficha donde se corrige la tarjeta (con la vista previa) y se ven sus clics
 * y sus interesados. «Interesados», una fila por persona que escribió al
 * WhatsApp de Helios desde una tarjeta, con si ya es paciente de ese médico.
 * Nadie sale sin que alguien del equipo lo encienda. Los datos salen de
 * `admin_directorio` y `admin_directorio_interesados` (docs/01 §2.11, docs/04).
 */
function DirectorioPage() {
  const navigate = useNavigate({ from: '/admin/directorio' })
  const search = Route.useSearch()
  const vista = search.vista ?? 'medicos'
  const ver = search.ver ?? 'todos'
  const client = useQueryClient()
  const avisar = useToast()
  const [ahora] = useState(() => new Date())

  const tablero = useQuery(consultaDirectorio())
  const datos = tablero.data

  // La lista de interesados solo se pide (y se relee) con su vista delante.
  const lista = useQuery({ ...consultaInteresados(), enabled: vista === 'interesados' })

  const medicos = useMemo(() => filtrarMedicos(datos?.medicos ?? [], { q: search.q, ver }), [datos, search.q, ver])
  const interesados = useMemo(() => filtrarInteresados(lista.data ?? [], search.q), [lista.data, search.q])
  const dias = useMemo(() => (datos?.porDia ?? []).map((d) => d.dia), [datos])
  const etiquetas = useMemo(() => dias.map((d) => formatDayShort(d)), [dias])

  const visibilidad = useMutation({
    mutationFn: ({ m, visible }: { m: MedicoEnElDirectorio; visible: boolean }) =>
      guardarTarjeta(m.id, { visible }),
    onSuccess: (_, { m, visible }) => {
      refrescarDirectorio(client)
      avisar(visible ? `${m.tarjeta.nombre} ya sale en el directorio.` : `${m.tarjeta.nombre} ya no sale en el directorio.`)
    },
  })

  const { mutate: cambiarVisibilidad } = visibilidad
  const cambiando = visibilidad.isPending ? visibilidad.variables.m.id : null
  const columnas = useMemo(
    () =>
      columnasDelDirectorio({
        ahora,
        dias: etiquetas,
        cambiando,
        onVisible: (m, visible) => cambiarVisibilidad({ m, visible }),
      }),
    [ahora, etiquetas, cambiando, cambiarVisibilidad],
  )
  const columnasInteresados = useMemo(() => columnasDeInteresados({ ahora }), [ahora])

  const abierto = search.medico ? datos?.medicos.find((m) => m.id === search.medico) : undefined

  /** Un filtro es un paso del historial; una búsqueda que se teclea, no. */
  function cambiar(patch: Partial<DirectorioSearch>, replace = false) {
    void navigate({ search: (prev) => ({ ...prev, ...patch }), replace })
  }

  const visibles = datos?.medicos.filter((m) => m.visible && m.bloqueo === null).length ?? 0
  const publicables = datos?.medicos.filter((m) => m.bloqueo === null).length ?? 0
  const t = datos?.totales

  return (
    <>
      <PageAction>
        <EnlacePublico />
      </PageAction>

      <div className="flex flex-col gap-6">
        {tablero.isPending && <SkeletonStats />}
        {datos && t && (
          <>
            <StatGrid cols={4}>
              <Stat
                label="En el directorio"
                value={String(visibles)}
                hint={`de ${publicables} que se pueden publicar`}
                info="Médicos que salen hoy en /directorio: encendidos, con la clínica activa, no de prueba y con WhatsApp."
              />
              <Stat
                label="Clics · 30 días"
                value={String(t.clics30d)}
                trend={cambioFrenteAlAnterior(t.clics30d, t.clics30dAnteriores) ?? undefined}
                hint={`de ${t.visitantes30d} ${t.visitantes30d === 1 ? 'persona' : 'personas'} · ${t.clics7d} en 7 días`}
                info={`Toques al botón de WhatsApp de las tarjetas en los últimos 30 días, frente a los 30 anteriores, y los navegadores distintos que los hicieron (a ${t.medicosContactados30d} ${t.medicosContactados30d === 1 ? 'médico' : 'médicos'}). Los del equipo y los del personal de las clínicas no cuentan. Desde el inicio: ${t.clicsTotal}.`}
              />
              <Stat
                label="Interesados · 30 días"
                value={String(t.interesados30d)}
                hint={
                  parteDe(t.interesados30d, t.clics30d)
                    ? `${parteDe(t.interesados30d, t.clics30d)} de los clics`
                    : `${t.interesadosTotal} desde el inicio`
                }
                info={`Personas que, después del clic, mandaron el mensaje con el código del médico al WhatsApp de Helios en los últimos 30 días. Se cuentan por teléfono y por médico. El pie dice cuántos son por cada 100 clics. Desde el inicio: ${t.interesadosTotal}.`}
              />
              <Stat
                label="Pacientes · 30 días"
                value={String(t.convertidos30d)}
                hint={
                  parteDe(t.convertidos30d, t.interesados30d)
                    ? `${parteDe(t.convertidos30d, t.interesados30d)} de los interesados`
                    : `${t.convertidosTotal} desde el inicio`
                }
                info={`De los interesados de los últimos 30 días, los que ya tuvieron una orden confirmada con ese médico desde el mismo teléfono. Desde el inicio: ${t.convertidosTotal} de ${t.interesadosTotal}.`}
              />
            </StatGrid>

            <BarChart
              title="Clics de contacto por día"
              summary={
                <>
                  {t.clics30d} clics de {t.visitantes30d} {t.visitantes30d === 1 ? 'persona' : 'personas'} en los últimos 30 días
                </>
              }
              enteros
              series={[{ key: 'clics', label: 'Clics' }]}
              points={datos.porDia.map((d) => ({
                key: d.dia,
                label: formatDayShort(d.dia),
                values: [d.clics],
                note: d.clics > 0 ? `${d.visitantes} ${d.visitantes === 1 ? 'persona' : 'personas'}` : undefined,
              }))}
              format={cuenta}
              formatShort={cuenta}
              ejeLabel="Día"
              unidadLabel="Personas"
              footnote="Una barra por día operativo (Caracas). Cada clic es un toque al botón «Escribir por WhatsApp» de una tarjeta; no se cuentan los del equipo ni los del personal de las clínicas."
              empty="Todavía nadie ha tocado un botón de WhatsApp del directorio."
            />

            {t.clicsInternos30d > 0 && (
              <Callout
                tone="info"
                titulo={`${t.clicsInternos30d} ${t.clicsInternos30d === 1 ? 'clic del equipo no cuenta' : 'clics del equipo no cuentan'} en estas cifras`}
              >
                Se hicieron con una sesión del superadmin o de una clínica abierta en el mismo navegador
                {t.ultimoInterno ? ` (el último, ${formatDateTime(t.ultimoInterno)})` : ''}. Para probar como un
                paciente, abre /directorio en una ventana privada o en otro teléfono.
              </Callout>
            )}

            <p className="type-panel-caption text-on-surface-variant">
              Se actualiza sola cada {RELECTURA_MS / 1000} s · leído a las {formatTime(new Date(tablero.dataUpdatedAt).toISOString())}
            </p>
          </>
        )}

        {/* Sin el tope de alto de la tabla (`--panel-table-max-h`, la
            pantalla menos la barra y los filtros): aquí va debajo de las
            cifras y el gráfico, y al bajar hasta ella sobraba ese hueco en
            blanco. Con una fila por médico, la tabla se baja con la página. */}
        <div className="[--panel-table-max-h:none]">
          <FilterBar>
            <BuscadorEnUrl
              id="buscar-directorio"
              valor={search.q}
              placeholder={
                vista === 'interesados' ? 'Médico, teléfono o paciente' : 'Médico, clínica, especialidad o teléfono'
              }
              onBuscar={(q) => cambiar({ q }, true)}
            />
            <Filtro label="Vista">
              <Segmented
                options={OPCIONES_VISTA}
                value={vista}
                onChange={(v) => cambiar({ vista: v === 'medicos' ? undefined : v })}
              />
            </Filtro>
            {vista === 'medicos' && (
              <Filtro label="Médicos">
                <Segmented
                  options={OPCIONES_VER}
                  value={ver}
                  onChange={(v) => cambiar({ ver: v === 'todos' ? undefined : v })}
                />
              </Filtro>
            )}
          </FilterBar>

          {vista === 'interesados' && (
            <VistaDeInteresados
              consulta={lista}
              interesados={interesados}
              buscando={!!search.q}
              columnas={columnasInteresados}
              onAbrir={(i) => cambiar({ medico: i.medicoId })}
            />
          )}

          {vista === 'medicos' && tablero.isPending && <SkeletonTable rows={6} columns={7} />}

          {vista === 'medicos' && tablero.isError && (
            <SeccionSinLeer
              titulo="No se pudo leer el directorio de médicos"
              error={tablero.error}
              onReintentar={() => void tablero.refetch()}
            />
          )}

          {vista === 'medicos' && visibilidad.isError && (
            <div className="mb-3">
              <ErrorBox title="No se pudo cambiar" detail={describeError(visibilidad.error)} />
            </div>
          )}

          {vista === 'medicos' && tablero.isSuccess && medicos.length === 0 && (
            <EmptyState
              icon={<Stethoscope size={40} />}
              title={ver === 'visibles' && !search.q ? 'Nadie sale todavía en el directorio' : 'Nada coincide'}
              description={
                ver === 'visibles' && !search.q
                  ? 'Enciende el interruptor de un médico en «Todos» para que salga en /directorio.'
                  : 'Prueba con otra parte del nombre, de la especialidad o del teléfono, o mira «Todos».'
              }
            />
          )}

          {vista === 'medicos' && tablero.isSuccess && medicos.length > 0 && (
            <DataTable
              rows={medicos}
              rowKey={(m) => m.id}
              columns={columnas}
              noun={['médico', 'médicos']}
              summary={<Resumen medicos={medicos} />}
              rowTone={(m) => (m.visible && m.bloqueo ? 'warning' : undefined)}
              exportar={{ archivo: 'directorio-de-medicos' }}
              onRowClick={(m) => cambiar({ medico: m.id })}
            />
          )}
        </div>
      </div>

      {abierto && datos && (
        <FichaDelDirectorio
          // Otro médico es otra ficha: el borrador no pasa de uno a otro.
          key={abierto.id}
          medico={abierto}
          dias={dias}
          onClose={() => cambiar({ medico: undefined })}
        />
      )}
    </>
  )
}

function Resumen({ medicos }: { medicos: MedicoEnElDirectorio[] }) {
  const visibles = medicos.filter((m) => m.visible && m.bloqueo === null).length
  const sinWhatsapp = medicos.filter((m) => m.bloqueo === 'sin_whatsapp').length
  return (
    <>
      {visibles} en el directorio
      {sinWhatsapp > 0 && <> · {sinWhatsapp} sin WhatsApp</>}
    </>
  )
}

/**
 * Todos los interesados, el más reciente primero (como los manda la base).
 * La fila abre la ficha del médico al que le escribió.
 */
function VistaDeInteresados({
  consulta,
  interesados,
  buscando,
  columnas,
  onAbrir,
}: {
  consulta: UseQueryResult<InteresadoDelDirectorio[]>
  /** Los de la consulta, ya filtrados por la búsqueda. */
  interesados: InteresadoDelDirectorio[]
  buscando: boolean
  columnas: Array<Column<InteresadoDelDirectorio>>
  onAbrir: (i: InteresadoDelDirectorio) => void
}) {
  if (consulta.isPending) return <SkeletonTable rows={6} columns={6} />
  if (consulta.isError) {
    return (
      <SeccionSinLeer
        titulo="No se pudo leer la lista de interesados"
        error={consulta.error}
        onReintentar={() => void consulta.refetch()}
      />
    )
  }
  if (interesados.length === 0) {
    return (
      <EmptyState
        icon={<MessageCircle size={40} />}
        title={buscando ? 'Nada coincide' : 'Todavía nadie ha escrito desde el directorio'}
        description={
          buscando
            ? 'Prueba con otra parte del nombre del médico, del teléfono o del paciente.'
            : 'Sale aquí quien toque «Escribir por WhatsApp» en una tarjeta y mande al WhatsApp de Helios el mensaje con el código del médico.'
        }
      />
    )
  }
  const llegoAlTope = consulta.data.length >= TOPE_DE_INTERESADOS
  return (
    <DataTable
      rows={interesados}
      rowKey={(i) => i.id}
      columns={columnas}
      noun={['interesado', 'interesados']}
      summary={<ResumenInteresados interesados={interesados} llegoAlTope={llegoAlTope} />}
      exportar={{ archivo: 'directorio-interesados' }}
      onRowClick={onAbrir}
    />
  )
}

function ResumenInteresados({
  interesados,
  llegoAlTope,
}: {
  interesados: InteresadoDelDirectorio[]
  llegoAlTope: boolean
}) {
  const pacientes = interesados.filter((i) => i.conversion).length
  return (
    <>
      {pacientes} {pacientes === 1 ? 'ya es paciente' : 'ya son pacientes'}
      {llegoAlTope && <> · los {TOPE_DE_INTERESADOS} más recientes</>}
    </>
  )
}

/** Abrir la página pública, o copiar su enlace para mandarlo. */
function EnlacePublico() {
  const [copiado, setCopiado] = useState(false)
  return (
    <div className="flex items-center gap-2">
      <Button
        size="sm"
        variant="outlined"
        onClick={() => {
          void navigator.clipboard.writeText(URL_PUBLICA).then(() => {
            setCopiado(true)
            window.setTimeout(() => setCopiado(false), 1800)
          })
        }}
      >
        {copiado ? <Check size={15} aria-hidden /> : <Copy size={15} aria-hidden />}
        {copiado ? 'Copiado' : 'Copiar enlace'}
      </Button>
      <a
        href="/directorio"
        target="_blank"
        rel="noopener"
        className="inline-flex h-9 items-center gap-1.5 rounded-panel-control px-3 type-panel-control text-on-surface transition-colors hover:bg-panel-control"
      >
        <ExternalLink size={15} aria-hidden /> Ver el directorio
      </a>
    </div>
  )
}
