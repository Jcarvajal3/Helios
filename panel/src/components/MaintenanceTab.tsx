import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Card,
  ConfirmDialog,
  DataLabel,
  ErrorBox,
  Input,
  Seccion,
  Segmented,
  SkeletonCard,
  formatDateTime,
} from '@/components/ui'
import { fetchMaintenance, setMaintenance } from '@/features/admin/maintenance'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

/** Lo mismo que exige `admin_set_maintenance` al encender. */
const TITULO_MINIMO = 3
const MENSAJE_MINIMO = 10

type Alcance = 'saldo' | 'aviso'

const ALCANCES: Array<{ value: Alcance; label: string }> = [
  { value: 'saldo', label: 'Parar las órdenes nuevas' },
  { value: 'aviso', label: 'Solo el aviso' },
]

/**
 * El freno de emergencia.
 *
 * Para las órdenes nuevas en todas las clínicas (panel y bot, por
 * `helios_spend_block`) y enseña el aviso que se escriba aquí en el panel de
 * las clínicas. Encenderlo pasa por el diálogo crítico con la vista previa del
 * aviso. No para registrar ni aprobar pagos (20260909160000).
 */
export function MaintenanceTab() {
  const client = useQueryClient()
  const avisar = useToast()
  const isSuperAdmin = useIsSuperAdmin()
  const query = useQuery({ queryKey: ['maintenance'], queryFn: fetchMaintenance })

  const [title, setTitle] = useState('')
  const [message, setMessage] = useState('')
  const [expected, setExpected] = useState('')
  const [alcance, setAlcance] = useState<Alcance>('saldo')
  const [loaded, setLoaded] = useState(false)
  const [encendiendo, setEncendiendo] = useState(false)

  // Se siembra una sola vez con lo guardado. Sin la guarda, cada refetch
  // pisaría lo que se está escribiendo, y esto se escribe con prisa.
  if (query.data && !loaded) {
    setTitle(query.data.title)
    setMessage(query.data.message)
    setExpected(query.data.expectedBack ?? '')
    setAlcance(query.data.blocksBalance ? 'saldo' : 'aviso')
    setLoaded(true)
  }

  // Solo encender pasa por el diálogo; su motivo va a la bitácora.
  const save = useMutation({
    mutationFn: ({ isActive, nota }: { isActive: boolean; nota: string | null }) =>
      setMaintenance({
        isActive,
        note: nota,
        blocksBalance: alcance === 'saldo',
        title: title.trim(),
        message: message.trim(),
        expectedBack: expected.trim() || undefined,
      }),
    onSuccess: (m, { isActive }) => {
      const estabaEncendido = query.data?.isActive ?? false
      avisar(
        !isActive
          ? 'El mantenimiento está apagado. Las clínicas vuelven a registrar pagos en cuotas con normalidad.'
          : estabaEncendido
            ? 'El aviso del mantenimiento está actualizado.'
            : m.blocksBalance
              ? 'El mantenimiento está encendido: nadie puede pagar en cuotas y todos ven el aviso en la siguiente carga.'
              : 'El mantenimiento está encendido: las clínicas ven el aviso en la siguiente carga y pueden seguir registrando órdenes.',
      )
      setEncendiendo(false)
      void client.invalidateQueries({ queryKey: ['maintenance'] })
    },
  })

  if (query.isLoading) return <SkeletonCard />
  if (query.isError) {
    return (
      <ErrorBox title="No se pudo leer el mantenimiento" detail={describeError(query.error)} />
    )
  }

  const on = query.data?.isActive ?? false
  const bloquea = alcance === 'saldo'

  const faltaTexto =
    title.trim().length < TITULO_MINIMO
      ? `El título necesita al menos ${TITULO_MINIMO} caracteres.`
      : message.trim().length < MENSAJE_MINIMO
        ? `Explica qué pasa en al menos ${MENSAJE_MINIMO} caracteres: es lo único que la gente va a leer.`
        : undefined
  const motivoTexto = !isSuperAdmin ? SOLO_SUPER_ADMIN : faltaTexto
  const motivoApagar = !isSuperAdmin ? SOLO_SUPER_ADMIN : undefined

  const vistaPrevia = (
    <>
      <p className="type-panel-body font-semibold text-on-surface">
        {title.trim() || 'Estamos en mantenimiento'}
      </p>
      <p className="mt-1 type-panel-body text-on-surface-variant">
        {message.trim() || 'Escribe arriba qué está pasando.'}
        {expected.trim() ? ` Volvemos ${expected.trim()}.` : ''}
      </p>
    </>
  )

  return (
    <Seccion
      titulo="Mantenimiento"
      info="El freno de emergencia. Con las órdenes nuevas paradas ninguna clínica puede registrar pagos en cuotas (ni por el panel ni por el bot), y el aviso sale en el panel en la siguiente carga. Registrar y aprobar los pagos de los pacientes sigue funcionando, para no crear atrasos a quien tiene una cuota que vence ese día."
      controles={
        on ? (
          <>
            {query.data?.startedAt && (
              <span className="type-panel-caption text-panel-muted">
                desde el {formatDateTime(query.data.startedAt)}
              </span>
            )}
            <Badge tone={query.data?.blocksBalance ? 'error' : 'warning'} icono>
              {query.data?.blocksBalance ? 'Encendido, con las órdenes nuevas paradas' : 'Encendido, solo el aviso'}
            </Badge>
          </>
        ) : (
          <Badge tone="success" icono>
            Apagado
          </Badge>
        )
      }
      className="max-w-3xl"
    >
      <Card className="flex flex-col gap-4">
        <Input
          id="mnt-title"
          label="Título"
          value={title}
          onChange={setTitle}
          placeholder="Estamos en mantenimiento"
        />
        <Input
          id="mnt-message"
          label="Qué pasa"
          value={message}
          onChange={setMessage}
          placeholder="Estamos resolviendo un problema. Podrás registrar pagos en cuotas en cuanto terminemos."
        />
        <Input
          id="mnt-expected"
          label="Cuándo volvemos (opcional, en texto libre)"
          value={expected}
          onChange={setExpected}
          placeholder="hoy a las 10 PM"
        />

        <div className="flex flex-col gap-shell-gap-stack border-t border-panel-hairline pt-4">
          <DataLabel>Qué apaga</DataLabel>
          <Segmented etiqueta="Qué apaga" options={ALCANCES} value={alcance} onChange={setAlcance} />
          {/* Escrito: es lo que decide si la gente puede consumir esta noche. */}
          <p className="type-panel-caption text-on-surface-variant">
            {bloquea
              ? 'Nadie puede pagar en cuotas hasta que se apague.'
              : 'El aviso sale, pero todos pueden seguir pagando en cuotas: para un mantenimiento programado o una caída parcial.'}
          </p>
        </div>
      </Card>

      <Card tone="inset">
        <DataLabel>Lo que verá el paciente en Inicio</DataLabel>
        <div className="mt-2">{vistaPrevia}</div>
      </Card>

      {save.isError && !encendiendo && (
        <ErrorBox title="No se pudo guardar" detail={describeError(save.error)} />
      )}

      <div className="flex flex-wrap items-start gap-3">
        {on ? (
          <>
            <Button
              size="md"
              disabled={save.isPending || !isSuperAdmin}
              motivoApagado={motivoApagar}
              onClick={() => save.mutate({ isActive: false, nota: null })}
            >
              {save.isPending ? 'Guardando…' : 'Apagar el mantenimiento'}
            </Button>
            <Button
              size="md"
              variant="tonal"
              disabled={save.isPending || motivoTexto !== undefined}
              motivoApagado={motivoTexto}
              onClick={() => save.mutate({ isActive: true, nota: null })}
            >
              Actualizar el aviso
            </Button>
          </>
        ) : (
          // En rojo, y es la excepción a «nada destructivo a la vista»: esta
          // pantalla EXISTE para esto, es la única acción que tiene y para a
          // todos los usuarios. El lima diría «adelante». El diálogo crítico
          // pide además la palabra y el motivo.
          <Button
            variant="danger"
            size="md"
            disabled={motivoTexto !== undefined}
            motivoApagado={motivoTexto}
            onClick={() => setEncendiendo(true)}
          >
            Encender el mantenimiento
          </Button>
        )}
      </div>

      {encendiendo && (
        <ConfirmDialog
          nivel="critico"
          title="Encender el mantenimiento"
          summary={
            bloquea
              ? 'Las clínicas verán este aviso y no podrán registrar pagos en cuotas hasta que se apague.'
              : 'Las clínicas verán este aviso. Se siguen pudiendo registrar pagos en cuotas.'
          }
          detail={
            <div className="flex flex-col gap-3">
              {vistaPrevia}
              <p className="type-panel-caption text-on-surface-variant">
                Pagar y reportar un pago siguen funcionando.
              </p>
            </div>
          }
          reasonPlaceholder="Caída del proveedor de pagos"
          confirmLabel="Encender"
          busy={save.isPending}
          error={save.isError ? describeError(save.error) : undefined}
          onConfirm={(nota) => save.mutate({ isActive: true, nota })}
          onClose={() => setEncendiendo(false)}
        />
      )}
    </Seccion>
  )
}
