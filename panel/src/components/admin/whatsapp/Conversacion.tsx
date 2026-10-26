import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import type { FormEvent, KeyboardEvent } from 'react'
import {
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
} from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import {
  ArrowLeft,
  Check,
  CheckCheck,
  CircleCheck,
  FileText,
  Paperclip,
  RotateCcw,
  Send,
} from 'lucide-react'

import {
  Badge,
  Button,
  IconButton,
  NoSePudoLeer,
  SkeletonList,
  Spinner,
  formatPhone,
} from '@/components/ui'
import { useToast } from '@/components/Toast'
import {
  CLAVE_WHATSAPP,
  consultaAdjunto,
  consultaMensajes,
  descargarAdjunto,
  enviarTexto,
  marcarResuelto,
  textoDelFallo,
} from '@/features/admin/whatsapp/api'
import {
  nombreDelChat,
  rotuloDeQuien,
  ventanaAbierta,
} from '@/features/admin/whatsapp/inbox'
import type { Adjunto, Chat, Mensaje } from '@/features/admin/whatsapp/inbox'
import { diaDe, hora, rotuloDelDia } from './horas'

/** El límite de WhatsApp para un mensaje de texto. */
const MAX_TEXTO = 4096

/**
 * La columna de la derecha: un chat. Cabecera con quién es y si se le puede
 * escribir, los mensajes del más viejo (arriba) al más nuevo (abajo) y, al
 * pie, la caja para contestar.
 */
export function Conversacion({
  chat,
  onVolver,
}: {
  chat: Chat
  onVolver: () => void
}) {
  const toast = useToast()
  const qc = useQueryClient()
  const abierta = ventanaAbierta(chat)

  const resolver = useMutation({
    mutationFn: (resuelto: boolean) => marcarResuelto(chat.waId, resuelto),
    onSuccess: (_, resuelto) => {
      toast(resuelto ? 'Chat marcado como resuelto' : 'Chat reabierto')
      void qc.invalidateQueries({ queryKey: [...CLAVE_WHATSAPP, 'chats'] })
      void qc.invalidateQueries({
        queryKey: [...CLAVE_WHATSAPP, 'chat', chat.waId],
      })
    },
    onError: (e) => toast(textoDelFallo(e)),
  })

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="flex items-center gap-3 border-b border-panel-hairline pb-shell-gap-inner">
        <IconButton
          label="Volver a los chats"
          variant="text"
          onClick={onVolver}
          className="lg:hidden"
        >
          <ArrowLeft size={18} />
        </IconButton>
        <div className="min-w-0 flex-1">
          <p className="truncate type-panel-body font-semibold text-on-surface">
            {nombreDelChat(chat, formatPhone)}
          </p>
          <p className="flex flex-wrap items-center gap-x-2 type-panel-caption text-on-surface-variant">
            {chat.telefono && (
              <span className="tabular-nums">{formatPhone(chat.telefono)}</span>
            )}
            <QuienEnLaCabecera chat={chat} />
          </p>
          {/* En el teléfono las etiquetas bajan debajo del nombre: en la fila,
              con dos de ellas el nombre se quedaba en nada. */}
          {chat.etiquetas.length > 0 && (
            <div className="mt-1 flex flex-wrap gap-1.5 sm:hidden">
              {chat.etiquetas.map((e) => (
                <Badge key={e}>{e}</Badge>
              ))}
            </div>
          )}
        </div>
        {chat.etiquetas.map((e) => (
          <Badge key={e} className="max-sm:hidden">
            {e}
          </Badge>
        ))}
        <Button
          variant="tonal"
          size="sm"
          disabled={resolver.isPending}
          onClick={() => resolver.mutate(!chat.resuelto)}
        >
          {chat.resuelto ? (
            <RotateCcw size={15} aria-hidden />
          ) : (
            <CircleCheck size={15} aria-hidden />
          )}
          {chat.resuelto ? 'Reabrir' : 'Resuelto'}
        </Button>
      </header>

      <Mensajes waId={chat.waId} />

      <Redactar
        waId={chat.waId}
        abierta={abierta}
        ventanaHasta={chat.ventanaHasta}
      />
    </div>
  )
}

