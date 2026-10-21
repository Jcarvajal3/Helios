import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { NotebookPen, Store } from 'lucide-react'

import { useToast } from '@/components/Toast'
import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { TelefonoConAcciones } from '@/components/admin/seguimiento/Contacto'
import {
  Badge,
  Button,
  ErrorBox,
  Input,
  Modal,
  Select,
  SkeletonList,
  Textarea,
  diaOperativo,
  formatDateTime,
  formatDay,
} from '@/components/ui'
import { anotarSeguimiento, consultaHistoria, refrescarSeguimiento } from '@/features/admin/seguimiento/api'
import {
  CANALES_DE_SEGUIMIENTO,
  ESTADO_DEL_SEGUIMIENTO,
  MOTIVOS_DE_SEGUIMIENTO,
  NOTA_MAXIMA,
  ROTULO_CANAL_DE_SEGUIMIENTO,
  ROTULO_MOTIVO,
  borradorDeSeguimiento,
  contactablesDe,
  estadoDelSeguimiento,
  motivoParaNoAnotarSeguimiento,
} from '@/features/admin/seguimiento/seguimiento'
import type {
  BorradorDeSeguimiento,
  ClinicaEnSeguimiento,
  MotivoDeSeguimiento,
} from '@/features/admin/seguimiento/seguimiento'
import { describeError } from '@/lib/supabase'

const OPCIONES_CANAL = CANALES_DE_SEGUIMIENTO.map((value) => ({ value, label: ROTULO_CANAL_DE_SEGUIMIENTO[value] }))
const OPCIONES_MOTIVO = MOTIVOS_DE_SEGUIMIENTO.map((value) => ({ value, label: ROTULO_MOTIVO[value] }))

/** Lo que conviene preguntar según el motivo: el ejemplo del campo de la nota. */
const EJEMPLO_DE_NOTA: Record<MotivoDeSeguimiento, string> = {
  seguimiento: '¿Cuántos pacientes le han preguntado por las cuotas? ¿La secretaria ya registra sola?',
  opinion: '¿Qué le gusta? ¿Qué le cuesta? ¿Qué le dicen sus pacientes? ¿Lo recomendaría a un colega?',
  soporte: 'Qué no le funcionó, en qué paso, y qué se le dijo o quedó pendiente.',
  capacitacion: 'A quién se le enseñó, qué se practicó (panel o bot) y qué quedó por ver.',
}

/** El valor del selector «Con quién» para el teléfono del consultorio. */
const CONSULTORIO = 'consultorio'

/**
 * La ficha de seguimiento de una clínica: a quién llamar y a qué número,
 * anotar lo que se habló y la historia de todos los contactos.
 *
 * `conQuien` llega puesto cuando se abre desde la fila de una persona.
 */
export function FichaDeSeguimiento({
  clinica,
  conQuien,
  onClose,
}: {
  clinica: ClinicaEnSeguimiento
  conQuien?: string
  onClose: () => void
}) {
  const [hoy] = useState(() => diaOperativo(new Date()))
  const estado = ESTADO_DEL_SEGUIMIENTO[estadoDelSeguimiento(clinica, hoy)]
  const contactables = contactablesDe(clinica)

  return (
    <Modal title={clinica.nombre} width="lg" onClose={onClose}>
      <div className="flex flex-col gap-6">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="type-panel-body text-on-surface-variant">
            <p className="text-on-surface">{clinica.medico ?? 'Sin médico titular'}</p>
            <p className="type-panel-caption">
              {[clinica.especialidad, clinica.ciudad, clinica.correo].filter(Boolean).join(' · ') || '—'}
            </p>
            <p className="type-panel-caption">
              {clinica.confirmadas30d} órdenes en 30 días · {clinica.confirmadas} desde el alta
            </p>
          </div>
          <div className="flex flex-col items-end gap-2">
            <Badge tone={estado.tone}>
              {estado.label}
              {clinica.volverEl ? ` · ${formatDay(clinica.volverEl)}` : ''}
            </Badge>
            <Link
              to="/admin/clinicas/$id"
              params={{ id: clinica.id }}
              className="inline-flex items-center gap-1 type-panel-caption text-on-surface-variant underline-offset-2 hover:text-on-surface hover:underline"
            >
              <Store size={13} aria-hidden /> Abrir la ficha de la clínica
            </Link>
          </div>
        </div>

        <section className="flex flex-col gap-2">
          <h3 className="type-panel-label text-on-surface-variant">A quién llamar</h3>
          {contactables.length === 0 ? (
            <p className="type-panel-body text-on-surface-variant">
              Ni la clínica ni su personal tienen teléfono. Se corrige en la ficha de la clínica.
            </p>
          ) : (
            <ul className="divide-y divide-panel-hairline rounded-panel-card border border-panel-hairline">
              {contactables.map((c) => {
                const persona = clinica.personal.find((p) => p.userId === c.userId)
                return (
                  <li key={c.userId ?? CONSULTORIO} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2">
                    <span>
                      <span className="text-on-surface">{c.nombre}</span>
                      <span className="type-panel-caption text-on-surface-variant">
                        {' '}
                        · {c.rol}
                        {persona ? ` · ${persona.confirmadas} ${persona.confirmadas === 1 ? 'orden' : 'órdenes'}` : ''}
                      </span>
                    </span>
                    <TelefonoConAcciones telefono={c.telefono} nombre={c.nombre} conWaMe />
                  </li>
                )
              })}
            </ul>
          )}
        </section>

        <AnotarContacto clinica={clinica} conQuienInicial={conQuien} hoy={hoy} />

        <Historia merchantId={clinica.id} />
      </div>
    </Modal>
  )
}

