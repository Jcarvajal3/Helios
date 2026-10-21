import { useNavigate } from '@tanstack/react-router'

import { Credenciales } from '@/components/PersonalDelLocal'
import { Button, Checkbox, Modal } from '@/components/ui'
import { enviarBienvenidaPorWhatsApp, registrarNumeroDelBot } from '@/features/admin/clinicas/bot'
import type { ResultadoBienvenidaWhatsApp } from '@/features/admin/clinicas/bot'
import { celularAE164 } from '@/features/admin/clinicas/clinicas'
import type { AltaDeClinica } from '@/features/admin/clinicas/clinicas'
import { generatePassword } from '@/features/admin/password'
import { addStaff, enviarBienvenida } from '@/features/merchant/staff'
import type { ResultadoBienvenida } from '@/features/merchant/staff'
import { describeError } from '@/lib/supabase'

// ═══════════════════════════════════════════════════════════════════════════
// Lo que pasa después de que nace una clínica, sea al aprobar una solicitud
// de la portada o al darla de alta a mano: el usuario del médico titular
// (administrador), su WhatsApp para el bot y la bienvenida por correo y por
// WhatsApp. Un solo camino para los dos: antes el alta a mano dejaba la
// clínica «sin personal» y había que ir después a Personal.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Lo que pasó además de nacer la clínica. La clínica ya existe: si algo de
 * esto falla, se dice y se arregla desde su ficha, pero no se deshace nada.
 */
export type DespuesDelAlta = {
  merchantId: string
  /** `null` si no se pidió crear el usuario. */
  usuario: { email: string; password: string } | { error: string } | null
  bot: 'ok' | { error: string } | null
  correo: ResultadoBienvenida | { status: 'error'; error: string } | null
  whatsapp: ResultadoBienvenidaWhatsApp | { status: 'error'; error: string } | null
}

/** Qué se pide hacer al dar de alta: crear su usuario y, con él, darle el bot. */
export type OpcionesDeAcceso = { crearUsuario: boolean; darBot: boolean }

/** Si se le puede dar el bot: hace falta su usuario y un celular. */
export function conBotDe(alta: AltaDeClinica, o: OpcionesDeAcceso): boolean {
  return o.crearUsuario && o.darBot && celularAE164(alta.phone) !== null
}

/**
 * Crea el usuario del titular con una contraseña generada, registra su
 * WhatsApp para el bot y le manda la bienvenida. El bot antes que los
 * mensajes: así el correo ya dice su número.
 */
export async function darAccesoAlTitular(
  merchantId: string,
  alta: AltaDeClinica,
  opciones: OpcionesDeAcceso,
): Promise<DespuesDelAlta> {
  const resultado: DespuesDelAlta = { merchantId, usuario: null, bot: null, correo: null, whatsapp: null }
  if (!opciones.crearUsuario) return resultado

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

  if (conBotDe(alta, opciones)) {
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
}

/** Las dos casillas de «Al dar de alta». */
export function OpcionesDelAlta({
  id,
  alta,
  opciones,
  onChange,
  titulo,
}: {
  id: string
  alta: AltaDeClinica
  opciones: OpcionesDeAcceso
  onChange: (o: OpcionesDeAcceso) => void
  titulo: string
}) {
  const celular = celularAE164(alta.phone)
  return (
    <fieldset className="flex flex-col gap-3">
      <legend className="mb-3 type-panel-section text-on-surface">{titulo}</legend>
      <Checkbox
        id={`${id}-usuario`}
        label={`Crear su usuario principal (administrador) con ${alta.email.trim() || 'su correo'} y enviarle sus accesos por correo, con copia a Helios`}
        checked={opciones.crearUsuario}
        onChange={(crearUsuario) => onChange({ ...opciones, crearUsuario })}
      />
      <Checkbox
        id={`${id}-bot`}
        label={
          celular
            ? `Registrar el ${alta.phone.trim()} para el bot y darle la bienvenida por WhatsApp`
            : 'Registrar su teléfono para el bot: no se puede, no es un celular (el bot solo funciona con celulares)'
        }
        checked={conBotDe(alta, opciones)}
        disabled={!opciones.crearUsuario || celular === null}
        onChange={(darBot) => onChange({ ...opciones, darBot })}
      />
    </fieldset>
  )
}

/**
 * La ventana de después: la contraseña, una sola vez, y qué salió y qué no.
 * «Ir a su ficha» abre en Personal, que es lo siguiente que se mira.
 */
export function YaDadaDeAlta({
  despues,
  alta,
  onClose,
}: {
  despues: DespuesDelAlta
  alta: AltaDeClinica
  onClose: () => void
}) {
  const navigate = useNavigate()
  const irALaFicha = () => {
    onClose()
    void navigate({ to: '/admin/clinicas/$id', params: { id: despues.merchantId }, search: { tab: 'personal' } })
  }

  return (
    <Modal title={`${alta.clinicName.trim()} ya está dada de alta`} width="md" onClose={irALaFicha}>
      <div className="flex flex-col gap-4">
        {despues.usuario && 'password' in despues.usuario && (
          <>
            <p className="type-panel-body text-on-surface-variant">
              {alta.ownerName.trim()} entra al panel como administrador con estos datos:
            </p>
            <Credenciales email={despues.usuario.email} password={despues.usuario.password} />
          </>
        )}
        <ResumenDelAlta despues={despues} telefono={alta.phone} />
        <div>
          <Button size="md" onClick={irALaFicha}>
            Ir a su ficha
          </Button>
        </div>
      </div>
    </Modal>
  )
}

/** Qué salió y qué no después de dar de alta, una línea por cosa. */
function ResumenDelAlta({ despues, telefono }: { despues: DespuesDelAlta; telefono: string }) {
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