const ENLACE = 'underline-offset-2 hover:underline'

/**
 * Quién es para Helios, con el enlace a su ficha: el paciente, o el médico
 * (o su secretaria) y su clínica. Si la base no lo conoce, buscarlo por el
 * teléfono en pacientes.
 */
function QuienEnLaCabecera({ chat }: { chat: Chat }) {
  const q = chat.quien
  if (q?.tipo === 'paciente') {
    const texto = `Paciente${q.nombre ? ` · ${q.nombre}` : ''}`
    return q.profileId ? (
      <Link
        to="/admin/pacientes/$id"
        params={{ id: q.profileId }}
        className={ENLACE}
      >
        {texto}
      </Link>
    ) : (
      <span>{texto}</span>
    )
  }
  if (q?.tipo === 'medico') {
    return (
      <>
        <span>
          {rotuloDeQuien(q)}
          {q.nombre ? ` · ${q.nombre}` : ''}
        </span>
        {q.merchantId && q.clinica && (
          <Link
            to="/admin/clinicas/$id"
            params={{ id: q.merchantId }}
            className={ENLACE}
          >
            {q.clinica}
          </Link>
        )}
      </>
    )
  }
  if (!chat.telefono) return null
  return (
    <Link
      to="/admin/pacientes"
      search={{ q: chat.telefono }}
      className={ENLACE}
    >
      Buscar en pacientes
    </Link>
  )
}

function Mensajes({ waId }: { waId: string }) {
  const consulta = useInfiniteQuery(consultaMensajes(waId))
  const caja = useRef<HTMLDivElement>(null)
  const qc = useQueryClient()

  // Las páginas vienen del más nuevo al más viejo; se pintan al revés.
  const mensajes = (consulta.data?.pages.flatMap((p) => p.filas) ?? [])
    .slice()
    .reverse()
  const masNuevo = mensajes.at(-1)?.id ?? null

  // Abrir un chat lo marca como recibido en el Inbox: la lista deja de
  // contarlo como «sin leer».
  useEffect(() => {
    if (consulta.isSuccess)
      void qc.invalidateQueries({ queryKey: [...CLAVE_WHATSAPP, 'chats'] })
  }, [waId, consulta.isSuccess, qc])

  // Abajo del todo al abrir y cuando llega uno nuevo; no al cargar los anteriores.
  useLayoutEffect(() => {
    const c = caja.current
    if (c) c.scrollTop = c.scrollHeight
  }, [waId, masNuevo])

  if (consulta.isError) {
    return (
      <div className="flex flex-1 items-center justify-center p-6">
        <NoSePudoLeer onReintentar={() => void consulta.refetch()} />
      </div>
    )
  }
  if (consulta.isPending) {
    return (
      <div className="flex-1 p-4">
        <SkeletonList />
      </div>
    )
  }

  return (
    <div
      ref={caja}
      className="min-h-0 flex-1 overflow-y-auto py-shell-gap-inner"
    >
      {consulta.hasNextPage && (
        <div className="mb-shell-gap-inner flex justify-center">
          <Button
            variant="text"
            size="sm"
            disabled={consulta.isFetchingNextPage}
            onClick={() => void consulta.fetchNextPage()}
          >
            {consulta.isFetchingNextPage
              ? 'Cargando…'
              : 'Ver mensajes anteriores'}
          </Button>
        </div>
      )}
      {mensajes.length === 0 ? (
        <p className="py-10 text-center type-panel-body text-panel-muted">
          Este chat aún no tiene mensajes.
        </p>
      ) : (
        <ol className="flex flex-col gap-1.5 px-1">
          {mensajes.map((m, i) => {
            const anterior = i > 0 ? mensajes[i - 1].hora : null
            const nuevoDia =
              m.hora !== null &&
              (anterior === null || diaDe(anterior) !== diaDe(m.hora))
            return (
              <li key={m.id || i} className="flex flex-col">
                {nuevoDia && m.hora !== null && (
                  <span className="my-shell-gap-inner self-center rounded-full bg-panel-control px-3 py-1 type-panel-caption text-on-surface-variant">
                    {rotuloDelDia(m.hora)}
                  </span>
                )}
                <Burbuja mensaje={m} />
              </li>
            )
          })}
        </ol>
      )}
    </div>
  )
}

