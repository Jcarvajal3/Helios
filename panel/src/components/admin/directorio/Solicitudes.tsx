import { useState } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'

import { CamposDeAlta } from '@/components/afiliacion/CamposDeAlta'
import type { Column } from '@/components/DataTable'
import { useToast } from '@/components/Toast'
import { Credenciales } from '@/components/PersonalDelLocal'
import { Badge, Button, Checkbox, ErrorBox, Modal, Textarea, formatDateTime } from '@/components/ui'
import { CLAVE_SOLICITUDES, aprobarSolicitud, rechazarSolicitud } from '@/features/admin/clinicas/api'
import { enviarBienvenidaPorWhatsApp, registrarNumeroDelBot } from '@/features/admin/clinicas/bot'
import type { ResultadoBienvenidaWhatsApp } from '@/features/admin/clinicas/bot'
import { celularAE164, correccionesDeSolicitud, motivoDeAlta } from '@/features/admin/clinicas/clinicas'
import { generatePassword } from '@/features/admin/password'
import type { AltaDeClinica, SolicitudDeAfiliacion } from '@/features/admin/clinicas/clinicas'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { addStaff, enviarBienvenida } from '@/features/merchant/staff'
import type { ResultadoBienvenida } from '@/features/merchant/staff'
import { describeError } from '@/lib/supabase'

// ═══════════════════════════════════════════════════════════════════════════
// Las solicitudes de afiliación que mandan los médicos desde la portada
// (`/afiliacion`). Esperan en Clínicas › Pendientes hasta que un super admin
// las aprueba (nace la clínica) o las rechaza.
// ═══════════════════════════════════════════════════════════════════════════

export const columnasSolicitudes: Array<Column<SolicitudDeAfiliacion>> = [
  {
    key: 'consultorio',
    header: 'Consultorio',
    identity: true,
    sort: (s) => s.alta.clinicName,
    csv: (s) => s.alta.clinicName,
    cell: (s) => (
      <div>
        <p className="font-medium text-on-surface">{s.alta.clinicName}</p>
        <p className="type-panel-caption text-on-surface-variant">{s.alta.taxId || 'Sin RIF'}</p>
      </div>
    ),
  },
  {
    key: 'medico',
    header: 'Médico',
    sort: (s) => s.alta.ownerName,
    csv: (s) => s.alta.ownerName,
    cell: (s) => (
      <div>
        <p className="text-on-surface">{s.alta.ownerName}</p>
        <p className="type-panel-caption text-on-surface-variant">{s.alta.ownerDocument}</p>
      </div>
    ),
  },
  {
    key: 'especialidad',
    header: 'Especialidad',
    sort: (s) => s.alta.specialty,
    csv: (s) => s.alta.specialty,
    cell: (s) => s.alta.specialty,
  },
  {
    key: 'contacto',
    header: 'Contacto',
    csv: (s) => `${s.alta.phone} · ${s.alta.email}`,
    cell: (s) => (
      <div>
        <p className="text-on-surface">{s.alta.phone}</p>
        <p className="type-panel-caption text-on-surface-variant">{s.alta.email}</p>
      </div>
    ),
  },
  {
    key: 'recibida',
    header: 'Recibida',
    sort: (s) => s.createdAt,
    sortDir: 'desc',
    csv: (s) => s.createdAt,
    cell: (s) => (
      <span className="flex flex-col items-start gap-1">
        <Badge tone="warning">Pendiente</Badge>
        <span className="type-panel-caption text-on-surface-variant">{formatDateTime(s.createdAt)}</span>
      </span>
    ),
  },
]

/**
 * Lo que pasó al aprobar, además de nacer la clínica. La clínica ya existe:
 * si algo de esto falla, se dice y se arregla desde su ficha, pero no se
 * deshace nada.
 */
type DespuesDeAprobar = {
  merchantId: string
  /** `null` si no se pidió crear el usuario. */
  usuario: { email: string; password: string } | { error: string } | null
  bot: 'ok' | { error: string } | null
  correo: ResultadoBienvenida | { status: 'error'; error: string } | null
  whatsapp: ResultadoBienvenidaWhatsApp | { status: 'error'; error: string } | null
}

/**
 * Revisar una solicitud: los datos del médico en el mismo formulario del
 * alta, por si hay que corregir algo antes de aprobar. Aprobar crea la
 * clínica (con su cuenta de pago) y, si se deja marcado:
 *
 *   · su usuario principal (administrador) con el correo y el nombre de la
 *     solicitud y una contraseña generada, y le manda los accesos por correo
 *     (con copia a Helios);
 *   · registra su teléfono para el bot (si es un celular) y le da la
 *     bienvenida por WhatsApp.
 *
 * Al terminar enseña la contraseña una vez y qué salió y qué no. Rechazar
 * pide el motivo, que queda para el equipo (al médico no se le manda nada).
 */
