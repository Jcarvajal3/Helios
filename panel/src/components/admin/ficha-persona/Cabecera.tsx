import { Lock, MessageCircle, ShieldAlert } from 'lucide-react'

import { EstadoBadge } from '@/components/admin/EstadoBadge'
import { CabeceraDeFicha } from '@/components/admin/ficha'
import type { HuecoDeMenu } from '@/components/admin/ficha'
import {
  Badge,
  claseDeBoton,
  formatDateTime,
  formatDocument,
  formatPhone,
  whatsappNumber,
} from '@/components/ui'
import type { UserDetail } from '@/features/admin/users'
import { BotonAnotarGestion } from './CobranzaGestion'
import { BotonWhatsAppCobranza, useCasoDeCobranza } from './CobranzaWhatsApp'

// ── 1. Cabecera ────────────────────────────────────────────────────────────

/**
 * Quién es, en qué estado está su cuenta y cómo escribirle, sin cambiar de
 * pestaña. Lo que debe y lo que puede gastar va en el carril; las acciones
 * que la frenan, en el «⋯».
 */
export function Cabecera({
  user,
  bloqueada,
  menu,
}: {
  user: UserDetail
  /** Si tiene un bloqueo manual abierto (`useBloqueoDeCuenta`). */
  bloqueada: boolean
  menu: ReadonlyArray<HuecoDeMenu>
}) {
  return (
    <CabeceraDeFicha
      identidad={<AvatarPersona user={user} />}
      nombre={user.fullName ?? 'Sin nombre'}
      insignias={
        <>
          <EstadoBadge tipo="persona" valor={user.status} />
          {bloqueada && (
            <Badge tone="error" icono={Lock}>
              Bloqueada
            </Badge>
          )}
          <Badge>{user.level === 0 ? 'Sin nivel' : `Nivel ${user.level}`}</Badge>
          {user.isBlacklisted && (
            <span className="inline-flex" title={user.blacklistReason ?? undefined}>
              <Badge tone="error" icono={ShieldAlert}>
                Marca interna
              </Badge>
            </span>
          )}
          {user.isTest && <Badge>Cuenta de prueba</Badge>}
        </>
      }
      datos={[
        user.phone ? formatPhone(user.phone) : null,
        user.document ? formatDocument(user.document) : null,
        `Alta el ${formatDateTime(user.createdAt)}`,
      ]}
      acciones={<Contacto user={user} />}
      menu={menu}
    />
  )
}

/**
 * Escribirle, que es la acción principal de la ficha, y anotar lo que se
 * habló.
 *
 * A quien está en la cartera se le escribe con la plantilla de su tramo, y el
 * botón se apaga con el motivo escrito si falta algo. A quien no debe nada
 * (una duda sobre su financiamiento, por ejemplo) se le abre el chat sin mensaje:
 * la plantilla de cobro no tiene nada que decirle.
 */
function Contacto({ user }: { user: UserDetail }) {
  const fila = useCasoDeCobranza(user.userId)
  const numero = whatsappNumber(user.phone)

  return (
    <>
      {fila.data === null ? (
        numero && (
          <a
            href={`https://wa.me/${numero}`}
            target="_blank"
            rel="noreferrer"
            className={`whitespace-nowrap ${claseDeBoton('filled', 'sm')}`}
          >
            <MessageCircle size={14} aria-hidden /> Escribir por WhatsApp
          </a>
        )
      ) : (
        <BotonWhatsAppCobranza userId={user.userId} persona={fila.data ?? undefined} principal />
      )}
      <BotonAnotarGestion userId={user.userId} nombre={user.fullName ?? 'este paciente'} />
    </>
  )
}

/** La inicial de su nombre: Helios no tiene app, y nadie elige avatar. */
function AvatarPersona({ user }: { user: UserDetail }) {
  const inicial = (user.fullName ?? '?').trim().charAt(0).toUpperCase() || '?'

  return (
    <span
      aria-hidden
      className="grid size-12 shrink-0 place-items-center rounded-full bg-panel-control"
    >
      <span className="type-panel-control text-on-surface-variant">{inicial}</span>
    </span>
  )
}
