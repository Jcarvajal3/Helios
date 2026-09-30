import { useQuery } from '@tanstack/react-query'

import {
  NoSePudoLeer,
  Seccion,
  SkeletonList,
  Stat,
  StatGrid,
  estadoDeConsulta,
  formatDay,
  formatUsd,
  diaOperativo,
  sumarDias,
} from '@/components/ui'
import { HORIZONTE_CARTERA, proximaAccion, tramoDeFila } from '@/features/admin/cobranza/cartera'
import type { CollectionRow } from '@/features/admin/cobranza/cartera'
import {
  consultaCargosPorAtraso,
  consultaGestiones,
} from '@/features/admin/cobranza/consultas'
import { lineaDeTiempo } from '@/features/admin/cobranza/lineaDeTiempo'
import { MAXIMO_DE_GESTIONES } from '@/features/admin/contacts'
import { desgloseQueCuadra } from '@/features/admin/desgloseDeCuotas'
import { textoDeDesgloseCorto } from '@/features/admin/metricas/formato'
import { QUE_PASA_EN_EL_TRAMO, cortesDeTramo, rotuloDeTramo } from '@/features/admin/tramos'
import { useParametros } from '@/features/admin/useParametros'
import { fetchUserDetail } from '@/features/admin/users'
import { LineaDeTiempo } from './CobranzaLineaDeTiempo'
import { useCasoDeCobranza } from './CobranzaWhatsApp'
import { ESTADOS_PROMESA } from '@/features/admin/estados'

// ── 6. El caso de cobranza ─────────────────────────────────────────────────

/**
 * El caso de cobranza de una persona: qué debe y desde cuándo, qué toca
 * hacer y todo lo que ha pasado, en orden.
 *
 * Los dos botones para hacerlo («Escribir por WhatsApp» y «Anotar una
 * gestión») y la barra para pasar al caso siguiente viven en la cabecera de
 * la ficha, a la vista desde cualquier pestaña. Los días de atraso ya los
 * dice el carril, en la pastilla de «Deuda en cuotas»: aquí no se repiten.
 */
export function PestanaCobranza({ userId }: { userId: string }) {
  const fila = useCasoDeCobranza(userId)

  return (
    <div className="flex flex-col gap-6">
      <ResumenDelCaso userId={userId} fila={fila} />
      <HistoriaDelCaso userId={userId} />
    </div>
  )
}

// ── Arriba: lo vencido, el atraso, el tramo y la próxima acción ────────────