function Burbuja({ mensaje: m }: { mensaje: Mensaje }) {
  return (
    <div
      className={`max-w-[min(32rem,85%)] rounded-panel-card px-3 py-2 ${
        m.deHelios ? 'self-end bg-primary/14' : 'self-start bg-panel-raised'
      }`}
    >
      {m.rotulo && (
        <p className="type-panel-caption font-semibold text-on-surface-variant">
          {m.rotulo}
        </p>
      )}
      {m.adjunto && <AdjuntoDelMensaje adjunto={m.adjunto} />}
      {m.texto && (
        <p className="whitespace-pre-wrap break-words type-panel-body text-on-surface">
          {m.texto}
        </p>
      )}
      <p className="mt-1 flex items-center justify-end gap-1.5 type-panel-caption text-panel-muted">
        {m.deHelios && m.autor && <span>{m.autor} ·</span>}
        {m.hora !== null && (
          <span className="tabular-nums">{hora(m.hora)}</span>
        )}
        {m.deHelios && m.estado && <MarcaDeEstado estado={m.estado} />}
      </p>
    </div>
  )
}

function MarcaDeEstado({ estado }: { estado: NonNullable<Mensaje['estado']> }) {
  if (estado === 'enviado') return <Check size={14} aria-label="Enviado" />
  return (
    <CheckCheck
      size={14}
      aria-label={estado === 'leido' ? 'Leído' : 'Entregado'}
      className={estado === 'leido' ? 'text-primary' : undefined}
    />
  )
}

/**
 * Una foto, un audio o un sticker se cargan solos (son lo que se mira de un
 * vistazo); un video o un documento, al pulsar. Pasan por la función con la
 * sesión de quien mira: un `<img src>` no podría mandar el token.
 */
function AdjuntoDelMensaje({ adjunto }: { adjunto: Adjunto }) {
  const [pedido, setPedido] = useState(
    adjunto.tipo === 'imagen' ||
      adjunto.tipo === 'audio' ||
      adjunto.tipo === 'sticker',
  )
  const toast = useToast()

  if (!adjunto.id) {
    return adjunto.enlace ? (
      <a
        href={adjunto.enlace}
        target="_blank"
        rel="noreferrer"
        className="type-panel-body underline"
      >
        Abrir el archivo
      </a>
    ) : (
      <p className="type-panel-caption text-panel-muted">
        Archivo no disponible
      </p>
    )
  }

  if (adjunto.tipo === 'documento') {
    const id = adjunto.id
    return (
      <button
        type="button"
        className="mb-1 flex items-center gap-2 rounded-panel-control bg-panel-control px-3 py-2 type-panel-body text-on-surface hover:bg-shell-inset"
        onClick={() => {
          descargarAdjunto(id, adjunto.mime)
            .then((blob) => {
              const url = URL.createObjectURL(blob)
              const a = document.createElement('a')
              a.href = url
              a.download = adjunto.nombreDeArchivo ?? 'documento'
              a.click()
              setTimeout(() => URL.revokeObjectURL(url), 60_000)
            })
            .catch((e: unknown) => toast(textoDelFallo(e)))
        }}
      >
        <FileText size={16} aria-hidden />
        <span className="truncate">
          {adjunto.nombreDeArchivo ?? 'Documento'}
        </span>
      </button>
    )
  }

  if (!pedido) {
    return (
      <Button variant="tonal" size="sm" onClick={() => setPedido(true)}>
        <Paperclip size={15} aria-hidden />
        Ver video
      </Button>
    )
  }

  return <AdjuntoCargado id={adjunto.id} adjunto={adjunto} />
}

