import { ChevronDown } from 'lucide-react'

import { AccionesDeFicha, ResumenDeFicha } from '@/components/admin/ficha'
import type { CifraDeFicha } from '@/components/admin/ficha'
import type { BloqueoDeCuenta } from '@/components/UserBlockCard'
import {
  Button,
  Menu,
  Meter,
  NoSePudoLeer,
  SOLO_SUPER_ADMIN,
  SkeletonBlock,
  formatUsd,
  formatPorcentaje,
} from '@/components/ui'
import { POR_QUE_NO_PUEDE_GASTAR, usoDelCupo } from '@/features/admin/directorio/cupo'
import { desgloseQueCuadra } from '@/features/admin/desgloseDeCuotas'
import { textoDeDesgloseCorto } from '@/features/admin/metricas/formato'
import type { LevelConfig } from '@/features/admin/ops'
import type { UserDetail } from '@/features/admin/users'
import { accionesDeEstado } from './accionesDeCuenta'
import type { AccionDeCuenta } from './accionesDeCuenta'

/**
 * El carril de la ficha de un paciente: lo que debe y lo que puede financiar,
 * y las acciones de todos los días.
 *
 * Son las dos primeras preguntas de cualquier llamada —«¿cuánto debo?» y
 * «¿por qué no puedo pagar con Ronda?»— y se ven desde todas las pestañas.
 */
export function CarrilPersona({
  user,
  niveles,
  cuenta,
  bloqueo,
}: {
  user: UserDetail
  niveles: { datos: Array<LevelConfig> | undefined; error: boolean; reintentar: () => void }
  cuenta: { abrir: (accion: AccionDeCuenta) => void; apagado: boolean }
  bloqueo: BloqueoDeCuenta
}) {
  return (
    <>
      <ResumenDeFicha cifras={cifrasDePersona(user)} />
      <AccionesDeCuenta user={user} niveles={niveles} cuenta={cuenta} bloqueo={bloqueo} />
    </>
  )
}

/**
 * Las dos cifras. La deuda en cuotas lleva el service fee dentro, repartido en
 * sus cuotas, y por eso va con su desglose debajo; el cupo y el disponible
 * van sin él.
 */
function cifrasDePersona(user: UserDetail): Array<CifraDeFicha> {
  const { credit, debt } = user
  const uso = usoDelCupo(credit.levelLimitUsd, credit.availableNominalUsd)
  const motivo = credit.availableBlockedReason
  const vencido = debt.overdueUsd > 0
  // Las cuotas sin pagar (sin las perdidas, que no son deuda viva), partidas
  // en consumo y fee, si suman la deuda de hoy. Lo vencido, igual: es payable
  // y va con sus sumandos.
  const vivas = user.installments.filter((i) => i.status === 'pending' && !i.writtenOffAt)
  const partes = desgloseQueCuadra(vivas, debt.openUsd)
  const partesVencidas = desgloseQueCuadra(
    vivas.filter((i) => i.daysOverdue > 0),
    debt.overdueUsd,
  )
  const perdido =
    debt.writtenOffUsd !== null && debt.writtenOffUsd > 0 && debt.writtenOffFinancedUsd !== null
      ? {
          payableUsd: debt.writtenOffUsd,
          financedUsd: debt.writtenOffFinancedUsd,
          feeUsd: Math.round((debt.writtenOffUsd - debt.writtenOffFinancedUsd) * 100) / 100,
        }
      : null

  const deuda: CifraDeFicha = {
    label: 'Deuda en cuotas (financiamiento + fee)',
    value: formatUsd(debt.openUsd),
    info: 'Suma de sus cuotas sin pagar, vencidas y por vencer, en financiamiento + service fee (IVA incluido); debajo, sus dos partes y lo vencido. Sin cargos por atraso ni cuotas perdidas (si las hay, van aparte debajo).',
    senal: vencido
      ? {
          tone: 'error',
          texto: `${debt.daysOverdue} ${debt.daysOverdue === 1 ? 'día' : 'días'} de atraso`,
        }
      : undefined,
    hint: [
      partes ? textoDeDesgloseCorto(partes) : null,
      vencido
        ? `vencido ${formatUsd(debt.overdueUsd)}${partesVencidas ? ` (${textoDeDesgloseCorto(partesVencidas)})` : ''}`
        : partes
          ? 'nada vencido'
          : 'Nada vencido',
      // Lo perdido ya no es deuda viva, pero no se esconde: va aparte y
      // con sus dos partes (es payable).
      perdido ? `aparte, perdido ${formatUsd(perdido.payableUsd)} (${textoDeDesgloseCorto(perdido)})` : null,
    ]
      .filter(Boolean)
      .join(' · '),
  }

  // La cifra es la de la app: con una cuota vencida, la cuenta sin activar o
  // un bloqueo es cero aunque le quede cupo, y la línea de debajo dice por qué.
  const disponible: CifraDeFicha =
    user.level === 0 || !uso
      ? { label: 'Disponible hoy', value: 'Sin cupo', hint: 'Todavía no tiene nivel' }
      : {
          label: 'Disponible hoy',
          value: formatUsd(credit.availableNowUsd),
          info: 'Límite del nivel menos el financiamiento (sin fee) de sus financiamientos con alguna cuota sin pagar, o cero con una cuota vencida, la cuenta no activa o un bloqueo: lo que una clínica vería como disponible; el cupo de cada financiamiento vuelve al pagar sus dos cuotas.',
          senal: motivo ? { tone: 'error', texto: 'No puede gastar' } : undefined,
          visual: (
            <Meter
              valor={uso.proporcion}
              tono={uso.proporcion >= 1 ? 'warning' : 'area'}
              rotulo={`Cupo en uso: ${formatPorcentaje(Math.round(uso.proporcion * 100))}`}
            />
          ),
          hint: motivo
            ? POR_QUE_NO_PUEDE_GASTAR[motivo]
            : `De ${formatUsd(credit.levelLimitUsd)} de cupo · ${formatUsd(uso.ocupadoUsd)} ocupados`,
        }

  return [deuda, disponible]
}

