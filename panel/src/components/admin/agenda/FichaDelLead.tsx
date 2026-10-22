import { useState } from 'react'
import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { LucideIcon } from 'lucide-react'
import {
  BadgeCheck,
  CalendarCheck,
  CalendarClock,
  CalendarPlus,
  CalendarX,
  MapPin,
  MessageCircle,
  NotebookPen,
  Pencil,
  Phone,
  PhoneMissed,
  PhoneOff,
  Send,
  Sparkles,
  Store,
  ThumbsDown,
  ThumbsUp,
  Trash2,
  UserPlus,
  Video,
} from 'lucide-react'

import { useToast } from '@/components/Toast'
import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import {
  Badge,
  Button,
  Callout,
  Chip,
  ConfirmDialog,
  ErrorBox,
  Input,
  Menu,
  Modal,
  SkeletonList,
  Textarea,
  claseDeBoton,
  formatDateTime,
  formatDay,
  formatPhone,
  formatTime,
  whatsappNumber,
} from '@/components/ui'
import { MESES_CORTOS, sumarDias } from '@/components/kit/rango'
import { haceCuanto } from '@/features/admin/cobranza/senales'
import { anotarGestion, borrarLead, consultaHistoria, refrescarAgenda } from '@/features/admin/agenda/api'
import {
  ESTADO_DEL_LEAD,
  MODOS_DE_VISITA,
  NOTA_MAXIMA,
  RESPUESTAS,
  ROTULO_CANAL,
  ROTULO_MODO,
  ROTULO_RAZON,
  ROTULO_RESPUESTA,
  ROTULO_RESULTADO,
  ROTULO_VIA,
  SIN_ELEGIR,
  anulaLaVisita,
  borradorDeGestion,
  canalDe,
  diaDeCaracas,
  estadoDelResultado,
  motivoParaNoAnotar,
  pasoDelEmbudo,
  pideFechaDeVisita,
  pideVolver,
  resultadoDe,
  rotuloDelDia,
  tieneVisita,
  visitaSinResultado,
  volverPropuesto,
} from '@/features/admin/agenda/agenda'
import type {
  BorradorDeGestion,
  CanalDelLead,
  Eleccion,
  EstadoDelLead,
  Gestion,
  Lead,
  ModoDeVisita,
  Resultado,
  TipoDeGestion,
} from '@/features/admin/agenda/agenda'
import { describeError } from '@/lib/supabase'

const ENLACE =
  'inline-flex items-center gap-1 type-panel-caption text-on-surface-variant underline-offset-2 hover:text-on-surface hover:underline'

const ICONO_RESULTADO: Record<Resultado, LucideIcon> = {
  mensaje_enviado: Send,
  interesado: ThumbsUp,
  no_interesado: ThumbsDown,
  no_contesto: PhoneMissed,
  ocupado: PhoneOff,
  visita_agendada: CalendarPlus,
  visita_realizada: CalendarCheck,
  visita_pospuesta: CalendarClock,
  visita_cancelada: CalendarX,
  afiliado: BadgeCheck,
  nota: NotebookPen,
}

const ICONO_CANAL: Record<CanalDelLead, LucideIcon> = {
  mensaje: MessageCircle,
  llamada: Phone,
  whatsapp: MessageCircle,
  visita: MapPin,
  correo: Send,
  redes: Sparkles,
}

const ICONO_TIPO: Record<TipoDeGestion, LucideIcon> = {
  mensaje: MessageCircle,
  llamada: Phone,
  visita: CalendarClock,
}

const ROTULO_TIPO: Record<TipoDeGestion, string> = {
  mensaje: 'Mensaje',
  llamada: 'Llamada',
  visita: 'Visita',
}

const ICONO_MODO: Record<ModoDeVisita, LucideIcon> = {
  presencial: MapPin,
  videollamada: Video,
  llamada: Phone,
}

