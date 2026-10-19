import { useEffect, useState } from 'react'
import { useInfiniteQuery } from '@tanstack/react-query'
import { MessageCircle } from 'lucide-react'

import {
  Button,
  NoSePudoLeer,
  SearchInput,
  Segmented,
  SkeletonList,
  formatPhone,
} from '@/components/ui'
import { consultaChats } from '@/features/admin/whatsapp/api'
import { nombreDelChat, vistaPrevia } from '@/features/admin/whatsapp/inbox'
import type { Chat } from '@/features/admin/whatsapp/inbox'
import { horaCorta } from './horas'

/**
 * La columna de la izquierda: los chats del número de Helios, del último
 * mensaje al primero, con buscador y «Sin leer». Se refresca sola cada 15 s.
 */
export function ListaDeChats({
  q,
  sinLeer,
  abierto,
  onBuscar,
  onSinLeer,
  onAbrir,
}: {
  q: string
  sinLeer: boolean
  abierto: string | null
  onBuscar: (q: string) => void
  onSinLeer: (sinLeer: boolean) => void
  onAbrir: (waId: string) => void
}) {
  const consulta = useInfiniteQuery(
    consultaChats({ q: q.trim() || null, sinLeer }),
  )
  const chats = consulta.data?.pages.flatMap((p) => p.filas) ?? []

  // Lo que se teclea vive aquí y llega a la URL (y al Inbox) un momento
  // después: ni una llamada por tecla, ni un espacio final que la URL recorte
  // mientras se escribe.
  const [texto, setTexto] = useState(q)
  useEffect(() => setTexto((t) => (t.trim() === q.trim() ? t : q)), [q])
  useEffect(() => {
    if (texto.trim() === q.trim()) return
    const id = setTimeout(() => onBuscar(texto.trim()), 350)
    return () => clearTimeout(id)
  }, [texto, q, onBuscar])

  return (
    <div className="flex min-h-0 flex-col gap-shell-gap-inner">
      <SearchInput
        id="buscar-chat"
        value={texto}
        onChange={setTexto}
        placeholder="Nombre, teléfono o etiqueta"
      />
      <Segmented
        etiqueta="Qué chats"
        options={[
          { value: 'todos', label: 'Todos' },
          { value: 'sin-leer', label: 'Sin leer' },
        ]}
        value={sinLeer ? 'sin-leer' : 'todos'}
        onChange={(v) => onSinLeer(v === 'sin-leer')}
      />

      <div className="min-h-0 flex-1 overflow-y-auto">
        {consulta.isError ? (
          <NoSePudoLeer onReintentar={() => void consulta.refetch()} />
        ) : consulta.isPending ? (
          <SkeletonList />
        ) : chats.length === 0 ? (
          <div className="flex flex-col items-center gap-2 py-10 text-center text-panel-muted">
            <MessageCircle size={32} aria-hidden />
            <p className="type-panel-body">
              {q.trim()
                ? 'Ningún chat coincide con la búsqueda.'
                : sinLeer
                  ? 'Nada sin leer.'
                  : 'Aún no hay conversaciones.'}
            </p>
          </div>
        ) : (
          <ul className="flex flex-col gap-0.5">
            {chats.map((chat) => (
              <li key={chat.waId}>
                <FilaDeChat
                  chat={chat}
                  activo={chat.waId === abierto}
                  onAbrir={() => onAbrir(chat.waId)}
                />
              </li>
            ))}
          </ul>
        )}
        {consulta.hasNextPage && (
          <div className="mt-shell-gap-inner">
            <Button
              variant="text"
              size="sm"
              disabled={consulta.isFetchingNextPage}
              onClick={() => void consulta.fetchNextPage()}
            >
              {consulta.isFetchingNextPage ? 'Cargando…' : 'Ver más chats'}
            </Button>
          </div>
        )}
      </div>
    </div>
  )
}

function FilaDeChat({
  chat,
  activo,
  onAbrir,
}: {
  chat: Chat
  activo: boolean
  onAbrir: () => void
}) {
  return (
    <button
      type="button"
      onClick={onAbrir}
      aria-current={activo ? 'true' : undefined}
      className={`flex w-full items-start gap-3 rounded-panel-control px-3 py-2.5 text-left transition-colors duration-[var(--transition-fast)] ${
        activo ? 'bg-panel-raised' : 'hover:bg-panel-raised'
      }`}
    >
      <span
        aria-hidden
        className="flex size-9 shrink-0 items-center justify-center rounded-full bg-panel-control type-panel-caption font-semibold text-on-surface"
      >
        {chat.iniciales}
      </span>
      <span className="min-w-0 flex-1">
        <span className="flex items-baseline gap-2">
          <span
            className={`truncate type-panel-body text-on-surface ${chat.sinLeer > 0 ? 'font-semibold' : ''}`}
          >
            {nombreDelChat(chat, formatPhone)}
          </span>
          <span className="ml-auto shrink-0 type-panel-caption tabular-nums text-panel-muted">
            {horaCorta(chat.ultimo?.hora ?? null)}
          </span>
        </span>
        <span className="mt-0.5 flex items-center gap-2">
          <span className="truncate type-panel-caption text-on-surface-variant">
            {vistaPrevia(chat.ultimo)}
          </span>
          {chat.sinLeer > 0 && (
            <span className="ml-auto flex h-5 min-w-5 shrink-0 items-center justify-center rounded-full bg-primary px-1.5 type-panel-caption font-semibold tabular-nums text-on-primary">
              {chat.sinLeer}
            </span>
          )}
        </span>
      </span>
    </button>
  )
}
