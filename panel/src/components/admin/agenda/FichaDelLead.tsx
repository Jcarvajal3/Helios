import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { CalendarPlus, MapPin, NotebookPen, Pencil, Store, Trash2 } from 'lucide-react'

import { useToast } from '@/components/Toast'
import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { TelefonoConAcciones } from '@/components/admin/seguimiento/Contacto'
import { EstadoDelLeadBadge } from '@/components/admin/agenda/columnas'
import {
  Button,
  Callout,
  ConfirmDialog,
  ErrorBox,
  Input,
  Modal,
  Select,
  SkeletonList,
  Textarea,
  formatDateTime,
  formatDay,
} from '@/components/ui'
import { anotarGestion, borrarLead, consultaHistoria, refrescarAgenda } from '@/features/admin/agenda/api'
import {
  CANALES_DEL_LEAD,
  ESTADOS_DEL_LEAD,
  ESTADO_DEL_LEAD,
  MODOS_DE_REUNION,
  NOTA_MAXIMA,
  ROTULO_CANAL,
  ROTULO_MODO,
  ROTULO_ORIGEN,
  ROTULO_RAZON,
  ROTULO_VIA,
  anulaLaReunion,
  borradorDeGestion,
  motivoParaNoAnotar,
  reunionSinResultado,
} from '@/features/admin/agenda/agenda'
import type { BorradorDeGestion, CanalDelLead, EstadoDelLead, Lead } from '@/features/admin/agenda/agenda'
import { describeError } from '@/lib/supabase'

const OPCIONES_ESTADO = ESTADOS_DEL_LEAD.map((value) => ({ value, label: ESTADO_DEL_LEAD[value].label }))
const OPCIONES_CANAL: Array<{ value: CanalDelLead | 'ninguno'; label: string }> = [
  ...CANALES_DEL_LEAD.map((value) => ({ value, label: ROTULO_CANAL[value] })),
  { value: 'ninguno', label: 'Sin contacto (solo una nota)' },
]
const OPCIONES_MODO = MODOS_DE_REUNION.map((value) => ({ value, label: ROTULO_MODO[value] }))

const ENLACE =
  'inline-flex items-center gap-1 type-panel-caption text-on-surface-variant underline-offset-2 hover:text-on-surface hover:underline'

/** Lo que conviene contar según el estado al que se pasa: el ejemplo de la nota. */
const EJEMPLO_DE_NOTA: Record<EstadoDelLead, string> = {
  nuevo: 'Algo sobre el médico que conviene saber antes de llamarlo.',
  contactado: 'Con quién se habló (el médico, la secretaria) y qué se le contó de Helios.',
  respondio: '¿Qué le interesó? ¿Qué dudas tiene? ¿Cuántos pacientes ve al mes?',
  no_respondio: 'Cuántas veces se le llamó y a qué hora conviene volver a intentar.',
  reunion: 'Quién va, qué llevar y qué quiere saber el médico.',
  convertido: 'Cómo se cerró la afiliación.',
  descartado: 'Por qué no le interesa, para no volver a llamarlo por lo mismo.',
}

/**
 * El enlace para añadir la reunión al Google Calendar de quien va. Las fechas
 * van en UTC, como pide Google (`20261023T143000Z`), y dura una hora.
 */
function enlaceAGoogleCalendar(l: Lead): string | null {
  if (!l.reunion) return null
  const inicio = new Date(l.reunion)
  const fin = new Date(inicio.getTime() + 60 * 60 * 1000)
  const utc = (d: Date) => d.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '')
  const params = new URLSearchParams({
    action: 'TEMPLATE',
    text: `Helios · Reunión con ${l.nombre}`,
    dates: `${utc(inicio)}/${utc(fin)}`,
    details: [l.consultorio, l.telefono, l.notas].filter(Boolean).join('\n'),
    location: l.lugar ?? l.direccion ?? '',
  })
  return `https://calendar.google.com/calendar/render?${params.toString()}`
}

