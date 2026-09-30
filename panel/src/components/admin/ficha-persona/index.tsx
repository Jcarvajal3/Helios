import { useNavigate } from '@tanstack/react-router'
import { useQuery, useQueryClient } from '@tanstack/react-query'

import { BarraDeCola } from '@/components/admin/ModoCola'
import { MarcoDeFicha, VolverA, useVolverDeFicha } from '@/components/admin/ficha'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import { usePageTitle } from '@/components/layouts/PageAction'
import { useBloqueoDeCuenta } from '@/components/UserBlockCard'
import { SkeletonList, Tabs } from '@/components/ui'
import { fetchLevelConfig } from '@/features/admin/ops'
import { fetchUserDetail } from '@/features/admin/users'
import type { UserDetail } from '@/features/admin/users'
import { menuDePersona } from './accionesDeCuenta'
import { Cabecera } from './Cabecera'
import { CarrilPersona } from './Carril'
import { PestanaCobranza } from './Cobranza'
import { useColaDelCaso } from './CobranzaCola'
import { PestanaConsumos } from './Consumos'
import { PestanaHistorial } from './Historial'
import { PestanaPagos } from './Pagos'
import { PestanaResumen } from './Resumen'
import { useAccionesDeCuenta } from './ResumenAcciones'

/*
 * La ficha de una persona, partida en un archivo por pestaña: quien trabaja
 * en una pestaña no pisa a quien trabaja en otra, y cada archivo se lee
 * entero.
 */

export type PestanaPersona =
  | 'resumen'
  | 'consumos'
  | 'pagos'
  | 'cobranza'
  | 'historial'

/** En el orden de las pestañas. Sirve también para validar la URL. */
export const PESTANAS_PERSONA: ReadonlyArray<PestanaPersona> = [
  'resumen',
  'consumos',
  'pagos',
  'cobranza',
  'historial',
]

const ROTULO: Record<PestanaPersona, string> = {
  resumen: 'Resumen',
  consumos: 'Financiamientos y cuotas',
  pagos: 'Pagos',
  cobranza: 'Cobranza',
  historial: 'Historial',
}

const PESTANAS = PESTANAS_PERSONA.map((value) => ({ value, label: ROTULO[value] }))

/**
 * La página de una persona.
 *
 * La cabecera está siempre a la vista —quién es, en qué estado, cómo
 * escribirle— y el carril también —qué debe, cuánto puede gastar, qué se le
 * puede hacer—. Lo demás va en pestañas, en el orden en que se contesta una
 * llamada: si su identidad está comprobada, qué consumió, qué pagó, qué se le
 * ha dicho y qué se le ha hecho a la cuenta.
 */
export function PaginaPersona({
  userId,
  tab,
  onTab,
}: {
  userId: string
  tab: PestanaPersona
  onTab: (tab: PestanaPersona) => void
}) {
  const client = useQueryClient()

  const detail = useQuery({
    queryKey: ['admin-user', userId],
    queryFn: () => fetchUserDetail(userId),
  })

  usePageTitle(detail.data ? (detail.data.fullName ?? 'Sin nombre') : null)

  // Todo lo de esta persona cuelga de ['admin-user', userId]: la ficha, sus
  // consumos y sus bloqueos se refrescan juntos.
  const invalidate = () => {
    void client.invalidateQueries({ queryKey: ['admin-user', userId] })
    void client.invalidateQueries({ queryKey: ['admin-users'] })
    void client.invalidateQueries({ queryKey: ['admin-audit'] })
  }

  return (
    <>
      <VolverOSiguiente userId={userId} />

      {detail.isPending && <SkeletonList rows={3} />}

      {detail.isError && (
        <SeccionSinLeer
          titulo="No se pudo abrir la ficha"
          error={detail.error}
          onReintentar={() => void detail.refetch()}
        />
      )}

      {detail.data && (
        <FichaPersona
          user={detail.data}
          userId={userId}
          tab={tab}
          onTab={onTab}
          onDone={invalidate}
        />
      )}
    </>
  )
}