/** Lo que conviene contar según lo que pasó: el ejemplo de la nota. */
const EJEMPLO_DE_NOTA: Record<Resultado, string> = {
  mensaje_enviado: 'Qué se le mandó y por dónde.',
  interesado: '¿Qué le interesó? ¿Qué dudas tiene? ¿Cuántos pacientes ve al mes?',
  no_interesado: 'Por qué no le interesa, para no volver a llamarlo por lo mismo.',
  no_contesto: 'A qué hora se le intentó y si conviene probar por otro lado.',
  ocupado: 'A qué hora conviene volver a intentar.',
  visita_agendada: 'Quién va, qué llevar y qué quiere saber el médico.',
  visita_realizada: 'Cómo fue, qué le gustó y qué quedó pendiente.',
  visita_pospuesta: 'Por qué se movió.',
  visita_cancelada: 'Por qué se canceló y si quiere otra fecha.',
  afiliado: 'Cómo se cerró la afiliación.',
  nota: 'Lo que conviene que sepa el equipo.',
}

/** Los pasos del embudo, del primero al último (`pasoDelEmbudo`). */
const PASOS = ['Sin contactar', 'Contactado', 'Interesado', 'Visita', 'Afiliado']

/**
 * El enlace para añadir la visita al Google Calendar de quien va. Las fechas
 * van en UTC, como pide Google (`20261023T143000Z`), y dura una hora.
 */