function enlaceAlMapa(direccion: string): string {
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(direccion)}`
}

/**
 * La ficha de un médico por afiliar: sus datos y cómo contactarlo, su
 * reunión, su afiliación si ya llegó, anotar una gestión y toda su historia.
 */
export function FichaDelLead({
  lead,
  hoy,
  ahora,
  onEditar,
  onClose,
}: {
  lead: Lead
  hoy: string
  ahora: Date
  onEditar: () => void
  onClose: () => void
}) {
  const client = useQueryClient()
  const avisar = useToast()
  const [borrando, setBorrando] = useState(false)

  const borrar = useMutation({
    mutationFn: () => borrarLead(lead.id),
    onSuccess: () => {
      refrescarAgenda(client)
      avisar(`${lead.nombre} ya no está en la agenda.`)
      onClose()
    },
  })

  const calendario = enlaceAGoogleCalendar(lead)
  const direccion = [lead.direccion, lead.ciudad].filter(Boolean).join(', ')

  return (
    <Modal title={lead.nombre} width="lg" onClose={onClose}>
      <div className="flex flex-col gap-6">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="type-panel-body text-on-surface-variant">
            <p className="text-on-surface">
              {[lead.especialidad, lead.consultorio].filter(Boolean).join(' · ') || 'Sin especialidad ni consultorio'}
            </p>
            <p className="type-panel-caption">
              {lead.origen ? `${ROTULO_ORIGEN[lead.origen]} · ` : ''}
              Apuntado el {formatDay(lead.creado.slice(0, 10))}
              {lead.responsable ? ` · Lo lleva ${lead.responsable}` : ''}
            </p>
          </div>
          <div className="flex flex-col items-end gap-2">
            <EstadoDelLeadBadge lead={lead} hoy={hoy} ahora={ahora} />
            <div className="flex gap-1">
              <Button size="sm" variant="text" onClick={onEditar}>
                <Pencil size={14} aria-hidden /> Editar
              </Button>
              <Button size="sm" variant="text" onClick={() => setBorrando(true)}>
                <Trash2 size={14} aria-hidden /> Eliminar
              </Button>
            </div>
          </div>
        </div>

        <section className="flex flex-col gap-2">
          <h3 className="type-panel-label text-on-surface-variant">Datos de contacto</h3>
          <dl className="grid gap-x-6 gap-y-2 type-panel-body sm:grid-cols-[max-content_1fr]">
            <dt className="text-on-surface-variant">Teléfono</dt>
            <dd>
              {lead.telefono ? (
                <TelefonoConAcciones telefono={lead.telefono} nombre={lead.nombre} conWaMe />
              ) : (
                '—'
              )}
            </dd>
            <dt className="text-on-surface-variant">Correo</dt>
            <dd>{lead.correo ? <a href={`mailto:${lead.correo}`} className="hover:underline">{lead.correo}</a> : '—'}</dd>
            <dt className="text-on-surface-variant">Dirección</dt>
            <dd>
              {direccion ? (
                <a href={enlaceAlMapa(direccion)} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 hover:underline">
                  <MapPin size={14} aria-hidden /> {direccion}
                </a>
              ) : (
                '—'
              )}
            </dd>
          </dl>
          {lead.notas && <p className="whitespace-pre-line type-panel-body text-on-surface">{lead.notas}</p>}
        </section>

        {lead.estado === 'convertido' && (
          <Callout tone="success" titulo="Afiliado">
            {lead.via ? ROTULO_VIA[lead.via] : 'Afiliado'}
            {lead.razon ? ` (se le reconoció ${ROTULO_RAZON[lead.razon]})` : ''}
            {lead.afiliadoEl ? ` el ${formatDateTime(lead.afiliadoEl)}` : ''}.
            {lead.clinicaId && (
              <>
                {' '}
                <Link to="/admin/clinicas/$id" params={{ id: lead.clinicaId }} className={ENLACE}>
                  <Store size={13} aria-hidden /> {lead.clinica ?? 'Abrir la clínica'}
                </Link>
              </>
            )}
            {!lead.clinicaId && lead.solicitudEstado === 'pending' && (
              <>
                {' '}
                <Link to="/admin/clinicas" search={{ estado: 'pendiente' }} className={ENLACE}>
                  Su solicitud está por revisar
                </Link>
              </>
            )}
          </Callout>
        )}

        {lead.reunion && (
          <section className="flex flex-wrap items-center justify-between gap-3 rounded-panel-card border border-panel-hairline px-4 py-3">
            <div className="type-panel-body">
              <p className="text-on-surface">
                {lead.estado === 'reunion' ? 'Reunión' : 'Última reunión'}: {formatDateTime(lead.reunion)}
              </p>
              <p className="type-panel-caption text-on-surface-variant">
                {lead.modo ? ROTULO_MODO[lead.modo] : 'Reunión'}
                {lead.lugar ? ` · ${lead.lugar}` : ''}
              </p>
            </div>
            {calendario && lead.estado === 'reunion' && !reunionSinResultado(lead, ahora) && (
              <a href={calendario} target="_blank" rel="noreferrer" className={ENLACE}>
                <CalendarPlus size={14} aria-hidden /> Añadir a Google Calendar
              </a>
            )}
          </section>
        )}

        <AnotarGestion key={`${lead.id}:${lead.estado}:${lead.reunion ?? ''}`} lead={lead} hoy={hoy} ahora={ahora} />

        <Historia leadId={lead.id} />
      </div>

      {borrando && (
        <ConfirmDialog
          title="Eliminar de la agenda"
          summary={`Vas a borrar a ${lead.nombre} y toda su historia (${lead.gestiones} ${lead.gestiones === 1 ? 'línea' : 'líneas'}). Sus datos quedan en la bitácora.`}
          confirmLabel="Eliminar"
          danger
          busy={borrar.isPending}
          error={borrar.isError ? describeError(borrar.error) : undefined}
          onConfirm={() => borrar.mutate()}
          onClose={() => setBorrando(false)}
        />
      )}
    </Modal>
  )
}

function AnotarGestion({ lead, hoy, ahora }: { lead: Lead; hoy: string; ahora: Date }) {
  const client = useQueryClient()
  const avisar = useToast()
  const [borrador, setBorrador] = useState(() => borradorDeGestion(lead))

  const anotar = useMutation({
    mutationFn: (b: BorradorDeGestion) => anotarGestion(lead, b),
    onSuccess: () => {
      refrescarAgenda(client)
      avisar(`Gestión con ${lead.nombre} anotada.`)
    },
  })

  function cambiar(parte: Partial<BorradorDeGestion>) {
    setBorrador((b) => ({ ...b, ...parte }))
  }

  const bloqueo = motivoParaNoAnotar(borrador, lead, hoy, ahora)
  const anula = anulaLaReunion(borrador, lead, ahora)
  const enReunion = borrador.estado === 'reunion'

  return (
    <section className="flex flex-col gap-3 rounded-panel-card bg-panel-raised p-4">
      <h3 className="type-panel-label text-on-surface-variant">Anotar una gestión</h3>
      <div className="grid gap-3 sm:grid-cols-2">
        <Select
          id="agenda-estado"
          label="Queda en"
          value={borrador.estado}
          options={OPCIONES_ESTADO}
          onChange={(estado) => cambiar({ estado })}
        />
        <Select
          id="agenda-canal"
          label="Por dónde"
          value={borrador.canal || 'ninguno'}
          options={OPCIONES_CANAL}
          onChange={(v) => cambiar({ canal: v === 'ninguno' ? '' : v })}
        />
      </div>

      {enReunion && (
        <div className="grid gap-3 sm:grid-cols-[1fr_8rem_1fr]">
          <Input
            id="agenda-reunion-dia"
            label="Día de la reunión"
            type="date"
            min={hoy}
            value={borrador.reunionDia}
            onChange={(reunionDia) => cambiar({ reunionDia })}
          />
          <Input
            id="agenda-reunion-hora"
            label="Hora"
            type="time"
            value={borrador.reunionHora}
            onChange={(reunionHora) => cambiar({ reunionHora })}
          />
          <Select
            id="agenda-reunion-modo"
            label="Cómo"
            value={borrador.modo}
            options={OPCIONES_MODO}
            onChange={(modo) => cambiar({ modo })}
          />
          <Input
            id="agenda-reunion-lugar"
            label={borrador.modo === 'videollamada' ? 'Enlace (opcional)' : 'Dónde (opcional)'}
            value={borrador.lugar}
            placeholder={borrador.modo === 'videollamada' ? 'https://meet.google.com/…' : 'Su consultorio'}
            onChange={(lugar) => cambiar({ lugar })}
            className="sm:col-span-3"
          />
        </div>
      )}

      <Textarea
        id="agenda-nota"
        label="Qué pasó (opcional)"
        rows={3}
        maxLength={NOTA_MAXIMA}
        value={borrador.nota}
        placeholder={EJEMPLO_DE_NOTA[borrador.estado]}
        onChange={(nota) => cambiar({ nota })}
      />

      {anula && lead.reunion && (
        <Callout tone="warning" titulo={`Se anula la reunión del ${formatDateTime(lead.reunion)}`}>
          Si solo quieres dejar una nota, deja «Reunión agendada».
        </Callout>
      )}

      <div className="flex flex-wrap items-end justify-between gap-3">
        {borrador.estado === 'convertido' || borrador.estado === 'descartado' ? (
          <span />
        ) : (
          <Input
            id="agenda-volver"
            label="Volver a llamar el (opcional)"
            type="date"
            min={hoy}
            value={borrador.volverEl}
            onChange={(volverEl) => cambiar({ volverEl })}
            className="w-56"
          />
        )}
        <Button
          size="sm"
          disabled={!!bloqueo || anotar.isPending}
          title={bloqueo}
          onClick={() => {
            if (!bloqueo) anotar.mutate(borrador)
          }}
        >
          <NotebookPen size={15} aria-hidden /> {anotar.isPending ? 'Anotando…' : 'Anotar'}
        </Button>
      </div>
      {bloqueo && borrador.estado === 'reunion' && (
        <p className="type-panel-caption text-on-surface-variant">{bloqueo}</p>
      )}
      {anotar.isError && <ErrorBox title="No se pudo anotar" detail={describeError(anotar.error)} />}
    </section>
  )
}

function Historia({ leadId }: { leadId: string }) {
  const historia = useQuery(consultaHistoria(leadId))

  return (
    <section className="flex flex-col gap-2">
      <h3 className="type-panel-label text-on-surface-variant">Historia</h3>
      {historia.isPending && <SkeletonList rows={3} />}
      {historia.isError && (
        <ErrorConReintento
          title="No se pudo leer la historia"
          error={historia.error}
          onReintentar={() => void historia.refetch()}
        />
      )}
      {historia.isSuccess && historia.data.length > 0 && (
        <ol className="flex flex-col gap-3">
          {historia.data.map((h) => (
            <li key={h.id} className="border-l-2 border-panel-hairline-strong pl-3">
              <p className="type-panel-caption text-on-surface-variant">
                {formatDateTime(h.cuando)} · {h.quien ?? 'Helios'}
                {h.canal ? ` · ${ROTULO_CANAL[h.canal]}` : ''}
              </p>
              <p className="type-panel-body text-on-surface">
                {h.tipo === 'creado' && 'Lo apuntó en la agenda.'}
                {h.tipo !== 'creado' && h.despues && h.antes !== h.despues && (
                  <>
                    {h.antes ? `${ESTADO_DEL_LEAD[h.antes].label} → ` : ''}
                    <strong className="font-medium">{ESTADO_DEL_LEAD[h.despues].label}</strong>
                    {h.reunion ? `, el ${formatDateTime(h.reunion)}` : ''}
                  </>
                )}
                {h.tipo !== 'creado' && h.despues === 'reunion' && h.antes === 'reunion' && h.reunion && (
                  <>Reunión el {formatDateTime(h.reunion)}</>
                )}
              </p>
              {h.nota && <p className="whitespace-pre-line type-panel-body text-on-surface">{h.nota}</p>}
            </li>
          ))}
        </ol>
      )}
    </section>
  )
}
