import { useState } from 'react'
import type { ReactNode } from 'react'
import { useMutation } from '@tanstack/react-query'

import { useToast } from '@/components/Toast'
import { Callout, ConfirmDialog, formatUsd } from '@/components/ui'
import type { NivelConfirmacion } from '@/components/ui'
import { desgloseQueCuadra } from '@/features/admin/desgloseDeCuotas'
import { usoDelCupo } from '@/features/admin/directorio/cupo'
import { estadoDePersona } from '@/features/admin/estados'
import { textoDeDesgloseCorto } from '@/features/admin/metricas/formato'
import type { LevelConfig } from '@/features/admin/ops'
import { useIsSuperAdmin } from '@/features/admin/role'
import { setTestAccount } from '@/features/admin/testAccounts'
import { setBlacklist, setUserLevel, setUserStatus } from '@/features/admin/users'
import type { ProfileStatus, UserDetail } from '@/features/admin/users'
import { describeError } from '@/lib/supabase'
import type { AccionDeCuenta } from './accionesDeCuenta'

// ── Las acciones sobre la cuenta ───────────────────────────────────────────

/**
 * Las acciones sobre la cuenta y sus diálogos: el estado, el nivel, la marca
 * interna y la marca de prueba.
 *
 * Es un hook y no una tarjeta porque sus botones viven en dos sitios: las de
 * todos los días en el carril de la ficha y las destructivas en el «⋯» de la
 * cabecera. Los dos abren con `abrir` y el diálogo se pinta donde se monte
 * `dialogo`.
 *
 * Todas las exige el servidor a un super admin (`admin_set_user_status`,
 * `admin_set_user_level`, `admin_set_blacklist`, `admin_set_test_account`):
 * el operador las ve apagadas y con el motivo antes de abrir un diálogo que no
 * va a poder confirmar.
 *
 * «Suspender» es un estado de la cuenta, y el estado automático lo levanta
 * solo cuando la persona no debe nada. El freno que no se levanta solo es
 * «Bloquear la cuenta» (`useBloqueoDeCuenta`).
 */