function ResumenDelCaso({
  userId,
  fila,
}: {
  userId: string
  fila: ReturnType<typeof useCasoDeCobranza>
}) {
  const parametros = useParametros()
  const usuario = useQuery({ queryKey: ['admin-user', userId], queryFn: () => fetchUserDetail(userId) })
  const cortes = cortesDeTramo(parametros.data)
  const hoy = diaOperativo(new Date())
  const estado = estadoDeConsulta(fila)
  const reintentar = () => void fila.refetch()

  if (estado === 'listo' && fila.data === null) {
    return (
      <p className="type-panel-body text-on-surface-variant">
        No tiene cuotas vencidas ni por vencer en los próximos {HORIZONTE_CARTERA} días.
      </p>
    )
  }

  const f: CollectionRow | null = fila.data ?? null
  // Lo vencido partido en consumo y fee, de las cuotas de la ficha (la misma
  // consulta que la cabecera: no vuelve a pedir nada) y solo si cuadra.
  const vencidoPartido =
    f?.overdueDesglose ??
    (f && usuario.data
      ? desgloseQueCuadra(
          usuario.data.installments.filter((i) => i.status === 'pending' && i.daysOverdue > 0),
          f.overdueUsd,
        )
      : null)
  // Lo que vence de hoy a hoy + 7 (el horizonte de la cartera), también
  // partido: es payable. Primero el desglose del servidor; si no viene, el de
  // las cuotas de la ficha, solo si cuadra.
  const hasta = sumarDias(hoy, HORIZONTE_CARTERA)
  const porVencerPartido =
    f?.upcomingDesglose ??
    (f && usuario.data
      ? desgloseQueCuadra(
          usuario.data.installments.filter(
            (i) => i.status === 'pending' && !i.writtenOffAt && i.daysOverdue === 0 && i.dueDate <= hasta,
          ),
          f.upcomingUsd,
        )
      : null)
  const tramo = f && cortes ? tramoDeFila(f, cortes) : null
  const accion = proximaAccion(f?.lastContactNextActionOn ?? null, hoy)

  return (
    <StatGrid cols={3}>
      <Stat
        label="Vencido (financiamiento + fee)"
        value={f ? formatUsd(f.overdueUsd) : ''}
        hint={
          f && f.overdueUsd === 0
            ? `Por vencer en ${HORIZONTE_CARTERA} días: ${formatUsd(f.upcomingUsd)}${
                porVencerPartido ? ` (${textoDeDesgloseCorto(porVencerPartido)})` : ''
              } · la primera, el ${formatDay(f.nextDueDate)}`
            : vencidoPartido
              ? textoDeDesgloseCorto(vencidoPartido)
              : undefined
        }
        info="Suma de sus cuotas sin pagar con vencimiento anterior a hoy (día operativo), en financiamiento + service fee; debajo, sus dos partes. El cargo por atraso va aparte."
        link={{ to: '/admin/pacientes/$id', params: { id: userId }, search: { tab: 'consumos' } }}
        estado={estado}
        onReintentar={reintentar}
      />
      <Stat
        label="Tramo de atraso"
        value={tramo && cortes ? rotuloDeTramo(tramo, cortes) : 'Sin atraso'}
        hint={tramo ? QUE_PASA_EN_EL_TRAMO[tramo] : undefined}
        link={tramo ? { to: '/admin/cobranza', search: { tramo } } : undefined}
        estado={estado === 'listo' ? estadoDeConsulta(parametros) : estado}
        onReintentar={parametros.isError ? () => void parametros.refetch() : reintentar}
      />
      <Stat
        label="Próxima acción"
        value={
          accion === null
            ? 'Sin fecha'
            : accion.cuando === 'hoy'
              ? 'Hoy'
              : formatDay(accion.fecha)
        }
        senal={accion?.cuando === 'atrasada' ? { tone: 'error', texto: 'Atrasada' } : undefined}
        hint={
          f?.promiseDate
            ? `Prometió pagar el ${formatDay(f.promiseDate)}${
                f.promiseStatus ? ` · ${ESTADOS_PROMESA[f.promiseStatus].label}` : ''
              }`
            : accion?.cuando === 'atrasada'
              ? 'La fecha pasó sin una gestión nueva.'
              : undefined
        }
        info="El día para volver a llamar que se anotó en la última gestión."
        estado={estado}
        onReintentar={reintentar}
      />
    </StatGrid>
  )
}

// ── Abajo: todo lo que ha pasado ───────────────────────────────────────────

function HistoriaDelCaso({ userId }: { userId: string }) {
  const persona = useQuery({
    queryKey: ['admin-user', userId],
    queryFn: () => fetchUserDetail(userId),
  })
  const gestiones = useQuery(consultaGestiones(userId))
  const cargos = useQuery(consultaCargosPorAtraso(userId))

  const cargando = persona.isPending || gestiones.isPending || cargos.isPending
  const hoy = diaOperativo(new Date())

  // Lo que no se pudo leer se dice, y la línea enseña lo demás: un hueco sin
  // aviso se leería como «nunca pasó».
  const fallos: Array<{ que: string; reintentar: () => void }> = [
    ...(persona.isError ? [{ que: 'Pagos y cuotas', reintentar: () => void persona.refetch() }] : []),
    ...(gestiones.isError ? [{ que: 'Gestiones', reintentar: () => void gestiones.refetch() }] : []),
    ...(cargos.isError ? [{ que: 'Cargos por atraso', reintentar: () => void cargos.refetch() }] : []),
  ]

  const sucesos = lineaDeTiempo({
    gestiones: gestiones.data ?? [],
    pagos: persona.data?.payments ?? [],
    cuotas: persona.data?.installments ?? [],
    cargos: cargos.data ?? [],
    hoy,
  })

  return (
    <Seccion
      titulo="Lo que ha pasado"
      info="Las gestiones, los pagos reportados, las cuotas vencidas y los cargos por atraso, lo último arriba."
    >
      {fallos.map((f) => (
        <p key={f.que} className="flex flex-wrap items-baseline gap-x-2 type-panel-body text-on-surface-variant">
          {f.que}:
          <NoSePudoLeer onReintentar={f.reintentar} />
        </p>
      ))}

      {gestiones.data?.length === MAXIMO_DE_GESTIONES && (
        <p className="type-panel-caption text-panel-muted">
          Se ven las {MAXIMO_DE_GESTIONES} gestiones más recientes.
        </p>
      )}

      {/* Con algo sin leer, una lista vacía no puede decir «no tiene nada». */}
      {cargando ? (
        <SkeletonList rows={4} />
      ) : sucesos.length === 0 && fallos.length > 0 ? null : (
        <LineaDeTiempo sucesos={sucesos} />
      )}
    </Seccion>
  )
}
