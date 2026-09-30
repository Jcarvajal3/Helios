import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { BellRing, MessageCircle, Play, X } from 'lucide-react'

import { ENLACE_EN_CELDA } from '@/components/DataTable'
import { useAtajos } from '@/components/admin/ModoCola'
import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Card,
  ConfirmDialog,
  EmptyState,
  FilterBar,
  Input,
  NoSePudoLeer,
  Seccion,
  SkeletonList,
  Tecla,
  claseDeBoton,
  diaOperativo,
  formatDay,
  formatPhone,
  formatTime,
} from '@/components/ui'
import { CLAVE_AVISOS, consultaColaDeAvisos, marcarAviso } from '@/features/admin/avisos/api'
import {
  ESTADO_AVISO,
  agruparPorPlantilla,
  colaDeTrabajo,
  contarAvisos,
  enlaceWhatsApp,
} from '@/features/admin/avisos/avisos'
import type { Aviso, EstadoAviso } from '@/features/admin/avisos/avisos'
import { describeError } from '@/lib/supabase'

/**
 * «Avisos de hoy» (plan §7.2): la cola de mensajes de WhatsApp que generaron
 * los crons, agrupada por plantilla. Cada aviso lleva su texto ya escrito,
 * «Abrir WhatsApp» (wa.me con el texto), «Enviado» y «Omitir».
 *
 * «Empezar» abre el modo cola: un aviso a la vez, con teclas, para vaciar
 * la cola rápido. Marcar como enviado deja la gestión en la cobranza del
 * paciente (canal WhatsApp).
 */
export function AvisosDeHoy({
  dia,
  enCola,
  onDia,
  onCola,
}: {
  dia: string | undefined
  enCola: boolean
  onDia: (dia: string | undefined) => void
  onCola: (enCola: boolean) => void
}) {
  const hoy = diaOperativo()
  const elDia = dia ?? hoy
  const cola = useQuery(consultaColaDeAvisos(elDia))
  const [omitiendo, setOmitiendo] = useState<Aviso | null>(null)
  const marcar = useMarcarAviso()

  const avisos = cola.data ?? []
  const recuento = contarAvisos(avisos)
  const grupos = agruparPorPlantilla(avisos)
  const pendientes = colaDeTrabajo(avisos)

  return (
    <>
      <FilterBar>
        <Input
          id="avisos-dia"
          label="Día"
          type="date"
          value={elDia}
          max={hoy}
          onChange={(v) => onDia(v && v !== hoy ? v : undefined)}
          className="w-44"
        />
        {cola.data && (
          <p className="self-end pb-2 type-panel-body text-on-surface-variant">
            {recuento.pendiente} por mandar · {recuento.enviado} enviados · {recuento.omitido} omitidos
            {recuento.fallido > 0 && ` · ${recuento.fallido} fallidos`}
          </p>
        )}
        <div className="ml-auto self-end">
          <Button size="md" disabled={pendientes.length === 0} onClick={() => onCola(true)}>
            <Play size={14} aria-hidden /> Empezar la cola
          </Button>
        </div>
      </FilterBar>

      {cola.isPending && <SkeletonList rows={5} />}
      {cola.isError && (
        <Card>
          <NoSePudoLeer onReintentar={() => void cola.refetch()} />
        </Card>
      )}

      {cola.data && avisos.length === 0 && (
        <EmptyState
          icon={<BellRing size={40} />}
          title={elDia === hoy ? 'Hoy no hay avisos' : `El ${formatDay(elDia)} no hubo avisos`}
          description="Los generan solos los recordatorios de cada cuota (víspera, día del vencimiento, +1 y +4 días), la bienvenida y los pagos aprobados o rechazados."
        />
      )}

      {enCola && pendientes.length > 0 ? (
        <ModoColaDeAvisos
          pendientes={pendientes}
          onOmitir={setOmitiendo}
          onMarcar={(a) => marcar.mutate({ aviso: a, estado: 'enviado', nota: '' })}
          marcando={marcar.isPending}
          onSalir={() => onCola(false)}
        />
      ) : (
        grupos.map((g) => (
          <Seccion
            key={g.clave}
            titulo={`${g.rotulo} · ${g.pendientes} por mandar`}
            info={`${g.avisos.length} ${g.avisos.length === 1 ? 'aviso' : 'avisos'} con la plantilla «${g.clave}».`}
          >
            <div className="flex flex-col gap-2">
              {g.avisos.map((a) => (
                <FilaDeAviso
                  key={a.id}
                  aviso={a}
                  ocupado={marcar.isPending && marcar.variables.aviso.id === a.id}
                  onEnviado={() => marcar.mutate({ aviso: a, estado: 'enviado', nota: '' })}
                  onOmitir={() => setOmitiendo(a)}
                />
              ))}
            </div>
          </Seccion>
        ))
      )}

      {enCola && cola.data && pendientes.length === 0 && (
        <Card>
          <p className="type-panel-body text-on-surface">No queda ningún aviso por mandar. ¡Cola vacía!</p>
          <Button className="mt-3" size="sm" variant="tonal" onClick={() => onCola(false)}>
            Volver a la lista
          </Button>
        </Card>
      )}

      {marcar.isError && !omitiendo && (
        <p className="type-panel-caption text-error">No se pudo marcar: {describeError(marcar.error)}</p>
      )}

      {omitiendo && (
        <ConfirmDialog
          title="Omitir el aviso"
          summary={`El aviso «${omitiendo.templateLabel}» a ${omitiendo.patientName ?? 'este paciente'} no se manda.`}
          nivel="sensible"
          reasonLabel="Por qué no se manda"
          reasonPlaceholder="Ya pagó por transferencia y está por aprobarse"
          confirmLabel="Omitir"
          busy={marcar.isPending}
          error={marcar.isError ? describeError(marcar.error) : undefined}
          onConfirm={(nota) =>
            marcar.mutate(
              { aviso: omitiendo, estado: 'omitido', nota },
              { onSuccess: () => setOmitiendo(null) },
            )
          }
          onClose={() => {
            setOmitiendo(null)
            marcar.reset()
          }}
        />
      )}
    </>
  )
}