export function useAccionesDeCuenta({
  user,
  niveles,
  onDone,
}: {
  user: UserDetail
  /** Los niveles activos. `undefined` mientras se leen. */
  niveles: Array<LevelConfig> | undefined
  onDone: () => void
}): { abrir: (accion: AccionDeCuenta) => void; apagado: boolean; dialogo: ReactNode } {
  const isSuperAdmin = useIsSuperAdmin()
  const avisar = useToast()
  const [abierta, setAbierta] = useState<AccionDeCuenta | null>(null)

  // Cada aviso dice el valor NUEVO y de quién: con cuatro palancas seguidas,
  // «Hecho» no distingue cuál acaba de moverse.
  const quien = user.fullName ?? 'esta cuenta'

  function cerrar() {
    setAbierta(null)
    estado.reset()
    nivel.reset()
    marca.reset()
    prueba.reset()
  }

  const estado = useMutation({
    mutationFn: (params: { status: ProfileStatus; note: string }) =>
      setUserStatus({ userId: user.userId, status: params.status, note: params.note }),
    onSuccess: (_data, params) => {
      cerrar()
      avisar(`${quien}: ${estadoDePersona(params.status).label.toLowerCase()}`)
      onDone()
    },
  })

  const nivel = useMutation({
    mutationFn: (params: { level: number; note: string }) =>
      setUserLevel({ userId: user.userId, level: params.level, note: params.note }),
    onSuccess: (_data, params) => {
      cerrar()
      avisar(params.level === 0 ? `${quien} se queda sin nivel` : `${quien} pasa a nivel ${params.level}`)
      onDone()
    },
  })

  const marca = useMutation({
    mutationFn: (reason: string) =>
      setBlacklist({ userId: user.userId, flag: !user.isBlacklisted, reason }),
    onSuccess: () => {
      cerrar()
      avisar(user.isBlacklisted ? `Marca interna quitada a ${quien}` : `${quien} queda con marca interna`)
      onDone()
    },
  })

  const prueba = useMutation({
    mutationFn: (note: string) =>
      setTestAccount({ kind: 'user', id: user.userId, flag: !user.isTest, note }),
    onSuccess: () => {
      cerrar()
      avisar(
        user.isTest
          ? `${quien} deja de ser cuenta de prueba y vuelve a contar en las cifras`
          : `${quien} pasa a cuenta de prueba y deja de contar en las cifras`,
      )
      onDone()
    },
  })

  let dialogo: ReactNode = null

  if (abierta?.tipo === 'estado') {
    dialogo = (
      <DialogoDeEstado
        user={user}
        destino={abierta.destino}
        busy={estado.isPending}
        error={estado.isError ? describeError(estado.error) : undefined}
        onConfirm={(note) => estado.mutate({ status: abierta.destino, note })}
        onClose={cerrar}
      />
    )
  }

  if (abierta?.tipo === 'nivel') {
    dialogo = (
      <DialogoDeNivel
        user={user}
        nuevo={niveles?.find((l) => l.level === abierta.level)}
        level={abierta.level}
        busy={nivel.isPending}
        error={nivel.isError ? describeError(nivel.error) : undefined}
        onConfirm={(note) => nivel.mutate({ level: abierta.level, note })}
        onClose={cerrar}
      />
    )
  }

  if (abierta?.tipo === 'prueba') {
    dialogo = (
      <ConfirmDialog
        title={user.isTest ? 'Quitar la marca de prueba' : 'Marcar como cuenta de prueba'}
        summary={
          user.isTest
            ? `${user.fullName ?? 'Este paciente'} vuelve a contar en las cifras, en las colas y en las promociones. Lo que se financió mientras estaba marcada vuelve a sumar.`
            : `${user.fullName ?? 'Este paciente'} deja de contar en la mora, en las cohortes, en los rankings y en las colas. Lo que ya se financió deja de sumar también.`
        }
        detail={
          <p className="type-panel-body text-on-surface-variant">
            Sus financiamientos y pagos se siguen escribiendo en el libro y en la bitácora, marcados
            como prueba: una prueba deja rastro, pero no entra en la contabilidad.
          </p>
        }
        nivel="sensible"
        reasonPlaceholder="Cuenta del equipo para probar el flujo de cobro"
        confirmLabel={user.isTest ? 'Quitar la marca' : 'Marcar como prueba'}
        busy={prueba.isPending}
        error={prueba.isError ? describeError(prueba.error) : undefined}
        onConfirm={(note) => prueba.mutate(note)}
        onClose={cerrar}
      />
    )
  }

  if (abierta?.tipo === 'marca') {
    dialogo = (
      <ConfirmDialog
        title={user.isBlacklisted ? 'Quitar la marca interna' : 'Poner la marca interna'}
        summary={
          user.isBlacklisted
            ? `Si ${user.fullName ?? 'este paciente'} vuelve a aparecer con esta cédula, se le podrá volver a financiar.`
            : `Si ${user.fullName ?? 'este paciente'} vuelve a aparecer con esta cédula, ninguna clínica podrá financiarle. La marca es permanente y sobrevive a cualquier cambio de estado.`
        }
        nivel="sensible"
        reasonPlaceholder="Se fue debiendo dos cuotas y no responde"
        confirmLabel={user.isBlacklisted ? 'Quitar la marca' : 'Marcar'}
        danger={!user.isBlacklisted}
        busy={marca.isPending}
        error={marca.isError ? describeError(marca.error) : undefined}
        onConfirm={(reason) => marca.mutate(reason)}
        onClose={cerrar}
      />
    )
  }

  return { abrir: setAbierta, apagado: !isSuperAdmin, dialogo }
}

type Dialogo = {
  title: string
  summary: string
  detail?: ReactNode
  confirmLabel: string
  placeholder: string
  nivel: NivelConfirmacion
  confirmWord?: string
}