function enlaceAGoogleCalendar(l: Lead): string | null {
  if (!l.reunion) return null
  const inicio = new Date(l.reunion)
  const fin = new Date(inicio.getTime() + 60 * 60 * 1000)
  const utc = (d: Date) => d.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '')
  const params = new URLSearchParams({
    action: 'TEMPLATE',
    text: `Helios · Visita a ${l.nombre}`,
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
 * La ficha de un médico por afiliar, de arriba abajo en el orden en que se
 * usa: quién es y en qué va (el embudo), cómo contactarlo (a un toque), qué
 * toca ahora (la visita o la llamada pendiente), anotar lo que pasó siguiendo
 * el árbol del equipo (mensaje, llamada o visita), y la historia.
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

  const quien = [lead.especialidad, lead.consultorio].filter(Boolean).join(' · ')

  return (
    <Modal title={lead.nombre} width="lg" onClose={onClose}>
      <div className="flex flex-col gap-5">
        <header className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <p className="type-panel-body text-on-surface">{quien || 'Sin especialidad ni consultorio'}</p>
            <p className="type-panel-caption text-on-surface-variant">
              Apuntado el {formatDay(lead.creado.slice(0, 10))}
              {lead.responsable ? ` · Gestionado por ${lead.responsable}` : ''}
            </p>
          </div>
          <div className="flex shrink-0 items-center gap-1">
            <Badge tone={ESTADO_DEL_LEAD[lead.estado].tone}>{ESTADO_DEL_LEAD[lead.estado].label}</Badge>
            <Menu
              etiqueta="Más acciones"
              items={[
                { label: 'Editar datos', icon: Pencil, onSelect: onEditar },
                'separador',
                { label: 'Eliminar de la agenda', icon: Trash2, peligro: true, onSelect: () => setBorrando(true) },
              ]}
            />
          </div>
        </header>

        <Embudo estado={lead.estado} />

        <Contacto lead={lead} />

        <ProximoPaso lead={lead} hoy={hoy} ahora={ahora} />

        <AnotarGestion key={`${lead.id}:${lead.estado}:${lead.reunion ?? ''}`} lead={lead} hoy={hoy} ahora={ahora} />

        <Historia leadId={lead.id} ahora={ahora} />
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

// ── En qué va ──────────────────────────────────────────────────────────────

/** El embudo en una tira: lo recorrido, en color, y el paso actual con su estado. */
function Embudo({ estado }: { estado: EstadoDelLead }) {
  const paso = pasoDelEmbudo(estado)
  const apagado = estado === 'descartado'
  return (
    <div aria-label={`En qué va: ${ESTADO_DEL_LEAD[estado].label}`}>
      <ol className="grid grid-cols-5 gap-1.5">
        {PASOS.map((p, i) => {
          const hecho = !apagado && i <= paso
          const actual = !apagado && i === paso
          return (
            <li key={p} className="flex min-w-0 flex-col gap-1.5">
              <span
                className={`h-1.5 rounded-full ${
                  hecho ? (estado === 'convertido' ? 'bg-success' : 'bg-primary') : 'bg-on-surface/10'
                }`}
              />
              <span
                className={`truncate type-panel-caption ${
                  actual ? 'font-semibold text-on-surface' : hecho ? 'text-on-surface-variant' : 'text-panel-muted'
                }`}
              >
                {actual ? ESTADO_DEL_LEAD[estado].label : p}
              </span>
            </li>
          )
        })}
      </ol>
    </div>
  )
}

// ── Cómo contactarlo ───────────────────────────────────────────────────────

/** Los botones para contactarlo, a un toque, y debajo su dirección y sus notas. */
function Contacto({ lead }: { lead: Lead }) {
  const wa = whatsappNumber(lead.telefono)
  const boton = claseDeBoton('tonal', 'sm')

  return (
    <section className="flex flex-col gap-2">
      {!lead.telefono && !lead.direccion ? (
        <p className="type-panel-body text-on-surface-variant">
          Sin teléfono ni dirección. Añádelos desde «⋯ › Editar datos».
        </p>
      ) : (
        <div className="flex flex-wrap gap-2">
          {lead.telefono && wa && (
            <a href={`tel:+${wa}`} className={boton}>
              <Phone size={15} aria-hidden /> Llamar
              <span className="tabular-nums text-on-surface-variant">{formatPhone(lead.telefono)}</span>
            </a>
          )}
          {wa && (
            <a href={`https://wa.me/${wa}`} target="_blank" rel="noreferrer" className={boton}>
              <MessageCircle size={15} aria-hidden /> WhatsApp
            </a>
          )}
          {lead.direccion && (
            <a href={enlaceAlMapa(lead.direccion)} target="_blank" rel="noreferrer" className={boton}>
              <MapPin size={15} aria-hidden /> Cómo llegar
            </a>
          )}
        </div>
      )}
      {lead.direccion && <p className="type-panel-caption text-on-surface-variant">{lead.direccion}</p>}
      {lead.notas && (
        <p className="whitespace-pre-line rounded-panel-control bg-panel-raised px-3 py-2 type-panel-body text-on-surface">
          {lead.notas}
        </p>
      )}
    </section>
  )
}

// ── Qué toca ahora ─────────────────────────────────────────────────────────

/** Una tarjeta con lo próximo: la visita, la llamada pendiente o la afiliación. */
function ProximoPaso({ lead, hoy, ahora }: { lead: Lead; hoy: string; ahora: Date }) {
  if (lead.estado === 'convertido') {
    return (
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
    )
  }

  if (tieneVisita(lead) && lead.reunion) {
    const dia = diaDeCaracas(lead.reunion)
    const paso = visitaSinResultado(lead, ahora)
    const calendario = enlaceAGoogleCalendar(lead)
    const IconoModo = lead.modo ? ICONO_MODO[lead.modo] : CalendarClock
    return (
      <Tarjeta
        tono={paso ? 'error' : dia === hoy ? 'warning' : 'brand'}
        fecha={dia}
        titulo={`Visita: ${rotuloDelDia(dia, hoy).toLowerCase()}, ${formatTime(lead.reunion)}`}
        subtitulo={
          paso ? (
            'La hora ya pasó: anota abajo si se realizó, se pospuso o se canceló.'
          ) : (
            <span className="inline-flex items-center gap-1">
              <IconoModo size={13} aria-hidden />
              {[lead.modo ? ROTULO_MODO[lead.modo] : null, lead.lugar].filter(Boolean).join(' · ')}
            </span>
          )
        }
        accion={
          calendario && !paso ? (
            <a href={calendario} target="_blank" rel="noreferrer" className={claseDeBoton('outlined', 'sm')}>
              <CalendarPlus size={14} aria-hidden /> Google Calendar
            </a>
          ) : null
        }
      />
    )
  }

  if (lead.estado === 'descartado') {
    return (
      <p className="type-panel-caption text-on-surface-variant">
        No le interesa. Si cambia de idea, anota abajo lo que pasó y vuelve al embudo.
      </p>
    )
  }

  if (lead.volverEl) {
    const atrasado = lead.volverEl < hoy
    return (
      <Tarjeta
        tono={atrasado ? 'error' : lead.volverEl === hoy ? 'warning' : 'neutral'}
        fecha={lead.volverEl}
        titulo={`Volver a llamar: ${rotuloDelDia(lead.volverEl, hoy).toLowerCase()}`}
        subtitulo={atrasado ? 'Se pasó la fecha.' : 'Lo anotó la última gestión.'}
      />
    )
  }

  if (lead.estado === 'visitado') {
    return (
      <Tarjeta
        tono="neutral"
        icono={CalendarCheck}
        titulo="Visita realizada"
        subtitulo="Falta que se afilie: anota si se afilió o cuándo volver a llamarlo."
      />
    )
  }

  if (lead.estado === 'nuevo') {
    return (
      <Tarjeta
        tono="warning"
        icono={UserPlus}
        titulo="Falta el primer contacto"
        subtitulo="Escríbele o llámalo, y anota abajo qué pasó."
      />
    )
  }

  return null
}

const TONO_TARJETA = {
  brand: 'border-primary/30 bg-primary/6',
  warning: 'border-warning/40 bg-warning/8',
  error: 'border-error/40 bg-error/8',
  neutral: 'border-panel-hairline bg-panel-raised',
} as const

function Tarjeta({
  tono,
  fecha,
  icono: Icono,
  titulo,
  subtitulo,
  accion,
}: {
  tono: keyof typeof TONO_TARJETA
  /** 'YYYY-MM-DD': se pinta como una hoja de calendario. */
  fecha?: string
  icono?: LucideIcon
  titulo: string
  subtitulo: ReactNode
  accion?: ReactNode
}) {
  return (
    <section className={`flex flex-wrap items-center gap-3 rounded-panel-card border px-4 py-3 ${TONO_TARJETA[tono]}`}>
      {fecha ? (
        <span className="flex w-12 shrink-0 flex-col items-center overflow-hidden rounded-panel-control border border-panel-hairline bg-panel-card">
          <span className="w-full bg-on-surface/6 py-0.5 text-center type-panel-caption uppercase text-on-surface-variant">
            {MESES_CORTOS[Number(fecha.slice(5, 7)) - 1]}
          </span>
          <span className="py-0.5 type-panel-section tabular-nums text-on-surface">{Number(fecha.slice(8, 10))}</span>
        </span>
      ) : Icono ? (
        <span className="flex size-10 shrink-0 items-center justify-center rounded-full bg-panel-card text-on-surface-variant">
          <Icono size={18} aria-hidden />
        </span>
      ) : null}
      <div className="min-w-44 flex-1">
        <p className="type-panel-body font-semibold text-on-surface">{titulo}</p>
        <p className="type-panel-caption text-on-surface-variant">{subtitulo}</p>
      </div>
      {accion}
    </section>
  )
}

// ── Anotar lo que pasó ─────────────────────────────────────────────────────

/** Para elegir un día sin teclear la fecha. */
function atajosDeVolver(hoy: string): Array<{ label: string; dia: string }> {
  return [
    { label: 'Mañana', dia: sumarDias(hoy, 1) },
    { label: 'En 3 días', dia: sumarDias(hoy, 3) },
    { label: 'En una semana', dia: sumarDias(hoy, 7) },
  ]
}

/**
 * Anotar una gestión siguiendo el árbol del equipo: primero por dónde fue
 * (mensaje, llamada o visita), después qué pasó y, si contestó, si le
 * interesa. Solo entonces aparece lo que ese resultado pide —la fecha de la
 * visita, cuándo volver a llamar— con la nota al final.
 */
function AnotarGestion({ lead, hoy, ahora }: { lead: Lead; hoy: string; ahora: Date }) {
  const client = useQueryClient()
  const avisar = useToast()
  const [eleccion, setEleccion] = useState<Eleccion>(SIN_ELEGIR)
  const [borrador, setBorrador] = useState(() => borradorDeGestion(lead))

  const conVisita = tieneVisita(lead)
  const resultado = resultadoDe(eleccion, conVisita)

  const anotar = useMutation({
    mutationFn: ({ r, b }: { r: Resultado; b: BorradorDeGestion }) => anotarGestion(lead.id, r, canalDe(eleccion), b),
    onSuccess: (_, { r }) => {
      refrescarAgenda(client)
      avisar(`${ROTULO_RESULTADO[r]}: anotado.`)
      setEleccion(SIN_ELEGIR)
      setBorrador(borradorDeGestion(lead))
    },
  })

  function cambiar(parte: Partial<BorradorDeGestion>) {
    setBorrador((b) => ({ ...b, ...parte }))
  }

  /** Elige una rama y propone lo que el resultado suele llevar. */
  function elegir(e: Eleccion) {
    setEleccion(e)
    const r = resultadoDe(e, conVisita)
    if (r === null) return
    const dias = volverPropuesto(r)
    cambiar({
      // Una nota no mueve la llamada pendiente.
      volverEl: r === 'nota' ? (lead.volverEl ?? '') : dias !== null ? sumarDias(hoy, dias) : '',
      visitaDia: r === 'visita_pospuesta' ? '' : borrador.visitaDia,
    })
  }

  const bloqueo = resultado ? motivoParaNoAnotar(resultado, borrador, lead, hoy) : undefined
  const anula = anulaLaVisita(resultado, lead, ahora)
  const visitaPasada = visitaSinResultado(lead, ahora)

  return (
    <section className="flex flex-col gap-4 rounded-panel-card border border-panel-hairline p-4">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h3 className="type-panel-section text-on-surface">Anotar gestión</h3>
        <div className="flex gap-1">
          <Chip selected={eleccion.tipo === 'afiliado'} onClick={() => elegir({ ...SIN_ELEGIR, tipo: 'afiliado' })}>
            <BadgeCheck size={14} aria-hidden /> Se afilió
          </Chip>
          <Chip selected={eleccion.tipo === 'nota'} onClick={() => elegir({ ...SIN_ELEGIR, tipo: 'nota' })}>
            <NotebookPen size={14} aria-hidden /> Solo una nota
          </Chip>
        </div>
      </div>

      <div className="grid grid-cols-3 gap-2">
        {(['mensaje', 'llamada', 'visita'] as const).map((t) => {
          const Icono = ICONO_TIPO[t]
          const elegido = eleccion.tipo === t
          const ayuda =
            t === 'visita'
              ? conVisita && lead.reunion
                ? `La del ${formatDateTime(lead.reunion)}`
                : 'Agendar con fecha'
              : t === 'mensaje'
                ? 'WhatsApp o SMS'
                : 'Por teléfono'
          return (
            <button
              key={t}
              type="button"
              aria-pressed={elegido}
              onClick={() => elegir({ ...SIN_ELEGIR, tipo: t })}
              className={`flex flex-col items-start gap-1 rounded-panel-control border px-3 py-2.5 text-left transition-colors ${
                elegido
                  ? 'border-primary bg-primary/8 ring-1 ring-primary'
                  : t === 'visita' && visitaPasada
                    ? 'border-error/50 bg-error/6 hover:bg-error/10'
                    : 'border-panel-hairline hover:border-panel-hairline-strong hover:bg-panel-raised'
              }`}
            >
              <Icono size={18} aria-hidden className={elegido ? 'text-primary' : 'text-on-surface-variant'} />
              <span className="type-panel-control text-on-surface">{ROTULO_TIPO[t]}</span>
              <span className="truncate type-panel-caption text-on-surface-variant">{ayuda}</span>
            </button>
          )
        })}
      </div>

      {eleccion.tipo !== null && (
        <div className="flex flex-col gap-4 border-t border-panel-hairline pt-4">
          {(eleccion.tipo === 'mensaje' || eleccion.tipo === 'llamada' || (eleccion.tipo === 'visita' && conVisita)) && (
            <Fila etiqueta={eleccion.tipo === 'visita' ? 'La visita' : 'Qué pasó'}>
              {RESPUESTAS[eleccion.tipo].map((r) => (
                <Chip
                  key={r}
                  selected={eleccion.respuesta === r}
                  onClick={() => elegir({ ...eleccion, respuesta: r, interesado: null })}
                >
                  {ROTULO_RESPUESTA[r]}
                </Chip>
              ))}
            </Fila>
          )}

          {eleccion.respuesta === 'contesto' && (
            <Fila etiqueta="¿Le interesa?">
              <Chip selected={eleccion.interesado === true} onClick={() => elegir({ ...eleccion, interesado: true })}>
                <ThumbsUp size={14} aria-hidden /> Interesado
              </Chip>
              <Chip selected={eleccion.interesado === false} onClick={() => elegir({ ...eleccion, interesado: false })}>
                <ThumbsDown size={14} aria-hidden /> No interesado
              </Chip>
              {eleccion.interesado === true && !conVisita && (
                <button
                  type="button"
                  className="ml-1 type-panel-caption text-primary underline-offset-2 hover:underline"
                  onClick={() => elegir({ ...SIN_ELEGIR, tipo: 'visita' })}
                >
                  ¿Ya quedaron en una visita? Agéndala
                </button>
              )}
            </Fila>
          )}

          {pideFechaDeVisita(resultado) && (
            <>
              <Fila etiqueta={resultado === 'visita_pospuesta' ? 'Nueva fecha' : 'Fecha'}>
                {[
                  { label: 'Hoy', dia: hoy },
                  { label: 'Mañana', dia: sumarDias(hoy, 1) },
                  { label: 'Pasado mañana', dia: sumarDias(hoy, 2) },
                ].map((a) => (
                  <Chip key={a.label} selected={borrador.visitaDia === a.dia} onClick={() => cambiar({ visitaDia: a.dia })}>
                    {a.label}
                  </Chip>
                ))}
                <Input
                  id="agenda-visita-dia"
                  type="date"
                  min={hoy}
                  value={borrador.visitaDia}
                  onChange={(visitaDia) => cambiar({ visitaDia })}
                  className="w-44"
                />
                <Input
                  id="agenda-visita-hora"
                  type="time"
                  value={borrador.visitaHora}
                  onChange={(visitaHora) => cambiar({ visitaHora })}
                  className="w-32"
                />
              </Fila>
              <Fila etiqueta="Cómo">
                {MODOS_DE_VISITA.map((m) => {
                  const Icono = ICONO_MODO[m]
                  return (
                    <Chip key={m} selected={borrador.modo === m} onClick={() => cambiar({ modo: m })}>
                      <Icono size={14} aria-hidden /> {ROTULO_MODO[m]}
                    </Chip>
                  )
                })}
              </Fila>
              <Input
                id="agenda-visita-lugar"
                label={borrador.modo === 'videollamada' ? 'Enlace (opcional)' : 'Dónde (opcional)'}
                value={borrador.lugar}
                placeholder={borrador.modo === 'videollamada' ? 'https://meet.google.com/…' : 'Su consultorio'}
                onChange={(lugar) => cambiar({ lugar })}
              />
            </>
          )}

          {resultado && pideVolver(resultado) && (
            <Fila etiqueta="Volver a llamar">
              {atajosDeVolver(hoy).map((a) => (
                <Chip key={a.label} selected={borrador.volverEl === a.dia} onClick={() => cambiar({ volverEl: a.dia })}>
                  {a.label}
                </Chip>
              ))}
              <Input
                id="agenda-volver"
                type="date"
                min={hoy}
                value={borrador.volverEl}
                onChange={(volverEl) => cambiar({ volverEl })}
                className="w-44"
              />
              <Chip selected={borrador.volverEl === ''} onClick={() => cambiar({ volverEl: '' })}>
                Sin fecha
              </Chip>
            </Fila>
          )}

          {resultado && (
            <Textarea
              id="agenda-nota"
              label={resultado === 'nota' ? 'Nota' : 'Nota (opcional)'}
              rows={2}
              maxLength={NOTA_MAXIMA}
              value={borrador.nota}
              placeholder={EJEMPLO_DE_NOTA[resultado]}
              onChange={(nota) => cambiar({ nota })}
            />
          )}

          {anula && lead.reunion && (
            <Callout
              tone="warning"
              titulo={
                resultado === 'visita_cancelada'
                  ? `Se cancela la visita del ${formatDateTime(lead.reunion)}`
                  : `Se anula la visita del ${formatDateTime(lead.reunion)}`
              }
            >
              {resultado === 'visita_cancelada'
                ? 'El médico queda como interesado, sin visita.'
                : 'Para dejar solo un comentario, usa «Solo una nota».'}
            </Callout>
          )}

          {anotar.isError && <ErrorBox title="No se pudo anotar" detail={describeError(anotar.error)} />}

          <div className="flex flex-wrap items-center justify-end gap-3">
            {resultado && (
              <span className="mr-auto inline-flex items-center gap-1.5 type-panel-caption text-on-surface-variant">
                Queda como
                <Badge tone={ESTADO_DEL_LEAD[estadoDelResultado(resultado, lead)].tone}>
                  {ESTADO_DEL_LEAD[estadoDelResultado(resultado, lead)].label}
                </Badge>
              </span>
            )}
            {bloqueo && <span className="type-panel-caption text-on-surface-variant">{bloqueo}</span>}
            <Button size="sm" variant="text" onClick={() => setEleccion(SIN_ELEGIR)}>
              Cancelar
            </Button>
            <Button
              size="md"
              disabled={resultado === null || !!bloqueo || anotar.isPending}
              onClick={() => {
                if (resultado && !bloqueo) anotar.mutate({ r: resultado, b: borrador })
              }}
            >
              {anotar.isPending ? 'Guardando…' : 'Guardar'}
            </Button>
          </div>
        </div>
      )}
    </section>
  )
}

/** Un rótulo a la izquierda y sus opciones en fila. */
function Fila({ etiqueta, children }: { etiqueta: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-1.5 sm:flex-row sm:items-center sm:gap-3">
      <span className="w-32 shrink-0 type-panel-label text-on-surface-variant">{etiqueta}</span>
      <div className="flex flex-wrap items-center gap-1.5">{children}</div>
    </div>
  )
}

// ── La historia ────────────────────────────────────────────────────────────

function iconoDeGestion(h: Gestion): LucideIcon {
  if (h.tipo === 'creado') return UserPlus
  if (h.tipo === 'conversion') return BadgeCheck
  if (h.resultado) return ICONO_RESULTADO[h.resultado]
  if (h.canal) return ICONO_CANAL[h.canal]
  return NotebookPen
}

/** Lo que dice una línea: el resultado, o (en las de antes del árbol) el cambio de estado. */
function queDice(h: Gestion): ReactNode {
  if (h.tipo === 'creado') return 'Lo apuntó en la agenda'
  if (h.resultado) {
    const deLaVisita =
      h.reunion && (h.resultado === 'visita_agendada' || h.resultado === 'visita_pospuesta')
        ? ` para el ${formatDateTime(h.reunion)}`
        : h.reunion && (h.resultado === 'visita_realizada' || h.resultado === 'visita_cancelada')
          ? ` (la del ${formatDateTime(h.reunion)})`
          : ''
    return (
      <>
        <span className="font-semibold">{ROTULO_RESULTADO[h.resultado]}</span>
        {deLaVisita && <span className="text-on-surface-variant">{deLaVisita}</span>}
      </>
    )
  }
  if (h.despues && h.antes !== h.despues) {
    return (
      <>
        {h.antes && <span className="text-on-surface-variant">{ESTADO_DEL_LEAD[h.antes].label} → </span>}
        <span className="font-semibold">{ESTADO_DEL_LEAD[h.despues].label}</span>
      </>
    )
  }
  return <span className="text-on-surface-variant">{h.canal ? ROTULO_CANAL[h.canal] : 'Nota'}</span>
}

function Historia({ leadId, ahora }: { leadId: string; ahora: Date }) {
  const historia = useQuery(consultaHistoria(leadId))

  return (
    <section className="flex flex-col gap-3">
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
        <ol className="relative flex flex-col gap-4 before:absolute before:top-2 before:bottom-2 before:left-[13px] before:w-px before:bg-panel-hairline">
          {historia.data.map((h) => {
            const Icono = iconoDeGestion(h)
            return (
              <li key={h.id} className="relative flex gap-3">
                <span className="z-10 flex size-7 shrink-0 items-center justify-center rounded-full border border-panel-hairline bg-panel-card text-on-surface-variant">
                  <Icono size={14} aria-hidden />
                </span>
                <div className="min-w-0 flex-1 pt-0.5">
                  <p className="type-panel-body text-on-surface">{queDice(h)}</p>
                  {h.nota && <p className="mt-0.5 whitespace-pre-line type-panel-body text-on-surface">{h.nota}</p>}
                  <p className="mt-0.5 type-panel-caption text-on-surface-variant" title={formatDateTime(h.cuando)}>
                    {haceCuanto(h.cuando, ahora)} · {h.quien ?? 'Helios'}
                    {h.canal && h.resultado ? ` · ${ROTULO_CANAL[h.canal]}` : ''}
                  </p>
                </div>
              </li>
            )
          })}
        </ol>
      )}
    </section>
  )
}