export function RevisarSolicitud({ solicitud, onClose }: { solicitud: SolicitudDeAfiliacion; onClose: () => void }) {
  const avisar = useToast()
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const isSuperAdmin = useIsSuperAdmin()

  const [alta, setAlta] = useState<AltaDeClinica>(solicitud.alta)
  const [rechazando, setRechazando] = useState(false)
  const [motivo, setMotivo] = useState('')
  const [crearUsuario, setCrearUsuario] = useState(true)
  const [darBot, setDarBot] = useState(true)
  const [despues, setDespues] = useState<DespuesDeAprobar | null>(null)

  const celular = celularAE164(alta.phone)
  const conBot = crearUsuario && darBot && celular !== null

  const refrescar = () => {
    void queryClient.invalidateQueries({ queryKey: CLAVE_SOLICITUDES })
    void queryClient.invalidateQueries({ queryKey: ['merchants'] })
  }

  const aprobar = useMutation({
    mutationFn: async (): Promise<DespuesDeAprobar> => {
      const merchantId = await aprobarSolicitud({
        id: solicitud.id,
        correcciones: correccionesDeSolicitud(solicitud.alta, alta),
      })
      const resultado: DespuesDeAprobar = { merchantId, usuario: null, bot: null, correo: null, whatsapp: null }
      if (!crearUsuario) return resultado

      const email = alta.email.trim().toLowerCase()
      const password = generatePassword()
      let userId: string
      try {
        userId = await addStaff({ merchantId, email, password, fullName: alta.ownerName, role: 'gerente' })
        resultado.usuario = { email, password }
      } catch (e) {
        resultado.usuario = { error: describeError(e) ?? 'No se pudo crear' }
        return resultado
      }

      // El bot antes que los mensajes: así el correo ya dice su número.
      if (conBot) {
        try {
          await registrarNumeroDelBot({ userId, merchantId, phone: alta.phone })
          resultado.bot = 'ok'
        } catch (e) {
          resultado.bot = { error: describeError(e) ?? 'No se pudo registrar' }
        }
      }

      try {
        resultado.correo = await enviarBienvenida({ merchantId, userId, password })
      } catch (e) {
        resultado.correo = { status: 'error', error: describeError(e) ?? 'No se pudo enviar' }
      }

      if (resultado.bot === 'ok') {
        try {
          resultado.whatsapp = await enviarBienvenidaPorWhatsApp({ merchantId, userId })
        } catch (e) {
          resultado.whatsapp = { status: 'error', error: describeError(e) ?? 'No se pudo enviar' }
        }
      }
      return resultado
    },
    onSuccess: (resultado) => {
      refrescar()
      if (resultado.usuario === null) {
        avisar(`${alta.clinicName.trim()} aprobada y dada de alta. Le falta el personal`)
        irALaFicha(resultado.merchantId)
      } else {
        setDespues(resultado)
      }
    },
  })

  function irALaFicha(merchantId: string) {
    onClose()
    void navigate({ to: '/admin/clinicas/$id', params: { id: merchantId } })
  }

  const rechazar = useMutation({
    mutationFn: () => rechazarSolicitud({ id: solicitud.id, motivo: motivo.trim() }),
    onSuccess: () => {
      avisar('Solicitud rechazada')
      refrescar()
      onClose()
    },
  })

  if (despues) {
    return (
      <Modal title={`${alta.clinicName.trim()} ya está dada de alta`} width="md" onClose={() => irALaFicha(despues.merchantId)}>
        <div className="flex flex-col gap-4">
          {despues.usuario && 'password' in despues.usuario && (
            <>
              <p className="type-panel-body text-on-surface-variant">
                {alta.ownerName.trim()} entra al panel como administrador con estos datos:
              </p>
              <Credenciales email={despues.usuario.email} password={despues.usuario.password} />
            </>
          )}
          <ResumenDeAprobacion despues={despues} telefono={alta.phone} />
          <div>
            <Button size="md" onClick={() => irALaFicha(despues.merchantId)}>
              Ir a su ficha
            </Button>
          </div>
        </div>
      </Modal>
    )
  }

  const ocupado = aprobar.isPending || rechazar.isPending
  const bloqueoAprobar = !isSuperAdmin ? SOLO_SUPER_ADMIN : (motivoDeAlta(alta) ?? undefined)
  const bloqueoRechazar = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : motivo.trim() === ''
      ? 'Escribe el motivo del rechazo.'
      : undefined

  return (
    <Modal title="Solicitud de afiliación" width="lg" onClose={onClose}>
      <div className="flex flex-col gap-6">
        <p className="type-panel-caption text-on-surface-variant">
          Recibida el {formatDateTime(solicitud.createdAt)}. Revisa los datos y corrige lo que haga falta antes de
          aprobar: al aprobar nace la clínica, activa y con esta cuenta de pago. Si quieres, añade su Pago Móvil.
        </p>

        <CamposDeAlta id={`solicitud-${solicitud.id}`} valor={alta} onChange={setAlta} />

        {!rechazando && (
          <fieldset className="flex flex-col gap-3">
            <legend className="mb-3 type-panel-section text-on-surface">Al aprobar</legend>
            <Checkbox
              id={`solicitud-usuario-${solicitud.id}`}
              label={`Crear su usuario principal (administrador) con ${alta.email.trim() || 'su correo'} y enviarle sus accesos por correo, con copia a Helios`}
              checked={crearUsuario}
              onChange={setCrearUsuario}
            />
            <Checkbox
              id={`solicitud-bot-${solicitud.id}`}
              label={
                celular
                  ? `Registrar el ${alta.phone.trim()} para el bot y darle la bienvenida por WhatsApp`
                  : 'Registrar su teléfono para el bot: no se puede, no es un celular (el bot solo funciona con celulares)'
              }
              checked={conBot}
              disabled={!crearUsuario || celular === null}
              onChange={setDarBot}
            />
          </fieldset>
        )}

        {aprobar.isError && <ErrorBox title="No se pudo aprobar" detail={describeError(aprobar.error)} />}
        {rechazar.isError && <ErrorBox title="No se pudo rechazar" detail={describeError(rechazar.error)} />}

        {rechazando ? (
          <div className="flex flex-col gap-3">
            <Textarea
              id={`solicitud-motivo-${solicitud.id}`}
              label="Motivo del rechazo (solo lo ve el equipo)"
              value={motivo}
              onChange={setMotivo}
              rows={3}
              maxLength={300}
              placeholder="No es un consultorio de salud, datos falsos…"
            />
            <div className="flex items-start gap-3">
              <Button
                size="md"
                variant="tonal"
                disabled={!!bloqueoRechazar || ocupado}
                motivoApagado={ocupado ? undefined : bloqueoRechazar}
                onClick={() => rechazar.mutate()}
              >
                {rechazar.isPending ? 'Rechazando…' : 'Rechazar la solicitud'}
              </Button>
              <Button variant="text" size="md" onClick={() => setRechazando(false)}>
                Volver
              </Button>
            </div>
          </div>
        ) : (
          <div className="flex flex-wrap items-start gap-3">
            <Button
              size="md"
              disabled={!!bloqueoAprobar || ocupado}
              motivoApagado={ocupado ? undefined : bloqueoAprobar}
              onClick={() => aprobar.mutate()}
            >
              {aprobar.isPending ? 'Aprobando…' : 'Aprobar y crear la clínica'}
            </Button>
            <Button
              variant="text"
              size="md"
              disabled={!isSuperAdmin || ocupado}
              title={isSuperAdmin ? undefined : SOLO_SUPER_ADMIN}
              onClick={() => setRechazando(true)}
            >
              Rechazar…
            </Button>
          </div>
        )}
      </div>
    </Modal>
  )
}

