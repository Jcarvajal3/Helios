import { useMemo, useState } from 'react'
import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Check, Copy, ExternalLink, Stethoscope } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import { BuscadorEnUrl } from '@/components/FiltrosDeLista'
import { useToast } from '@/components/Toast'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import { FichaDelDirectorio } from '@/components/admin/directorio-de-medicos/FichaDelDirectorio'
import { columnasDelDirectorio } from '@/components/admin/directorio-de-medicos/columnas'
import { BarChart } from '@/components/charts/barras'
import { PageAction } from '@/components/layouts/PageAction'
import {
  Button,
  EmptyState,
  ErrorBox,
  FilterBar,
  Filtro,
  Segmented,
  SkeletonStats,
  SkeletonTable,
  Stat,
  StatGrid,
  formatDayShort,
} from '@/components/ui'
import { SITIO_URL } from '@/config/sitio'
import { consultaDirectorio, guardarTarjeta, refrescarDirectorio } from '@/features/admin/directorioDeMedicos/api'
import {
  VALORES_QUE_SE_VE,
  cambioFrenteAlAnterior,
  filtrarMedicos,
} from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import type { MedicoEnElDirectorio, QueSeVe } from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import { FUENTES_DE_LA_PORTADA } from '@/lib/fuentes'
import { comoId, comoTexto, unoDe } from '@/lib/busqueda'
import { describeError } from '@/lib/supabase'

/** El filtro, la búsqueda y la ficha abierta: todo en la URL. */
type DirectorioSearch = {
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
    ver: unoDe(VALORES_QUE_SE_VE, search.ver),
    q: comoTexto(search.q),
    medico: comoId(search.medico),
  }),
})

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
 * Arriba, las cifras de los últimos 30 días y los clics día a día. Debajo,
 * una fila por clínica: el interruptor publica u oculta al momento, y la
 * fila abre la ficha donde se corrige la tarjeta (con la vista previa) y se
 * ven sus clics. Nadie sale sin que alguien del equipo lo encienda. Los
 * datos salen de `admin_directorio` (docs/01 §2.11).
 */
function DirectorioPage() {
  const navigate = useNavigate({ from: '/admin/directorio' })
  const search = Route.useSearch()
  const ver = search.ver ?? 'todos'
  const client = useQueryClient()
  const avisar = useToast()
  const [ahora] = useState(() => new Date())

  const tablero = useQuery(consultaDirectorio())
  const datos = tablero.data

  const medicos = useMemo(() => filtrarMedicos(datos?.medicos ?? [], { q: search.q, ver }), [datos, search.q, ver])
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
                hint={`${t.clics7d} en los últimos 7 días`}
                info="Toques al botón de WhatsApp de las tarjetas en los últimos 30 días, frente a los 30 anteriores. Los del equipo y los del personal de las clínicas no cuentan."
              />
              <Stat
                label="Personas · 30 días"
                value={String(t.visitantes30d)}
                hint={`escribieron a ${t.medicosContactados30d} ${t.medicosContactados30d === 1 ? 'médico' : 'médicos'}`}
                info="Navegadores distintos que tocaron algún botón de WhatsApp en los últimos 30 días."
              />
              <Stat
                label="Clics desde el inicio"
                value={String(t.clicsTotal)}
                info="Todos los toques al botón de WhatsApp desde que existe el directorio."
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
          </>
        )}

        <div>
          <FilterBar>
            <BuscadorEnUrl
              id="buscar-directorio"
              valor={search.q}
              placeholder="Médico, clínica, especialidad o teléfono"
              onBuscar={(q) => cambiar({ q }, true)}
            />
            <Filtro label="Médicos">
              <Segmented
                options={OPCIONES_VER}
                value={ver}
                onChange={(v) => cambiar({ ver: v === 'todos' ? undefined : v })}
              />
            </Filtro>
          </FilterBar>

          {tablero.isPending && <SkeletonTable rows={6} columns={7} />}

          {tablero.isError && (
            <SeccionSinLeer
              titulo="No se pudo leer el directorio de médicos"
              error={tablero.error}
              onReintentar={() => void tablero.refetch()}
            />
          )}

          {visibilidad.isError && (
            <div className="mb-3">
              <ErrorBox title="No se pudo cambiar" detail={describeError(visibilidad.error)} />
            </div>
          )}

          {tablero.isSuccess && medicos.length === 0 && (
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

          {tablero.isSuccess && medicos.length > 0 && (
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
