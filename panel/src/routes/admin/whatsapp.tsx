import { createFileRoute, useNavigate } from '@tanstack/react-router'

import { InboxDeWhatsApp } from '@/components/admin/whatsapp/InboxDeWhatsApp'
import { comoBooleano, comoTexto, unoDe } from '@/lib/busqueda'

/** El chat abierto (su wa_id), la búsqueda, «Sin leer» y de quién: todo en la URL. */
type WhatsAppSearch = {
  chat?: string
  q?: string
  sin_leer?: true
  quien?: 'medicos' | 'pacientes'
}

export const Route = createFileRoute('/admin/whatsapp')({
  staticData: { title: 'WhatsApp', width: 'wide' },
  component: WhatsAppPage,
  validateSearch: (search: Record<string, unknown>): WhatsAppSearch => ({
    chat: comoTexto(search.chat),
    q: comoTexto(search.q),
    sin_leer: comoBooleano(search.sin_leer),
    quien: unoDe(['medicos', 'pacientes'] as const, search.quien),
  }),
})

/**
 * WhatsApp: el inbox del número de Helios dentro del superadmin. Lo que
 * escriben pacientes y médicos, y lo que les contesta el equipo, a través del
 * Inbox de 360dialog (Edge Function `whatsapp-inbox`).
 */
function WhatsAppPage() {
  const navigate = useNavigate({ from: '/admin/whatsapp' })
  const search = Route.useSearch()

  return (
    <InboxDeWhatsApp
      chat={search.chat ?? null}
      q={search.q ?? ''}
      sinLeer={search.sin_leer === true}
      quien={search.quien ?? null}
      onCambiar={(cambio) =>
        void navigate({
          search: (antes) => ({
            chat:
              cambio.chat === undefined
                ? antes.chat
                : (cambio.chat ?? undefined),
            q: cambio.q === undefined ? antes.q : cambio.q || undefined,
            sin_leer:
              cambio.sinLeer === undefined
                ? antes.sin_leer
                : cambio.sinLeer || undefined,
            quien:
              cambio.quien === undefined
                ? antes.quien
                : (cambio.quien ?? undefined),
          }),
          // Escribir en el buscador no llena el historial de pasos.
          replace: cambio.q !== undefined,
        })
      }
    />
  )
}