function AdjuntoCargado({ id, adjunto }: { id: string; adjunto: Adjunto }) {
  const consulta = useQuery(consultaAdjunto(id, adjunto.mime))
  const [url, setUrl] = useState<string | null>(null)

  useEffect(() => {
    if (!consulta.data) return
    const u = URL.createObjectURL(consulta.data)
    setUrl(u)
    return () => URL.revokeObjectURL(u)
  }, [consulta.data])

  if (consulta.isError)
    return (
      <p className="type-panel-caption text-error">
        {textoDelFallo(consulta.error)}
      </p>
    )
  if (!url) return <Spinner className="my-2" />

  switch (adjunto.tipo) {
    case 'audio':
      return <audio controls src={url} className="mb-1 max-w-full" />
    case 'video':
      return (
        <video
          controls
          src={url}
          className="mb-1 max-h-80 max-w-full rounded-panel-control"
        />
      )
    case 'sticker':
      return (
        <img src={url} alt="Sticker" className="mb-1 size-32 object-contain" />
      )
    default:
      return (
        <a href={url} target="_blank" rel="noreferrer">
          <img
            src={url}
            alt="Foto del chat"
            className="mb-1 max-h-80 max-w-full rounded-panel-control object-contain"
          />
        </a>
      )
  }
}

/**
 * La caja para contestar. Dentro de la ventana de 24 h, texto libre; fuera,
 * WhatsApp solo deja mandar una plantilla, así que se apaga y lo explica.
 * Enter manda; Mayús+Enter, salto de línea.
 */
function Redactar({
  waId,
  abierta,
  ventanaHasta,
}: {
  waId: string
  abierta: boolean
  ventanaHasta: number | null
}) {
  const [texto, setTexto] = useState('')
  const toast = useToast()
  const qc = useQueryClient()

  // Cada chat tiene su borrador: cambiar de chat no se lleva el texto.
  useEffect(() => setTexto(''), [waId])

  const enviar = useMutation({
    mutationFn: (t: string) => enviarTexto(waId, t),
    onSuccess: () => {
      setTexto('')
      void qc.invalidateQueries({
        queryKey: [...CLAVE_WHATSAPP, 'mensajes', waId],
      })
      void qc.invalidateQueries({ queryKey: [...CLAVE_WHATSAPP, 'chats'] })
    },
    onError: (e) => {
      toast(textoDelFallo(e))
      // Un 453 quiere decir que la ventana se cerró mientras se escribía.
      void qc.invalidateQueries({ queryKey: [...CLAVE_WHATSAPP, 'chats'] })
    },
  })

  const limpio = texto.trim()
  const puede =
    abierta && limpio !== '' && limpio.length <= MAX_TEXTO && !enviar.isPending

  function mandar(e?: FormEvent) {
    e?.preventDefault()
    if (puede) enviar.mutate(limpio)
  }

  function alTeclear(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault()
      mandar()
    }
  }

  if (!abierta) {
    return (
      <div className="border-t border-panel-hairline pt-shell-gap-inner">
        <p className="rounded-panel-control bg-panel-control px-3 py-2.5 type-panel-body text-on-surface-variant">
          {ventanaHasta === null
            ? 'Este contacto aún no ha escrito: WhatsApp solo deja empezar la conversación con una plantilla.'
            : 'Pasaron más de 24 horas desde su último mensaje: WhatsApp solo deja escribirle con una plantilla. Cuando vuelva a escribir, podrás contestar aquí.'}
        </p>
      </div>
    )
  }

  return (
    <form
      onSubmit={mandar}
      className="flex items-end gap-2 border-t border-panel-hairline pt-shell-gap-inner"
    >
      <label htmlFor="redactar" className="sr-only">
        Mensaje
      </label>
      <textarea
        id="redactar"
        rows={2}
        value={texto}
        maxLength={MAX_TEXTO}
        onChange={(e) => setTexto(e.target.value)}
        onKeyDown={alTeclear}
        placeholder="Escribe un mensaje"
        className="max-h-40 min-h-[2.75rem] flex-1 resize-none rounded-panel-control border border-transparent bg-panel-control px-panel-pad-control py-2.5 type-panel-body text-on-surface outline-none placeholder:text-placeholder focus:border-primary"
      />
      <Button type="submit" size="md" disabled={!puede}>
        {enviar.isPending ? <Spinner /> : <Send size={16} aria-hidden />}
        Enviar
      </Button>
    </form>
  )
}
