import { useState } from 'react'
import type { ReactNode } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { MailWarning, Pencil } from 'lucide-react'

import { CambiosPropuestos } from '@/components/admin/pacientes/CambiosPropuestos'
import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Card,
  Checkbox,
  ErrorBox,
  Input,
  Modal,
  NoSePudoLeer,
  Seccion,
  Textarea,
  diaOperativo,
  formatDateTime,
  formatDay,
  formatDocument,
  formatPhone,
} from '@/components/ui'
import { consultaCorreosRecientes, reenviarComprobante } from '@/features/admin/avisos/api'
import { actualizarContactoDelPaciente, consultaCambiosPropuestos } from '@/features/admin/pacientes/api'
import {
  NOMBRE_DEL_CAMPO,
  SEXO,
  borradorDeDatos,
  cambioDeDatos,
  cambiosDelPaciente,
  edadEn,
} from '@/features/admin/pacientes/datos'
import type { BorradorDeDatos, CampoEditable, DatosDelPaciente } from '@/features/admin/pacientes/datos'
import type { UserDetail } from '@/features/admin/users'
import { describeError } from '@/lib/supabase'

// ── 2. Datos ───────────────────────────────────────────────────────────────

/**
 * Los datos que tecleó la clínica al registrarlo: identidad, contacto,
 * dirección y el contacto de referencia para la cobranza, con quién lo
 * registró y dónde. Helios no verifica identidades: lo que hay aquí es lo que
 * se escribió, y corregirlo pide motivo.
 *
 * Debajo, los cambios que propuso otra clínica al registrarlo de nuevo con
 * datos distintos: no se sobrescriben solos.
 */
export function PestanaDatos({ user, onDone }: { user: UserDetail; onDone: () => void }) {
  const d = user.datos
  const [editando, setEditando] = useState(false)
  const cambios = useQuery(consultaCambiosPropuestos('pendiente'))
  const suyos = cambiosDelPaciente(cambios.data ?? [], user.userId)
  const edad = d.age ?? edadEn(d.birthDate, diaOperativo())

  return (
    <div className="flex flex-col gap-shell-gap-block">
      {d.emailInvalidAt && (
        <Card tone="inset">
          <p className="flex items-center gap-2 type-panel-body text-error">
            <MailWarning size={16} aria-hidden /> El correo rebotó el {formatDateTime(d.emailInvalidAt)}: el comprobante
            no le llegó. Corrígelo con «Editar contacto»: al guardar el correo nuevo, se le reenvía el comprobante.
          </p>
        </Card>
      )}

      <Seccion
        titulo="Datos del paciente"
        info="Lo que escribió la clínica al registrarlo. Helios no verifica identidades: si algo está mal, se corrige aquí con motivo y queda en la bitácora."
        controles={
          <Button size="sm" variant="tonal" onClick={() => setEditando(true)}>
            <Pencil size={14} aria-hidden /> Editar contacto
          </Button>
        }
      >
        <Card>
          <Datos>
            <Dato rotulo="Cédula">{d.document ? formatDocument(d.document) : '—'}</Dato>
            <Dato rotulo="Nacimiento">
              {d.birthDate ? `${formatDay(d.birthDate)}${edad !== null ? ` · ${edad} años` : ''}` : '—'}
            </Dato>
            <Dato rotulo="Sexo">{d.sex ? (SEXO[d.sex] ?? d.sex) : '—'}</Dato>
            <Dato rotulo="Teléfono (WhatsApp)">{d.phone ? formatPhone(d.phone) : '—'}</Dato>
            <Dato rotulo="Correo">
              <span className="inline-flex flex-wrap items-center gap-2">
                {d.email ?? '—'}
                {d.emailInvalidAt && (
                  <Badge tone="error" icono>
                    Correo inválido
                  </Badge>
                )}
              </span>
            </Dato>
            <Dato rotulo="Ocupación">{d.occupation ?? '—'}</Dato>
            <Dato rotulo="Dirección">{[d.address, d.city, d.state].filter(Boolean).join(', ') || '—'}</Dato>
          </Datos>
        </Card>
      </Seccion>

      <Seccion
        titulo="Contacto de referencia"
        info="A quién se llama si no se localiza al paciente. Lo pide la clínica al registrarlo."
      >
        <Card>
          <Datos>
            <Dato rotulo="Nombre">{d.referenceName ?? '—'}</Dato>
            <Dato rotulo="Teléfono">{d.referencePhone ? formatPhone(d.referencePhone) : '—'}</Dato>
            <Dato rotulo="Parentesco">{d.referenceRelationship ?? '—'}</Dato>
          </Datos>
        </Card>
      </Seccion>

      <Seccion titulo="Registro" info="Quién lo registró por primera vez, en qué clínica y cuándo.">
        <Card>
          <Datos>
            <Dato rotulo="Registrado por">{d.registeredByName ?? '—'}</Dato>
            <Dato rotulo="Clínica">{d.registeredMerchantName ?? '—'}</Dato>
            <Dato rotulo="Fecha">{d.createdAt ? formatDateTime(d.createdAt) : '—'}</Dato>
          </Datos>
        </Card>
      </Seccion>

      <Seccion
        titulo="Cambios propuestos"
        info="Cuando una clínica registra a un paciente que ya existe con datos distintos, no se sobrescribe nada: queda aquí para que Helios lo apruebe o lo rechace."
      >
        {cambios.isError ? (
          <Card>
            <NoSePudoLeer onReintentar={() => void cambios.refetch()} />
          </Card>
        ) : suyos.length === 0 ? (
          <Card>
            <p className="type-panel-body text-on-surface-variant">
              {cambios.isPending ? 'Leyendo…' : 'Ninguna clínica ha propuesto cambios.'}
            </p>
          </Card>
        ) : (
          <CambiosPropuestos cambios={suyos} conPaciente={false} />
        )}
      </Seccion>

      {editando && (
        <EditarContacto
          userId={user.userId}
          nombre={user.fullName}
          datos={d}
          ultimaOrden={ultimaOrdenConfirmada(user)}
          onClose={() => setEditando(false)}
          onDone={() => {
            setEditando(false)
            onDone()
          }}
        />
      )}
    </div>
  )
}