/** Lo que dice el diálogo de cada cambio de estado. */
function textosDeEstado(user: UserDetail, destino: ProfileStatus): Dialogo {
  const quien = user.fullName ?? 'Este paciente'
  // Lo que debe y lo vencido son payable: van con sus dos partes si cuadran.
  const vivas = user.installments.filter((i) => i.status === 'pending' && !i.writtenOffAt)
  const partes = desgloseQueCuadra(vivas, user.debt.openUsd)
  const partesVencidas = desgloseQueCuadra(
    vivas.filter((i) => i.daysOverdue > 0),
    user.debt.overdueUsd,
  )

  if (destino === 'frozen') {
    return {
      title: 'Congelar la cuenta',
      summary: `${quien} no va a poder hacer financiamientos nuevos. La cuenta sigue viva y sus cuotas siguen su curso.`,
      confirmLabel: 'Congelar',
      placeholder: 'Sospecha de uso por un tercero',
      nivel: 'sensible',
    }
  }

  if (destino === 'suspended') {
    return {
      title: 'Suspender la cuenta',
      summary: `${quien} no va a poder financiarse. Es el escalón siguiente a congelar, y el estado automático lo levanta por la mañana si no tiene cuotas vencidas.`,
      detail: (
        <p className="type-panel-body text-on-surface-variant">
          Para un freno que no se levante solo, usa «Bloquear la cuenta».
        </p>
      ),
      confirmLabel: 'Suspender',
      placeholder: 'Cuarenta días sin pagar y sin responder',
      nivel: 'sensible',
    }
  }

  if (destino === 'expelled') {
    return {
      title: 'Expulsar',
      summary: `${quien} queda fuera de Helios. De la expulsión no se vuelve.`,
      detail: (
        <p className="type-panel-body text-on-surface-variant">
          Debe {formatUsd(user.debt.openUsd)} en cuotas
          {partes ? ` (${textoDeDesgloseCorto(partes)})` : ''}, {formatUsd(user.debt.overdueUsd)} de
          ello vencido. La marca interna se pone aparte: expulsar no la pone.
        </p>
      ),
      confirmLabel: 'Expulsar',
      placeholder: 'Fraude confirmado con la clínica',
      nivel: 'critico',
      confirmWord: 'EXPULSAR',
    }
  }

  const suspendido = user.status === 'suspended'
  return {
    title: suspendido ? 'Levantar la suspensión' : 'Descongelar la cuenta',
    summary: `${quien} va a poder volver a financiarse.${
      user.debt.overdueUsd > 0
        ? ` Todavía tiene ${formatUsd(user.debt.overdueUsd)} vencido${
            partesVencidas ? ` (${textoDeDesgloseCorto(partesVencidas)})` : ''
          }, así que el estado automático la volverá a congelar mañana a las 10:00.`
        : ''
    }`,
    confirmLabel: suspendido ? 'Levantar la suspensión' : 'Descongelar',
    placeholder: 'Acuerdo de pago por WhatsApp del 22/08',
    nivel: 'sensible',
  }
}

function DialogoDeEstado({
  user,
  destino,
  busy,
  error,
  onConfirm,
  onClose,
}: {
  user: UserDetail
  destino: ProfileStatus
  busy: boolean
  error: string | undefined
  onConfirm: (note: string) => void
  onClose: () => void
}) {
  const t = textosDeEstado(user, destino)
  return (
    <ConfirmDialog
      title={t.title}
      summary={t.summary}
      detail={t.detail}
      nivel={t.nivel}
      confirmWord={t.confirmWord}
      reasonPlaceholder={t.placeholder}
      confirmLabel={t.confirmLabel}
      danger={destino === 'suspended'}
      busy={busy}
      error={error}
      onConfirm={onConfirm}
      onClose={onClose}
    />
  )
}

/**
 * Cambiar el nivel a mano. El aviso compara el cupo nuevo con lo que ya tiene
 * ocupado, no con la deuda: la deuda lleva el service fee dentro y el
 * cupo no.
 */
function DialogoDeNivel({
  user,
  nuevo,
  level,
  busy,
  error,
  onConfirm,
  onClose,
}: {
  user: UserDetail
  nuevo: LevelConfig | undefined
  level: number
  busy: boolean
  error: string | undefined
  onConfirm: (note: string) => void
  onClose: () => void
}) {
  const cupoNuevo = nuevo?.monthlyLimitUsd ?? 0
  const ocupado =
    usoDelCupo(user.credit.levelLimitUsd, user.credit.availableNominalUsd)?.ocupadoUsd ?? 0

  return (
    <ConfirmDialog
      title="Cambiar el nivel a mano"
      summary={`${user.fullName ?? 'Este paciente'} pasa del nivel ${user.level} al ${level}: el cupo pasa de ${formatUsd(
        user.credit.levelLimitUsd,
      )} a ${formatUsd(cupoNuevo)}.`}
      detail={
        cupoNuevo < ocupado ? (
          <Callout tone="warning" titulo="El cupo nuevo es menor que lo que ya tiene ocupado">
            Tiene {formatUsd(ocupado)} ocupados: se queda sin disponible hasta que pague.
          </Callout>
        ) : undefined
      }
      nivel="sensible"
      reasonPlaceholder="Paciente de la clínica, con el aval del administrador"
      confirmLabel={`Pasar al nivel ${level}`}
      busy={busy}
      error={error}
      onConfirm={onConfirm}
      onClose={onClose}
    />
  )
}
