import { Link } from '@tanstack/react-router'
import { ExternalLink, MessageCircle, Phone } from 'lucide-react'

import { formatPhone, whatsappNumber } from '@/components/ui'
import { chatDelInbox, enlaceDeLlamada } from '@/features/admin/seguimiento/seguimiento'

const ICONO =
  'inline-flex size-7 items-center justify-center rounded-panel-control text-on-surface-variant transition-colors hover:bg-panel-raised hover:text-on-surface'

/**
 * Un teléfono con lo que se hace con él: llamarlo y abrir su chat en el inbox
 * de Helios (con `conWaMe`, también desde el WhatsApp propio).
 *
 * El chat va al inbox y no a wa.me: los médicos que usan el bot ya le
 * escriben al número de Helios, así que la conversación de siempre está ahí,
 * y lo que se le conteste queda a la vista del resto del equipo. Fuera de la
 * ventana de 24 h de WhatsApp el inbox no deja escribir texto libre; para eso
 * está «Desde tu WhatsApp».
 *
 * `conInbox={false}` quita el enlace al inbox, para quien no puede abrirlo
 * (el rol de la agenda).
 */
export function TelefonoConAcciones({
  telefono,
  nombre,
  conWaMe = false,
  conInbox = true,
}: {
  telefono: string
  nombre: string
  conWaMe?: boolean
  conInbox?: boolean
}) {
  const llamada = enlaceDeLlamada(telefono)
  const chat = conInbox ? chatDelInbox(telefono) : null
  const waMe = whatsappNumber(telefono)

  return (
    <span className="inline-flex items-center gap-1">
      <span className="tabular-nums whitespace-nowrap">{formatPhone(telefono)}</span>
      {llamada && (
        <a href={llamada} className={ICONO} aria-label={`Llamar a ${nombre}`} title={`Llamar a ${nombre}`}>
          <Phone size={14} aria-hidden />
        </a>
      )}
      {chat && (
        <Link
          to="/admin/whatsapp"
          search={{ chat }}
          className={ICONO}
          aria-label={`Abrir el chat de ${nombre} en el inbox`}
          title="Abrir su chat en el inbox de Helios"
        >
          <MessageCircle size={14} aria-hidden />
        </Link>
      )}
      {conWaMe && waMe && (
        <a
          href={`https://wa.me/${waMe}`}
          target="_blank"
          rel="noreferrer"
          className={ICONO}
          aria-label={`Escribir a ${nombre} desde tu WhatsApp`}
          title="Escribirle desde tu WhatsApp (wa.me)"
        >
          <ExternalLink size={14} aria-hidden />
        </a>
      )}
    </span>
  )
}