/**
 * El nivel, el estado de todos los días y la marca de prueba. Suspender,
 * marcar, bloquear y expulsar van en el «⋯» de la cabecera.
 */
function AccionesDeCuenta({
  user,
  niveles,
  cuenta,
  bloqueo,
}: {
  user: UserDetail
  niveles: { datos: Array<LevelConfig> | undefined; error: boolean; reintentar: () => void }
  cuenta: { abrir: (accion: AccionDeCuenta) => void; apagado: boolean }
  bloqueo: BloqueoDeCuenta
}) {
  const { abrir, apagado } = cuenta
  const puede = accionesDeEstado(user.status)
  const title = apagado ? SOLO_SUPER_ADMIN : undefined

  return (
    <AccionesDeFicha
      info="Todas piden motivo y quedan en la bitácora con el valor de antes y el de después. Congelar lo levanta el estado automático cada mañana si no hay cuotas vencidas. El nivel cambia el cupo en el momento. Una cuenta de prueba deja de contar en las cifras y en las colas."
      aviso={apagado ? 'Son del super admin: desde tu cuenta se consultan, pero no se aplican.' : undefined}
    >
      <CambiarNivel user={user} niveles={niveles} apagado={apagado} abrir={abrir} />

      {puede.reactivar ? (
        <Button
          size="sm"
          variant="tonal"
          disabled={apagado}
          title={title}
          onClick={() => abrir({ tipo: 'estado', destino: 'active' })}
        >
          {puede.reactivar}
        </Button>
      ) : (
        puede.congelar && (
          <Button
            size="sm"
            variant="tonal"
            disabled={apagado}
            title={title}
            onClick={() => abrir({ tipo: 'estado', destino: 'frozen' })}
          >
            Congelar
          </Button>
        )
      )}

      {bloqueo.estado === 'abierto' && (
        <Button size="sm" variant="tonal" disabled={apagado} title={title} onClick={bloqueo.levantar}>
          Levantar el bloqueo
        </Button>
      )}

      <Button
        size="sm"
        variant="tonal"
        disabled={apagado}
        title={title}
        onClick={() => abrir({ tipo: 'prueba' })}
      >
        {user.isTest ? 'Ya no es de prueba' : 'Marcar como prueba'}
      </Button>
    </AccionesDeFicha>
  )
}

/**
 * El nivel a mano, en un desplegable: seis botones en fila no caben en el
 * carril, y el nivel actual en lima parecía la acción principal. Cada nivel
 * abre su diálogo con el cupo de antes y el de después.
 */
function CambiarNivel({
  user,
  niveles,
  apagado,
  abrir,
}: {
  user: UserDetail
  niveles: { datos: Array<LevelConfig> | undefined; error: boolean; reintentar: () => void }
  apagado: boolean
  abrir: (accion: AccionDeCuenta) => void
}) {
  if (niveles.error) return <NoSePudoLeer onReintentar={niveles.reintentar} />
  if (!niveles.datos) return <SkeletonBlock className="h-panel-control-sm w-36" />

  return (
    <Menu
      etiqueta="Cambiar el nivel"
      disparador={
        <>
          Cambiar el nivel <ChevronDown size={14} aria-hidden />
        </>
      }
      items={niveles.datos.map((l) => ({
        label: `${l.label} · ${formatUsd(l.monthlyLimitUsd)}`,
        onSelect: () => abrir({ tipo: 'nivel', level: l.level }),
        disabled: apagado || l.level === user.level,
        motivoApagado: apagado ? SOLO_SUPER_ADMIN : l.level === user.level ? 'Es su nivel actual' : undefined,
      }))}
    />
  )
}