/**
 * La ficha ya leída. Aquí viven las acciones sobre la cuenta y el bloqueo
 * porque sus botones están repartidos: las de todos los días en el carril y
 * las que frenan a alguien en el «⋯» de la cabecera. Los diálogos se montan
 * una vez, abajo.
 */
function FichaPersona({
  user,
  userId,
  tab,
  onTab,
  onDone,
}: {
  user: UserDetail
  userId: string
  tab: PestanaPersona
  onTab: (tab: PestanaPersona) => void
  onDone: () => void
}) {
  const niveles = useQuery({ queryKey: ['admin-levels'], queryFn: fetchLevelConfig })
  const activos = niveles.data?.filter((l) => l.isActive)

  const cuenta = useAccionesDeCuenta({ user, niveles: activos, onDone })
  const bloqueo = useBloqueoDeCuenta(userId)

  const menu = menuDePersona({
    status: user.status,
    marcada: user.isBlacklisted,
    bloqueo: bloqueo.estado,
    apagado: cuenta.apagado,
    abrir: cuenta.abrir,
    bloquear: bloqueo.bloquear,
  })

  return (
    <>
      <MarcoDeFicha
        cabecera={<Cabecera user={user} bloqueada={bloqueo.estado === 'abierto'} menu={menu} />}
        carril={
          <CarrilPersona
            user={user}
            niveles={{
              datos: activos,
              error: niveles.isError,
              reintentar: () => void niveles.refetch(),
            }}
            cuenta={cuenta}
            bloqueo={bloqueo}
          />
        }
      >
        <Tabs options={PESTANAS} value={tab} onChange={onTab} className="mb-0" />

        {tab === 'resumen' && <PestanaResumen user={user} niveles={activos} bloqueo={bloqueo} />}

        {tab === 'consumos' && <PestanaConsumos user={user} userId={userId} onDone={onDone} />}

        {tab === 'pagos' && <PestanaPagos user={user} />}

        {tab === 'cobranza' && <PestanaCobranza userId={userId} />}

        {tab === 'historial' && <PestanaHistorial userId={userId} />}
      </MarcoDeFicha>

      {cuenta.dialogo}
      {bloqueo.dialogo}
    </>
  )
}

/**
 * Encima de la cabecera: la barra para pasar al caso siguiente si se llegó
 * desde la cartera vencida o desde las promesas (o desde «Empezar» en
 * Inicio), y si no, la vuelta a Personas.
 *
 * Va fuera de las pestañas porque el caso se trabaja desde la ficha entera:
 * se puede mirar Consumos o Pagos y seguir con J al siguiente, que se abre en
 * su pestaña Cobranza.
 */
function VolverOSiguiente({ userId }: { userId: string }) {
  const navigate = useNavigate()
  const { cola, volverA } = useColaDelCaso(userId)
  // La pantalla desde la que se abrió manda: la lista fija de la cola solo
  // vale si no se sabe (un enlace pegado).
  const origen = useVolverDeFicha()

  if (cola.total === 0) {
    return <VolverA link={{ to: '/admin/pacientes' }}>Pacientes</VolverA>
  }

  return (
    <BarraDeCola
      cola={cola}
      rotulo={
        origen.origen?.titulo ??
        (volverA.lista === 'promesas' ? 'Promesas' : volverA.lista === 'morosos' ? 'Morosos' : 'Por cobrar')
      }
      onIr={(id) =>
        void navigate({ to: '/admin/pacientes/$id', params: { id }, search: { tab: 'cobranza' } })
      }
      onVolver={() =>
        origen.volver
          ? origen.volver()
          : void (volverA.lista === 'promesas'
          ? navigate({
              to: '/admin/cobranza',
              search: {
                vista: 'promesas',
                estado: volverA.estado === 'vence_hoy' ? undefined : volverA.estado,
              },
            })
          : volverA.lista === 'morosos'
            ? navigate({ to: '/admin/cobranza', search: { vista: 'morosos' } })
            : navigate({
                to: '/admin/cobranza',
                search: { tramo: volverA.tramo === 'todos' ? undefined : volverA.tramo },
              }))
      }
    />
  )
}