/** Marcar un aviso, refrescando la cola, los contadores y la cobranza del paciente. */
function useMarcarAviso() {
  const client = useQueryClient()
  const avisar = useToast()
  return useMutation({
    mutationFn: (p: { aviso: Aviso; estado: EstadoAviso; nota: string }) =>
      marcarAviso({ id: p.aviso.id, estado: p.estado, nota: p.nota }),
    onSuccess: (_, p) => {
      avisar(
        p.estado === 'enviado'
          ? `Aviso a ${p.aviso.patientName ?? 'el paciente'} marcado como enviado`
          : `Aviso a ${p.aviso.patientName ?? 'el paciente'} omitido`,
      )
      void client.invalidateQueries({ queryKey: CLAVE_AVISOS })
      if (p.aviso.profileId) {
        void client.invalidateQueries({ queryKey: ['admin-contacts', p.aviso.profileId] })
        void client.invalidateQueries({ queryKey: ['admin-collections'] })
      }
    },
  })
}

function Paciente({ aviso }: { aviso: Aviso }) {
  return aviso.profileId ? (
    <Link
      to="/admin/pacientes/$id"
      params={{ id: aviso.profileId }}
      search={{ tab: 'cobranza' }}
      className={`type-panel-body font-semibold ${ENLACE_EN_CELDA}`}
    >
      {aviso.patientName ?? 'Sin nombre'}
    </Link>
  ) : (
    <span className="type-panel-body font-semibold text-on-surface">{aviso.patientName ?? 'Sin nombre'}</span>
  )
}

function Detalles({ aviso }: { aviso: Aviso }) {
  return (
    <p className="type-panel-caption text-on-surface-variant">
      {aviso.phone ? formatPhone(aviso.phone) : 'Sin teléfono'}
      {aviso.dueDate && ` · cuota del ${formatDay(aviso.dueDate)}`}
      {aviso.orderNumber !== null && ` · #${aviso.orderNumber}`}
      {aviso.sentAt &&
        ` · ${aviso.status === 'omitido' ? 'omitido' : 'enviado'} a las ${formatTime(aviso.sentAt)}${aviso.sentByName ? ` por ${aviso.sentByName}` : ''}`}
    </p>
  )
}

function BotonWhatsApp({ aviso, principal = false }: { aviso: Aviso; principal?: boolean }) {
  const href = enlaceWhatsApp(aviso.phone, aviso.renderedText)
  if (!href) return <Badge tone="warning">Sin teléfono</Badge>
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer"
      className={`whitespace-nowrap ${claseDeBoton(principal ? 'filled' : 'tonal', 'sm')}`}
    >
      <MessageCircle size={14} aria-hidden /> Abrir WhatsApp
    </a>
  )
}

