import { useQuery, useQueryClient } from '@tanstack/react-query'
import type { InfiniteData } from '@tanstack/react-query'
import { MessageCircle, PlugZap } from 'lucide-react'

import { Callout } from '@/components/kit/Callout'
import { Card, EmptyState, NoSePudoLeer, SkeletonCard } from '@/components/ui'
import {
  claveDeChats,
  consultaChat,
  consultaEstadoDelInbox,
} from '@/features/admin/whatsapp/api'
import type {
  Chat,
  FiltroDeQuien,
  Pagina,
} from '@/features/admin/whatsapp/inbox'
import { Conversacion } from './Conversacion'
import { ListaDeChats } from './ListaDeChats'

/**
 * El inbox de WhatsApp: las conversaciones del número de Helios, leídas y
 * contestadas desde el Inbox de 360dialog sin salir del superadmin.
 *
 * Dos columnas en pantalla ancha (lista y chat); en una estrecha, una u otra
 * según haya un chat abierto. El chat abierto, la búsqueda, «Sin leer» y
 * el filtro de médicos o pacientes viven en la URL: se puede mandar el enlace de un chat a un compañero.
 */
export function InboxDeWhatsApp({
  chat,
  q,
  sinLeer,
  quien,
  onCambiar,
}: {
  chat: string | null
  q: string
  sinLeer: boolean
  quien: FiltroDeQuien | null
  onCambiar: (cambio: {
    chat?: string | null
    q?: string
    sinLeer?: boolean
    quien?: FiltroDeQuien | null
  }) => void
}) {
  const estado = useQuery(consultaEstadoDelInbox())

  if (estado.isPending) return <SkeletonCard />
  if (estado.isError) {
    return (
      <Card>
        <NoSePudoLeer onReintentar={() => void estado.refetch()} />
      </Card>
    )
  }
  if (!estado.data.configurado) return <SinConfigurar />

  return (
    <div className="flex flex-col gap-shell-gap-inner">
      {!estado.data.conectado && (
        <Callout tone="error" titulo="360dialog rechaza el token del Inbox">
          Hay que generar uno nuevo (POST /api/v1/auth/token/ con el usuario de
          «App integration») y guardarlo en el secreto D360_INBOX_TOKEN.
        </Callout>
      )}
      <Card className="grid h-[calc(100dvh-11rem)] min-h-[32rem] grid-cols-1 gap-shell-gap-block lg:grid-cols-[minmax(18rem,22rem)_1fr]">
        <div className={`min-h-0 flex-col ${chat ? 'hidden lg:flex' : 'flex'}`}>
          <ListaDeChats
            q={q}
            sinLeer={sinLeer}
            quien={quien}
            abierto={chat}
            onBuscar={(v) => onCambiar({ q: v })}
            onSinLeer={(v) => onCambiar({ sinLeer: v })}
            onQuien={(v) => onCambiar({ quien: v })}
            onAbrir={(waId) => onCambiar({ chat: waId })}
          />
        </div>
        <div
          className={`min-h-0 flex-col lg:border-l lg:border-panel-hairline lg:pl-shell-gap-block ${chat ? 'flex' : 'hidden lg:flex'}`}
        >
          {chat ? (
            <ChatAbierto
              waId={chat}
              q={q}
              sinLeer={sinLeer}
              quien={quien}
              onVolver={() => onCambiar({ chat: null })}
            />
          ) : (
            <div className="flex flex-1 flex-col items-center justify-center gap-2 text-center text-panel-muted">
              <MessageCircle size={40} aria-hidden />
              <p className="type-panel-body">
                Elige un chat para leerlo y contestar.
              </p>
            </div>
          )}
        </div>
      </Card>
    </div>
  )
}

/**
 * El chat abierto. Si está en la lista que ya se cargó, se usa esa fila (no
 * cuesta otra llamada); si se entró por enlace y no está, se pide suelto.
 */
function ChatAbierto({
  waId,
  q,
  sinLeer,
  quien,
  onVolver,
}: {
  waId: string
  q: string
  sinLeer: boolean
  quien: FiltroDeQuien | null
  onVolver: () => void
}) {
  const qc = useQueryClient()
  const lista = qc.getQueryData<InfiniteData<Pagina<Chat>>>(
    claveDeChats({ q: q.trim() || null, sinLeer, quien }),
  )
  const deLaLista =
    lista?.pages.flatMap((p) => p.filas).find((c) => c.waId === waId) ?? null
  const suelto = useQuery({
    ...consultaChat(waId),
    enabled: deLaLista === null,
  })
  const chat = deLaLista ?? suelto.data ?? null

  if (chat) return <Conversacion key={waId} chat={chat} onVolver={onVolver} />
  if (suelto.isPending) return <SkeletonCard />
  if (suelto.isError)
    return <NoSePudoLeer onReintentar={() => void suelto.refetch()} />
  return (
    <div className="flex flex-1 items-center justify-center text-center type-panel-body text-panel-muted">
      Ese chat no está en el Inbox.
    </div>
  )
}

function SinConfigurar() {
  return (
    <EmptyState
      icon={<PlugZap size={40} />}
      title="El inbox aún no está conectado con 360dialog"
      description="Falta guardar en Supabase los secretos D360_INBOX_URL (la dirección del Inbox) y D360_INBOX_TOKEN (el token de un usuario del grupo «App integration»), y desplegar la función whatsapp-inbox."
    />
  )
}
