import { useMemo, useState } from 'react'
import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { Contact } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import { BuscadorEnUrl } from '@/components/FiltrosDeLista'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import { FichaDeSeguimiento } from '@/components/admin/seguimiento/FichaDeSeguimiento'
import { columnasPorClinica, columnasPorPersona } from '@/components/admin/seguimiento/columnas'
import { EmptyState, FilterBar, Filtro, Segmented, SkeletonTable, diaOperativo } from '@/components/ui'
import { consultaTablero } from '@/features/admin/seguimiento/api'
import {
  VALORES_QUE_SE_VE,
  esParaLlamar,
  estadoDelSeguimiento,
  filtrarClinicas,
  filtrarPersonas,
  ordenarParaLlamar,
  personasDelTablero,
} from '@/features/admin/seguimiento/seguimiento'
import type {
  ClinicaEnSeguimiento,
  PersonaConSuClinica,
  Prioridad,
  QueSeVe,
} from '@/features/admin/seguimiento/seguimiento'
import { comoId, comoTexto, unoDe } from '@/lib/busqueda'

type Vista = 'clinicas' | 'personas'

/** La vista, el filtro, la búsqueda y la ficha abierta: todo en la URL. */
type SeguimientoSearch = {
  vista?: Vista
  ver?: QueSeVe
  q?: string
  /** La clínica cuya ficha de seguimiento está abierta. */
  clinica?: string
  /** Con quién, cuando la ficha se abrió desde la fila de una persona. */
  persona?: string
}

export const Route = createFileRoute('/admin/seguimiento')({
  staticData: { title: 'Seguimiento', width: 'wide' },
  component: SeguimientoPage,
  validateSearch: (search: Record<string, unknown>): SeguimientoSearch => ({
    vista: unoDe(['clinicas', 'personas'] as const, search.vista),
    ver: unoDe(VALORES_QUE_SE_VE, search.ver),
    q: comoTexto(search.q),
    clinica: comoId(search.clinica),
    persona: comoId(search.persona),
  }),
})

const OPCIONES_VISTA: Array<{ value: Vista; label: string }> = [
  { value: 'personas', label: 'Por persona' },
  { value: 'clinicas', label: 'Por clínica' },
]

const OPCIONES_VER: Array<{ value: QueSeVe; label: string }> = [
  { value: 'para_llamar', label: 'Para llamar' },
  { value: 'activas', label: 'Activas' },
  { value: 'todas', label: 'Todas' },
]

/**
 * Seguimiento: el contacto permanente del equipo con cada clínica.
 *
 * «Por persona», la que se abre, es todo el personal junto con su semáforo de
 * prioridad de contacto (sus órdenes cruzadas con cuánto lleva sin usar el
 * panel ni el bot): arriba, a quien hay que llamar para saber por qué no usa
 * Helios, y dentro de cada color quien más órdenes tiene. «Por clínica» es la
 * lista de las llamadas pendientes: el médico, el teléfono del consultorio,
 * todo su personal y qué se habló la última vez, en el orden en que hay que
 * llamar (lo atrasado, lo de hoy y las que nunca se han llamado, arriba). Las
 * dos abren la misma ficha, donde se llama, se escribe y se anota lo hablado.
 * Los datos salen de `admin_followups_board` (docs/01 §2.8).
 */