/** Qué salió y qué no después de aprobar, una línea por cosa. */
function ResumenDeAprobacion({ despues, telefono }: { despues: DespuesDeAprobar; telefono: string }) {
  const lineas: Array<{ ok: boolean; texto: string }> = []
  const u = despues.usuario

  if (u && 'error' in u) {
    lineas.push({
      ok: false,
      texto: `No se creó su usuario: ${u.error}. Créalo desde la pestaña Personal de su ficha.`,
    })
  }

  if (despues.bot === 'ok') {
    lineas.push({ ok: true, texto: `Puede usar el bot desde el ${telefono.trim()}.` })
  } else if (despues.bot) {
    lineas.push({ ok: false, texto: `No se registró su WhatsApp para el bot: ${despues.bot.error}. Ponlo desde Personal.` })
  }

  const c = despues.correo
  if (c?.status === 'enviado') {
    lineas.push({ ok: true, texto: 'Le enviamos sus accesos por correo, con copia a Helios.' })
  } else if (c?.status === 'sin_configurar') {
    lineas.push({ ok: false, texto: 'No se envió el correo: el envío de correos no está configurado. Pásale los datos por otro canal.' })
  } else if (c) {
    lineas.push({ ok: false, texto: `No se pudo enviar el correo${c.error ? ` (${c.error})` : ''}. Pásale los datos por otro canal.` })
  }

  const w = despues.whatsapp
  if (w?.status === 'en_cola') {
    lineas.push({ ok: true, texto: 'Su bienvenida por WhatsApp sale en un momento.' })
  } else if (w?.status === 'ya_enviado') {
    lineas.push({ ok: true, texto: 'Su bienvenida por WhatsApp ya se había enviado.' })
  } else if (w?.status === 'sin_plantilla') {
    lineas.push({
      ok: false,
      texto: 'No se envió el WhatsApp: no te ha escrito en las últimas 24 h y la plantilla de bienvenida aún no está aprobada en Meta. Escríbele tú.',
    })
  } else if (w) {
    lineas.push({ ok: false, texto: `No se pudo enviar el WhatsApp${'error' in w ? ` (${w.error})` : ''}.` })
  }

  if (lineas.length === 0) return null
  return (
    <ul className="flex flex-col gap-1">
      {lineas.map((l) => (
        <li key={l.texto} className={`type-panel-body ${l.ok ? 'text-on-surface-variant' : 'text-warning'}`}>
          {l.texto}
        </li>
      ))}
    </ul>
  )
}