function AnotarContacto({
  clinica,
  conQuienInicial,
  hoy,
}: {
  clinica: ClinicaEnSeguimiento
  conQuienInicial?: string
  hoy: string
}) {
  const client = useQueryClient()
  const avisar = useToast()
  const [borrador, setBorrador] = useState(() =>
    borradorDeSeguimiento({ conQuien: conQuienInicial ?? '' }),
  )

  const anotar = useMutation({
    mutationFn: (b: BorradorDeSeguimiento) => anotarSeguimiento(clinica.id, b),
    onSuccess: () => {
      refrescarSeguimiento(client)
      avisar(`Contacto con ${clinica.nombre} anotado.`)
      setBorrador(borradorDeSeguimiento())
    },
  })

  function cambiar(parte: Partial<BorradorDeSeguimiento>) {
    setBorrador((b) => ({ ...b, ...parte }))
  }

  const opcionesConQuien = [
    { value: CONSULTORIO, label: clinica.medico ? `${clinica.medico} (consultorio)` : 'El consultorio' },
    ...clinica.personal.map((p) => ({ value: p.userId, label: p.nombre })),
  ]
  const bloqueo = motivoParaNoAnotarSeguimiento(borrador, hoy)

  return (
    <section className="flex flex-col gap-3 rounded-panel-card bg-panel-raised p-4">
      <h3 className="type-panel-label text-on-surface-variant">Anotar un contacto</h3>
      <div className="grid gap-3 sm:grid-cols-3">
        <Select
          id="seguimiento-con-quien"
          label="Con quién"
          value={borrador.conQuien || CONSULTORIO}
          options={opcionesConQuien}
          onChange={(v) => cambiar({ conQuien: v === CONSULTORIO ? '' : v })}
        />
        <Select
          id="seguimiento-canal"
          label="Por dónde"
          value={borrador.canal}
          options={OPCIONES_CANAL}
          onChange={(canal) => cambiar({ canal })}
        />
        <Select
          id="seguimiento-motivo"
          label="De qué"
          value={borrador.motivo}
          options={OPCIONES_MOTIVO}
          onChange={(motivo) => cambiar({ motivo })}
        />
      </div>
      <Textarea
        id="seguimiento-nota"
        label="Qué se habló"
        rows={3}
        maxLength={NOTA_MAXIMA}
        value={borrador.nota}
        placeholder={EJEMPLO_DE_NOTA[borrador.motivo]}
        onChange={(nota) => cambiar({ nota })}
      />
      <div className="flex flex-wrap items-end justify-between gap-3">
        <Input
          id="seguimiento-volver"
          label="Volver a llamar el (opcional)"
          type="date"
          min={hoy}
          value={borrador.volverEl}
          onChange={(volverEl) => cambiar({ volverEl })}
          className="w-56"
        />
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
      {anotar.isError && <ErrorBox title="No se pudo anotar" detail={describeError(anotar.error)} />}
    </section>
  )
}

function Historia({ merchantId }: { merchantId: string }) {
  const historia = useQuery(consultaHistoria(merchantId))

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
      {historia.isSuccess && historia.data.length === 0 && (
        <p className="type-panel-body text-on-surface-variant">
          Nadie del equipo ha anotado todavía un contacto con esta clínica.
        </p>
      )}
      {historia.isSuccess && historia.data.length > 0 && (
        <ol className="flex flex-col gap-3">
          {historia.data.map((h) => (
            <li key={h.id} className="border-l-2 border-panel-hairline-strong pl-3">
              <p className="type-panel-caption text-on-surface-variant">
                {formatDateTime(h.cuando)} · {h.quien}
                {h.conQuien ? ` con ${h.conQuien}` : ''} · {ROTULO_CANAL_DE_SEGUIMIENTO[h.canal]} ·{' '}
                {ROTULO_MOTIVO[h.motivo]}
              </p>
              <p className="whitespace-pre-line type-panel-body text-on-surface">{h.nota}</p>
              {h.volverEl && (
                <p className="type-panel-caption text-on-surface-variant">Volver a llamar el {formatDay(h.volverEl)}</p>
              )}
            </li>
          ))}
        </ol>
      )}
    </section>
  )
}