function SeguimientoPage() {
  const navigate = useNavigate({ from: '/admin/seguimiento' })
  const search = Route.useSearch()
  const vista = search.vista ?? 'personas'
  const ver = search.ver ?? 'activas'
  const [hoy] = useState(() => diaOperativo(new Date()))
  const [ahora] = useState(() => new Date())

  const tablero = useQuery(consultaTablero())

  const clinicas = useMemo(
    () => ordenarParaLlamar(filtrarClinicas(tablero.data ?? [], { texto: search.q, ver }, hoy), hoy),
    [tablero.data, search.q, ver, hoy],
  )
  const personas = useMemo(
    () => filtrarPersonas(personasDelTablero(clinicas, ahora), vista === 'personas' ? search.q : ''),
    [clinicas, search.q, vista, ahora],
  )
  const columnasClinica = useMemo(() => columnasPorClinica(hoy, ahora), [hoy, ahora])
  const columnasPersona = useMemo(() => columnasPorPersona(ahora), [ahora])

  const abierta = search.clinica ? tablero.data?.find((c) => c.id === search.clinica) : undefined

  /** Un filtro es un paso del historial; una búsqueda que se teclea, no. */
  function cambiar(patch: Partial<SeguimientoSearch>, replace = false) {
    void navigate({ search: (prev) => ({ ...prev, ...patch }), replace })
  }

  const filas = vista === 'clinicas' ? clinicas : personas

  return (
    <>
      <FilterBar>
        <BuscadorEnUrl
          id="buscar-seguimiento"
          valor={search.q}
          placeholder="Clínica, médico, persona o teléfono"
          onBuscar={(q) => cambiar({ q }, true)}
        />
        <Filtro label="Vista">
          <Segmented
            options={OPCIONES_VISTA}
            value={vista}
            onChange={(v) => cambiar({ vista: v === 'personas' ? undefined : v })}
          />
        </Filtro>
        <Filtro label="Clínicas">
          <Segmented
            options={OPCIONES_VER}
            value={ver}
            onChange={(v) => cambiar({ ver: v === 'activas' ? undefined : v })}
          />
        </Filtro>
      </FilterBar>

      {tablero.isPending && <SkeletonTable rows={6} columns={6} />}

      {tablero.isError && (
        <SeccionSinLeer
          titulo="No se pudo leer el seguimiento de las clínicas"
          error={tablero.error}
          onReintentar={() => void tablero.refetch()}
        />
      )}

      {tablero.isSuccess && filas.length === 0 && (
        <EmptyState
          icon={<Contact size={40} />}
          title={ver === 'para_llamar' && !search.q ? 'No hay nadie a quien llamar hoy' : 'Nada coincide'}
          description={
            ver === 'para_llamar' && !search.q
              ? 'Todas las clínicas activas tienen un contacto anotado y ninguna fecha para volver a llamar vence hoy.'
              : 'Prueba con otra parte del nombre o del teléfono, o mira «Todas».'
          }
        />
      )}

      {tablero.isSuccess && vista === 'clinicas' && clinicas.length > 0 && (
        <DataTable
          rows={clinicas}
          rowKey={(c) => c.id}
          columns={columnasClinica}
          noun={['clínica', 'clínicas']}
          summary={<ResumenClinicas clinicas={clinicas} hoy={hoy} />}
          rowTone={(c) => tonoDeFila(c, hoy)}
          exportar={{ archivo: 'seguimiento-clinicas' }}
          onRowClick={(c) => cambiar({ clinica: c.id, persona: undefined })}
        />
      )}

      {tablero.isSuccess && vista === 'personas' && personas.length > 0 && (
        <DataTable
          rows={personas}
          rowKey={(p) => `${p.clinicaId}:${p.userId}`}
          columns={columnasPersona}
          noun={['persona', 'personas']}
          summary={<ResumenPersonas personas={personas} />}
          rowTone={(p) => TONO_DE_PRIORIDAD[p.prioridad?.prioridad ?? 'activo']}
          exportar={{ archivo: 'seguimiento-personas' }}
          onRowClick={(p) => cambiar({ clinica: p.clinicaId, persona: p.userId })}
        />
      )}

      {abierta && (
        <FichaDeSeguimiento
          // Otra clínica es otra ficha: el borrador no pasa de una a otra.
          key={`${abierta.id}:${search.persona ?? ''}`}
          clinica={abierta}
          conQuien={search.persona}
          onClose={() => cambiar({ clinica: undefined, persona: undefined })}
        />
      )}
    </>
  )
}

function tonoDeFila(c: ClinicaEnSeguimiento, hoy: string): 'warning' | 'error' | undefined {
  if (!esParaLlamar(c, hoy)) return undefined
  return estadoDelSeguimiento(c, hoy) === 'atrasado' ? 'error' : 'warning'
}

const TONO_DE_PRIORIDAD: Record<Prioridad, 'warning' | 'error' | undefined> = {
  contactar_ya: 'error',
  contactar_pronto: 'warning',
  activo: undefined,
}

function ResumenClinicas({ clinicas, hoy }: { clinicas: ClinicaEnSeguimiento[]; hoy: string }) {
  const paraLlamar = clinicas.filter((c) => esParaLlamar(c, hoy)).length
  const nunca = clinicas.filter((c) => c.contactos === 0).length
  return (
    <>
      {paraLlamar} para llamar · {nunca} {nunca === 1 ? 'nunca contactada' : 'nunca contactadas'}
    </>
  )
}

function ResumenPersonas({ personas }: { personas: PersonaConSuClinica[] }) {
  const conNumero = personas.filter((p) => p.telefono !== null).length
  const cuantas = (prioridad: Prioridad) => personas.filter((p) => p.prioridad?.prioridad === prioridad).length
  const primera = personas.reduce<PersonaConSuClinica | undefined>(
    (a, p) => (a === undefined || p.confirmadas > a.confirmadas ? p : a),
    undefined,
  )
  return (
    <>
      {cuantas('contactar_ya')} para contactar ya · {cuantas('contactar_pronto')} pronto · {conNumero} con número
      del bot
      {primera && primera.confirmadas > 0 && (
        <>
          {' '}
          · la que más órdenes registra: {primera.nombre} ({primera.clinica}), {primera.confirmadas}
        </>
      )}
    </>
  )
}