function Datos({ children }: { children: ReactNode }) {
  return <dl className="grid grid-cols-1 gap-x-8 gap-y-4 sm:grid-cols-2 lg:grid-cols-3">{children}</dl>
}

function Dato({ rotulo, children }: { rotulo: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <dt className="type-panel-label text-on-surface-variant">{rotulo}</dt>
      <dd className="type-panel-body text-on-surface">{children}</dd>
    </div>
  )
}

/** Los campos del formulario, en dos bloques: el paciente y su referencia. */
const BLOQUES: ReadonlyArray<{ titulo: string; campos: ReadonlyArray<CampoEditable> }> = [
  { titulo: 'El paciente', campos: ['phone', 'email', 'state', 'city', 'address', 'occupation'] },
  { titulo: 'Su referencia', campos: ['reference_name', 'reference_phone', 'reference_relationship'] },
]

/**
 * Corregir el contacto: teléfono, correo, dirección, ocupación y la
 * referencia. La identidad (nombre, cédula, nacimiento) no se toca desde
 * aquí. Solo se manda lo que cambió, con el motivo (obligatorio: bitácora).
 */
/** La orden confirmada más reciente: la del comprobante que se reenvía al corregir el correo. */
function ultimaOrdenConfirmada(user: UserDetail): { id: string; orderNumber: number | null } | null {
  const confirmadas = user.charges
    .filter((c) => c.status === 'confirmed')
    .sort((a, b) => (b.confirmedAt ?? '').localeCompare(a.confirmedAt ?? ''))
  const c = confirmadas.at(0)
  return c ? { id: c.id, orderNumber: c.orderNumber } : null
}