/** Un aviso en la lista: quién, cuándo vence, el texto y los tres botones. */
function FilaDeAviso({
  aviso,
  ocupado,
  onEnviado,
  onOmitir,
}: {
  aviso: Aviso
  ocupado: boolean
  onEnviado: () => void
  onOmitir: () => void
}) {
  const [abierto, setAbierto] = useState(false)
  const pendiente = aviso.status === 'pendiente' || aviso.status === 'fallido'
  const estado = ESTADO_AVISO[aviso.status]

  return (
    <Card tone={pendiente ? 'default' : 'inset'}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <Paciente aviso={aviso} />
            <Badge tone={estado.tone}>{estado.label}</Badge>
          </div>
          <Detalles aviso={aviso} />
          <button
            type="button"
            onClick={() => setAbierto((v) => !v)}
            aria-expanded={abierto}
            className={`mt-2 block w-full text-left type-panel-body text-on-surface-variant ${abierto ? 'whitespace-pre-wrap' : 'line-clamp-2'}`}
          >
            {aviso.renderedText || 'Sin texto'}
          </button>
        </div>
        {pendiente && (
          <div className="flex flex-wrap items-start gap-2">
            <BotonWhatsApp aviso={aviso} />
            <Button size="sm" disabled={ocupado} onClick={onEnviado}>
              Enviado
            </Button>
            <Button size="sm" variant="text" disabled={ocupado} onClick={onOmitir}>
              Omitir
            </Button>
          </div>
        )}
      </div>
    </Card>
  )
}

/**
 * El modo cola: un aviso a la vez, en grande, para vaciar la cola con el
 * teclado. W (o Enter) abre WhatsApp, E lo marca enviado y pasa al
 * siguiente, O pide la nota para omitirlo, J y K se mueven, Esc sale.
 *
 * Los enviados salen de la cola al refrescarse; mientras tanto se avanza a
 * mano al siguiente para no esperar a la base.
 */
function ModoColaDeAvisos({
  pendientes,
  onMarcar,
  onOmitir,
  marcando,
  onSalir,
}: {
  pendientes: Aviso[]
  onMarcar: (a: Aviso) => void
  onOmitir: (a: Aviso) => void
  marcando: boolean
  onSalir: () => void
}) {
  const [indice, setIndice] = useState(0)
  const i = Math.min(indice, pendientes.length - 1)
  const actual = pendientes.at(i)
  const href = actual ? enlaceWhatsApp(actual.phone, actual.renderedText) : null

  function abrir() {
    if (href) window.open(href, '_blank', 'noopener,noreferrer')
  }
  function enviado() {
    if (!actual || marcando) return
    onMarcar(actual)
    // La base lo saca de la cola; el que queda en este puesto es el siguiente.
    if (i >= pendientes.length - 1) setIndice(Math.max(0, i - 1))
  }
  const siguiente = () => setIndice((n) => Math.min(n + 1, pendientes.length - 1))
  const anterior = () => setIndice((n) => Math.max(n - 1, 0))

  useAtajos({
    w: abrir,
    Enter: abrir,
    e: enviado,
    o: () => actual && onOmitir(actual),
    j: siguiente,
    ArrowRight: siguiente,
    k: anterior,
    ArrowLeft: anterior,
    Escape: onSalir,
  })

  if (!actual) return null

  return (
    <Card className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p aria-live="polite" className="type-panel-body tabular-nums text-on-surface-variant">
          <span className="text-on-surface">{i + 1}</span> de {pendientes.length} por mandar ·{' '}
          <span className="text-on-surface">{actual.templateLabel}</span>
        </p>
        <Button size="sm" variant="text" onClick={onSalir}>
          <X size={14} aria-hidden /> Salir de la cola <Tecla enBoton>Esc</Tecla>
        </Button>
      </div>

      <div>
        <Paciente aviso={actual} />
        <Detalles aviso={actual} />
      </div>

      <p className="whitespace-pre-wrap rounded-panel-control bg-panel-raised p-4 type-panel-body text-on-surface">
        {actual.renderedText || 'Sin texto'}
      </p>

      <div className="flex flex-wrap items-center gap-2">
        {href ? (
          <a href={href} target="_blank" rel="noreferrer" className={claseDeBoton('filled', 'md')}>
            <MessageCircle size={16} aria-hidden /> Abrir WhatsApp <Tecla enBoton>W</Tecla>
          </a>
        ) : (
          <Badge tone="warning">Sin teléfono: no se puede abrir el chat</Badge>
        )}
        <Button size="md" variant="tonal" disabled={marcando} onClick={enviado}>
          Enviado <Tecla enBoton>E</Tecla>
        </Button>
        <Button size="md" variant="text" onClick={() => onOmitir(actual)}>
          Omitir <Tecla enBoton>O</Tecla>
        </Button>
        <span className="ml-auto flex gap-2">
          <Button size="sm" variant="tonal" disabled={i === 0} onClick={anterior}>
            Anterior <Tecla enBoton>K</Tecla>
          </Button>
          <Button size="sm" variant="tonal" disabled={i >= pendientes.length - 1} onClick={siguiente}>
            Siguiente <Tecla enBoton>J</Tecla>
          </Button>
        </span>
      </div>
    </Card>
  )
}