function EditarContacto({
  userId,
  nombre,
  datos,
  ultimaOrden,
  onClose,
  onDone,
}: {
  userId: string
  nombre: string | null
  datos: DatosDelPaciente
  /** Su orden confirmada más reciente, si tiene: se le puede reenviar el comprobante al correo nuevo. */
  ultimaOrden: { id: string; orderNumber: number | null } | null
  onClose: () => void
  onDone: () => void
}) {
  const client = useQueryClient()
  const avisar = useToast()
  const [borrador, setBorrador] = useState<BorradorDeDatos>(() => borradorDeDatos(datos))
  const [motivo, setMotivo] = useState('')
  const [reenviar, setReenviar] = useState(true)

  const cambio = cambioDeDatos(datos, borrador)
  // Corregir el correo casi siempre es porque el comprobante no le llegó: se
  // reenvía en el mismo paso, sin ir a Avisos › Correos.
  const ofrecerReenvio = cambio.ok && cambio.campos.includes('email') && ultimaOrden !== null
  const bloqueo = !cambio.ok
    ? cambio.motivo
    : motivo.trim().length < 5
      ? 'Escribe el motivo: queda en la bitácora.'
      : undefined

  const guardar = useMutation({
    mutationFn: async () => {
      if (!cambio.ok) throw new Error(cambio.motivo)
      await actualizarContactoDelPaciente({ userId, cambios: cambio.payload, motivo })
      // `ofrecerReenvio` ya asegura que hay orden (TS lo estrecha).
      if (!(ofrecerReenvio && reenviar)) return 'sin-reenvio' as const
      // El contacto ya está guardado: si el reenvío falla, se dice, pero no
      // se deshace nada.
      try {
        await reenviarComprobante({ chargeId: ultimaOrden.id })
        return 'reenviado' as const
      } catch {
        return 'reenvio-fallido' as const
      }
    },
    onSuccess: (reenvio) => {
      avisar(
        reenvio === 'reenviado'
          ? `Datos de ${nombre ?? 'el paciente'} actualizados y comprobante reenviado al correo nuevo`
          : reenvio === 'reenvio-fallido'
            ? `Datos actualizados, pero no se pudo reenviar el comprobante: hazlo desde Avisos › Correos`
            : `Datos de ${nombre ?? 'el paciente'} actualizados`,
      )
      void client.invalidateQueries({ queryKey: ['admin-user', userId] })
      void client.invalidateQueries({ queryKey: consultaCorreosRecientes().queryKey })
      void client.invalidateQueries({ queryKey: ['admin-users'] })
      void client.invalidateQueries({ queryKey: ['admin-audit'] })
      onDone()
    },
  })

  return (
    <Modal title={`Editar el contacto de ${nombre ?? 'este paciente'}`} width="lg" onClose={onClose}>
      <div className="flex flex-col gap-5">
        {BLOQUES.map((b) => (
          <fieldset key={b.titulo} className="flex flex-col gap-3">
            <legend className="mb-2 type-panel-label text-on-surface-variant">{b.titulo}</legend>
            <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
              {b.campos.map((campo) => (
                <Input
                  key={campo}
                  id={`editar-contacto-${campo}`}
                  label={NOMBRE_DEL_CAMPO[campo]}
                  value={borrador[campo]}
                  onChange={(v) => setBorrador((prev) => ({ ...prev, [campo]: v }))}
                  inputMode={campo.includes('phone') ? 'tel' : undefined}
                  type={campo === 'email' ? 'email' : 'text'}
                  autoComplete="off"
                />
              ))}
            </div>
          </fieldset>
        ))}

        {cambio.ok && (
          <p className="type-panel-caption text-on-surface-variant">
            Cambia: {cambio.campos.map((c) => NOMBRE_DEL_CAMPO[c].toLowerCase()).join(', ')}.
          </p>
        )}

        {ofrecerReenvio && (
          <Checkbox
            id="editar-contacto-reenviar"
            label={`Reenviar el comprobante de la orden${
              ultimaOrden.orderNumber !== null ? ` #${ultimaOrden.orderNumber}` : ''
            } al correo nuevo`}
            checked={reenviar}
            onChange={setReenviar}
          />
        )}

        <Textarea
          id="editar-contacto-motivo"
          label="Motivo"
          value={motivo}
          onChange={setMotivo}
          rows={2}
          maxLength={300}
          placeholder="El paciente escribió por WhatsApp con su correo correcto"
        />

        {guardar.isError && <ErrorBox title="No se pudo guardar" detail={describeError(guardar.error)} />}

        <div className="flex flex-wrap items-start gap-3">
          <Button
            size="md"
            disabled={bloqueo !== undefined || guardar.isPending}
            motivoApagado={bloqueo}
            onClick={() => guardar.mutate()}
          >
            {guardar.isPending
              ? 'Guardando…'
              : ofrecerReenvio && reenviar
                ? 'Guardar y reenviar el comprobante'
                : 'Guardar los cambios'}
          </Button>
          <Button size="md" variant="text" onClick={onClose}>
            Cancelar
          </Button>
        </div>
      </div>
    </Modal>
  )
}
