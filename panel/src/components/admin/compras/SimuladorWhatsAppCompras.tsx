import { Fragment, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import type { FormEvent, KeyboardEvent, ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  ArrowUpRight,
  CheckCheck,
  ImagePlus,
  Paperclip,
  RefreshCw,
  RotateCcw,
  Send,
  ShieldAlert,
  Smartphone,
  Sparkles,
  Star,
  X,
} from 'lucide-react'

import { hora } from '@/components/admin/whatsapp/horas'
import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Callout,
  Card,
  Chip,
  DataLabel,
  EmptyState,
  ErrorBox,
  Select,
  SkeletonCard,
  SkeletonList,
  claseDeBoton,
  formatBcvRate,
  formatPhone,
  formatUsd,
  formatVes,
} from '@/components/ui'
import { BANKS } from '@/features/admin/banks'
import {
  agregarMensajeSimulador,
  crearSolicitudSimulador,
  enlaceDelComprobanteDePago,
  reiniciarSimulador,
  reportarPagoSimulador,
  subirComprobanteCompra,
} from '@/features/admin/compras/api'
import {
  buscarEnCatalogoMock,
  buscarProductoPorAsin,
  cotizarProductoCompra,
  elegirEnvioSugerido,
} from '@/features/admin/compras/catalogoMock'
import type { ProductoCatalogoMock } from '@/features/admin/compras/catalogoMock'
import {
  CLAVE_COMPRAS,
  consultaAjustesCompras,
  consultaMedicosSimulador,
  consultaMensajesSimulador,
  consultaSolicitudesSimulador,
} from '@/features/admin/compras/consultas'
import { etiquetaDeEnvio } from '@/features/admin/compras/estados'
import type {
  AjustesComprasConfig,
  BotonSimulador,
  MensajeSimulador,
  MetodoEnvioCompra,
  MetodoPagoCompra,
  SolicitudCompraResumen,
  TarjetaCarruselSimulador,
} from '@/features/admin/compras/tipos'
import { comoFila, filas, numero, numeroONulo, texto, textoONulo, booleano } from '@/lib/json'
import { leerMonto } from '@/lib/montos'
import { describeError } from '@/lib/supabase'
import { EstadoSolicitudCompraBadge } from './EstadoCompraBadge'

type EstadoSesionSim =
  | 'menu'
  | 'compra_buscar'
  | 'compra_resultados'
  | 'compra_envio'
  | 'compra_confirmar'
  | 'compra_pago'
  | 'compra_pago_datos'

type ContextoSesionSim = {
  estado: EstadoSesionSim
  producto: ProductoCatalogoMock | null
  shippingMethod: MetodoEnvioCompra
  requestIdPago: string | null
  metodoPago: MetodoPagoCompra
}

const CONTEXTO_INICIAL: ContextoSesionSim = {
  estado: 'menu',
  producto: null,
  shippingMethod: 'aereo',
  requestIdPago: null,
  metodoPago: 'pago_movil',
}

const CHIPS_PRUEBA: ReadonlyArray<{ label: string; texto: string }> = [
  { label: 'Estetoscopio Littmann', texto: 'Estetoscopio Littmann' },
  { label: 'Pegar link Amazon', texto: 'https://www.amazon.com/dp/B07S2H3XBB' },
  { label: 'Equipo pesado (marítimo)', texto: 'Equipo pesado (marítimo)' },
  { label: 'Insumo restringido', texto: 'Insumo restringido' },
  { label: 'Mis compras', texto: 'Mis compras' },
]

const AJUSTES_RESPALDO: AjustesComprasConfig = {
  taxUsaPct: 7,
  serviceFeePct: 10,
  airRatePerLbUsd: 6.5,
  airMinUsd: 15,
  seaRatePerFt3Usd: 28,
  seaMinUsd: 35,
  fallbackWeightLb: 1.5,
  quoteTtlHours: 24,
  catalogProvider: 'mock',
  isEnabled: true,
  bcvRateToday: null,
  updatedAt: null,
}

export function SimuladorWhatsAppCompras() {
  const queryClient = useQueryClient()
  const avisar = useToast()

  const medicosQuery = useQuery(consultaMedicosSimulador())
  const ajustesQuery = useQuery(consultaAjustesCompras())
  const ajustes = ajustesQuery.data ?? AJUSTES_RESPALDO

  const [claveElegida, setClaveElegida] = useState('')
  const medicos = medicosQuery.data ?? []
  const medicoActivo = useMemo(
    () => medicos.find((m) => m.key === claveElegida) ?? medicos.at(0) ?? null,
    [medicos, claveElegida],
  )
  const phone = medicoActivo?.phone ?? ''

  const mensajesQuery = useQuery(consultaMensajesSimulador(phone))
  const solicitudesQuery = useQuery(consultaSolicitudesSimulador(phone))

  const [ctx, setCtx] = useState<ContextoSesionSim>(CONTEXTO_INICIAL)
  const [borrador, setBorrador] = useState('')
  const [archivoPendiente, setArchivoPendiente] = useState<File | null>(null)
  const [procesando, setProcesando] = useState(false)
  const [errorFlujo, setErrorFlujo] = useState<string | null>(null)

  const cajaMensajesRef = useRef<HTMLDivElement>(null)
  const inputArchivoRef = useRef<HTMLInputElement>(null)

  // Al cambiar de médico, limpiamos el contexto efímero del bot
  useEffect(() => {
    setCtx(CONTEXTO_INICIAL)
    setBorrador('')
    setArchivoPendiente(null)
    setErrorFlujo(null)
  }, [phone])

  const mensajes = mensajesQuery.data ?? []
  const ultimoId = mensajes.at(-1)?.id ?? null

  useLayoutEffect(() => {
    const el = cajaMensajesRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [phone, ultimoId, mensajes.length])

  function refrescarTodo() {
    void queryClient.invalidateQueries({ queryKey: CLAVE_COMPRAS })
  }

  const reiniciar = useMutation({
    mutationFn: () => reiniciarSimulador(phone),
    onSuccess: () => {
      setCtx(CONTEXTO_INICIAL)
      setArchivoPendiente(null)
      setErrorFlujo(null)
      refrescarTodo()
      avisar('Conversación del simulador reiniciada.')
    },
    onError: (e) => avisar(describeError(e) ?? 'No se pudo reiniciar el chat'),
  })

  async function enviarComoMedico(textoCrudo: string, adjunto: File | null = null) {
    if (!medicoActivo || procesando) return
    const limpio = textoCrudo.trim()
    if (!limpio && !adjunto) return

    setProcesando(true)
    setErrorFlujo(null)
    try {
      await procesarTurnoUsuario({
        texto: limpio,
        adjunto,
        medico: medicoActivo,
        ajustes,
        ctx,
        solicitudes: solicitudesQuery.data ?? [],
        onActualizarCtx: setCtx,
      })
      setBorrador('')
      setArchivoPendiente(null)
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: [...CLAVE_COMPRAS, 'sim', 'mensajes', phone] }),
        queryClient.invalidateQueries({ queryKey: [...CLAVE_COMPRAS, 'sim', 'solicitudes', phone] }),
        queryClient.invalidateQueries({ queryKey: [...CLAVE_COMPRAS, 'conteos'] }),
        queryClient.invalidateQueries({ queryKey: [...CLAVE_COMPRAS, 'lista'] }),
        queryClient.invalidateQueries({ queryKey: [...CLAVE_COMPRAS, 'pagos'] }),
      ])
    } catch (e) {
      setErrorFlujo(describeError(e) ?? 'No se pudo procesar el mensaje en el simulador.')
    } finally {
      setProcesando(false)
    }
  }

  async function pulsarBotonBot(actionId: string, tituloBoton: string) {
    if (!medicoActivo || procesando) return
    setProcesando(true)
    setErrorFlujo(null)
    try {
      await procesarAccionInteractiva({
        actionId,
        tituloBoton,
        medico: medicoActivo,
        ajustes,
        ctx,
        solicitudes: solicitudesQuery.data ?? [],
        onActualizarCtx: setCtx,
      })
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: [...CLAVE_COMPRAS, 'sim', 'mensajes', phone] }),
        queryClient.invalidateQueries({ queryKey: [...CLAVE_COMPRAS, 'sim', 'solicitudes', phone] }),
        queryClient.invalidateQueries({ queryKey: [...CLAVE_COMPRAS, 'conteos'] }),
        queryClient.invalidateQueries({ queryKey: [...CLAVE_COMPRAS, 'lista'] }),
        queryClient.invalidateQueries({ queryKey: [...CLAVE_COMPRAS, 'pagos'] }),
      ])
    } catch (e) {
      setErrorFlujo(describeError(e) ?? 'No se pudo ejecutar la acción del simulador.')
    } finally {
      setProcesando(false)
    }
  }

  async function generarCapturaDePrueba() {
    const req = buscarSolicitudParaPagar(ctx.requestIdPago, solicitudesQuery.data ?? [])
    const archivo = await crearImagenComprobantePrueba({
      codigo: req?.code ?? '#C-DEMO',
      montoVes:
        req?.totalVesToday ??
        req?.totalVesQuote ??
        (req && ajustes.bcvRateToday ? req.totalUsd * ajustes.bcvRateToday : 15420.5),
      referencia: String(Math.floor(100000 + Math.random() * 899999)),
    })
    setArchivoPendiente(archivo)
    avisar('Captura de comprobante de prueba generada. Pulsa Enviar para adjuntarla.')
  }

  function alEnviarFormulario(e: FormEvent) {
    e.preventDefault()
    void enviarComoMedico(borrador, archivoPendiente)
  }

  function alTeclear(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault()
      void enviarComoMedico(borrador, archivoPendiente)
    }
  }

  if (medicosQuery.isPending) return <SkeletonCard />

  if (medicosQuery.isError) {
    return (
      <ErrorBox
        title="No se pudieron cargar los médicos para el simulador"
        detail={describeError(medicosQuery.error)}
      />
    )
  }

  if (medicos.length === 0) {
    return (
      <EmptyState
        icon={<Smartphone size={44} />}
        title="No hay médicos con teléfono registrado"
        description="Afilia al menos una clínica con número de WhatsApp para probar el simulador interactivo."
      />
    )
  }

  return (
    <div className="flex flex-col gap-shell-gap-inner">
      {/* Barra superior del simulador */}
      <Card className="flex flex-col gap-4">
        <div className="flex flex-wrap items-end gap-3">
          <Select
            id="sim-medico"
            label="Médico / Clínica simulada"
            value={medicoActivo?.key ?? ''}
            options={medicos.map((m) => ({
              value: m.key,
              label: `${m.merchantName}${m.doctorName ? ` · ${m.doctorName}` : ''} (${formatPhone(m.phone)})`,
            }))}
            onChange={setClaveElegida}
            className="min-w-64 flex-1"
          />

          <Badge tone="warning" icono={Smartphone} className="self-center">
            Modo Simulador (sin envío real a 360dialog)
          </Badge>

          <div className="ml-auto flex flex-wrap gap-2">
            <Button
              size="sm"
              variant="tonal"
              disabled={mensajesQuery.isFetching || solicitudesQuery.isFetching}
              onClick={refrescarTodo}
            >
              <RefreshCw
                size={14}
                aria-hidden
                className={mensajesQuery.isFetching ? 'animate-spin' : undefined}
              />
              Refrescar mensajes
            </Button>
            <Button
              size="sm"
              variant="text"
              disabled={reiniciar.isPending || !phone}
              onClick={() => reiniciar.mutate()}
            >
              <RotateCcw size={14} aria-hidden />
              Reiniciar chat
            </Button>
          </div>
        </div>

        {/* Chips rápidos de prueba */}
        <div className="flex flex-wrap items-center gap-2 border-t border-panel-hairline pt-3">
          <span className="type-panel-caption font-semibold text-on-surface-variant">
            Pruebas rápidas:
          </span>
          {CHIPS_PRUEBA.map((chip) => (
            <Chip
              key={chip.label}
              onClick={() => {
                if (!procesando) void enviarComoMedico(chip.texto)
              }}
            >
              {chip.label}
            </Chip>
          ))}
        </div>
      </Card>

      {errorFlujo && <ErrorBox title="Error en el simulador" detail={errorFlujo} />}

      {/* Vista dividida 2 columnas: Chat WhatsApp + Inspector técnico */}
      <div className="grid grid-cols-1 gap-shell-gap-block lg:grid-cols-[minmax(0,1fr)_22rem]">
        {/* Izquierda: Chat WhatsApp simulado */}
        <Card className="flex h-[calc(100dvh-16rem)] min-h-[34rem] flex-col p-0 overflow-hidden">
          {/* Cabecera estilo WhatsApp */}
          <header className="flex items-center justify-between gap-3 border-b border-panel-hairline bg-panel-raised px-4 py-3">
            <div className="flex min-w-0 items-center gap-3">
              <div className="flex size-10 shrink-0 items-center justify-center rounded-full bg-primary/14 type-panel-body font-bold text-on-surface">
                H
              </div>
              <div className="min-w-0">
                <p className="truncate type-panel-body font-semibold text-on-surface">
                  Helios Compras · Bot WhatsApp
                </p>
                <p className="truncate type-panel-caption text-on-surface-variant">
                  Chateando como {medicoActivo?.merchantName} ({formatPhone(phone)})
                </p>
              </div>
            </div>
            <Badge tone="success">En línea</Badge>
          </header>

          {/* Lista de mensajes */}
          <div
            ref={cajaMensajesRef}
            className="min-h-0 flex-1 overflow-y-auto bg-panel-card px-4 py-4"
          >
            {mensajesQuery.isPending ? (
              <SkeletonList rows={3} />
            ) : mensajes.length === 0 ? (
              <div className="flex h-full flex-col items-center justify-center gap-3 py-8 text-center">
                <Sparkles size={32} className="text-panel-muted" aria-hidden />
                <div className="max-w-sm">
                  <p className="type-panel-body font-semibold text-on-surface">
                    Inicia una prueba como {medicoActivo?.merchantName}
                  </p>
                  <p className="mt-1 type-panel-caption text-on-surface-variant">
                    Escribe un producto médico (ej. «Estetoscopio Littmann»), pega un link de Amazon
                    o pulsa cualquiera de los chips de prueba de arriba.
                  </p>
                </div>
                <Button
                  size="sm"
                  variant="tonal"
                  disabled={procesando}
                  onClick={() => void enviarComoMedico('Hola')}
                >
                  Enviar «Hola» al bot
                </Button>
              </div>
            ) : (
              <ol className="flex flex-col gap-2.5">
                {mensajes.map((m) => (
                  <li key={m.id} className="flex flex-col">
                    <BurbujaSimulada
                      mensaje={m}
                      deshabilitado={procesando}
                      onPulsarBoton={(id, label) => void pulsarBotonBot(id, label)}
                    />
                  </li>
                ))}
              </ol>
            )}
          </div>

          {/* Barra de archivo adjunto pendiente */}
          {archivoPendiente && (
            <div className="flex items-center justify-between gap-2 border-t border-panel-hairline bg-panel-raised px-4 py-2">
              <div className="flex min-w-0 items-center gap-2">
                <Paperclip size={14} className="shrink-0 text-on-surface-variant" aria-hidden />
                <span className="truncate type-panel-caption text-on-surface">
                  Comprobante listo: {archivoPendiente.name}
                </span>
              </div>
              <button
                type="button"
                aria-label="Quitar captura"
                onClick={() => setArchivoPendiente(null)}
                className="text-on-surface-variant hover:text-on-surface"
              >
                <X size={15} />
              </button>
            </div>
          )}

          {/* Composer inferior */}
          <form
            onSubmit={alEnviarFormulario}
            className="flex flex-wrap items-end gap-2 border-t border-panel-hairline bg-panel-raised px-3 py-3"
          >
            <input
              ref={inputArchivoRef}
              type="file"
              accept="image/*,application/pdf"
              className="hidden"
              onChange={(e) => {
                const file = e.target.files?.[0] ?? null
                if (file) setArchivoPendiente(file)
                e.target.value = ''
              }}
            />

            <Button
              type="button"
              size="sm"
              variant="tonal"
              disabled={procesando}
              title="Adjuntar captura real desde tu equipo"
              onClick={() => inputArchivoRef.current?.click()}
            >
              <Paperclip size={15} aria-hidden />
              Adjuntar
            </Button>

            <Button
              type="button"
              size="sm"
              variant="text"
              disabled={procesando}
              title="Generar una captura PNG de pago ficticia para probar la subida"
              onClick={() => void generarCapturaDePrueba()}
            >
              <ImagePlus size={15} aria-hidden />
              Captura prueba
            </Button>

            <label htmlFor="sim-composer" className="sr-only">
              Mensaje del médico
            </label>
            <textarea
              id="sim-composer"
              rows={1}
              value={borrador}
              onChange={(e) => setBorrador(e.target.value)}
              onKeyDown={alTeclear}
              placeholder={
                ctx.estado === 'compra_pago_datos'
                  ? 'Ej: Banesco 482910 12500 (o adjunta captura)'
                  : 'Escribe un mensaje como médico (Enter envía)…'
              }
              className="max-h-28 min-h-10 flex-1 resize-none rounded-panel-control border border-transparent bg-panel-control px-3 py-2 type-panel-body text-on-surface outline-none placeholder:text-placeholder focus:border-primary"
            />

            <Button
              type="submit"
              size="md"
              disabled={procesando || (!borrador.trim() && !archivoPendiente)}
            >
              <Send size={15} aria-hidden />
              {procesando ? 'Enviando…' : 'Enviar'}
            </Button>
          </form>
        </Card>

        {/* Derecha: Inspector técnico en vivo */}
        <aside className="flex flex-col gap-4">
          <Card className="flex flex-col gap-3">
            <div className="flex items-center justify-between gap-2">
              <DataLabel>Inspector de sesión</DataLabel>
              <Badge tone="brand">En vivo</Badge>
            </div>
            <dl className="grid grid-cols-1 gap-2.5">
              <div className="rounded-panel-control bg-panel-raised px-3 py-2">
                <dt className="type-panel-caption text-on-surface-variant">Estado de la sesión</dt>
                <dd className="mt-0.5 font-mono type-panel-body font-semibold text-on-surface">
                  {ctx.estado}
                </dd>
              </div>
              <div className="rounded-panel-control bg-panel-raised px-3 py-2">
                <dt className="type-panel-caption text-on-surface-variant">Proveedor activo</dt>
                <dd className="mt-0.5 font-mono type-panel-body text-on-surface">
                  {ajustes.catalogProvider === 'mock'
                    ? 'MockAmazonProvider (24 ítems)'
                    : `${ajustes.catalogProvider} (fallback mock en simulador)`}
                </dd>
              </div>
              <div className="rounded-panel-control bg-panel-raised px-3 py-2">
                <dt className="type-panel-caption text-on-surface-variant">Tasa BCV en vivo</dt>
                <dd className="mt-0.5 type-panel-body font-semibold tabular-nums text-on-surface">
                  {ajustes.bcvRateToday !== null
                    ? formatBcvRate(ajustes.bcvRateToday)
                    : 'Sin tasa cargada'}
                </dd>
              </div>
            </dl>
            <Callout tone="info" titulo="Ciclo completo en vivo">
              Las solicitudes y pagos creados aquí se guardan en Supabase. Abre la ficha en
              Superadmin, aprueba aduana o concilia el pago y vuelve a pulsar «Refrescar mensajes».
            </Callout>
          </Card>

          <Card className="flex flex-col gap-3">
            <div className="flex items-center justify-between gap-2">
              <DataLabel>Solicitudes de este médico</DataLabel>
              <Badge tone="neutral">{solicitudesQuery.data?.length ?? 0}</Badge>
            </div>

            {solicitudesQuery.isPending && <SkeletonList rows={2} />}

            {solicitudesQuery.data && solicitudesQuery.data.length === 0 && (
              <p className="type-panel-caption text-on-surface-variant">
                Todavía no has confirmado ninguna solicitud en esta sesión.
              </p>
            )}

            {solicitudesQuery.data && solicitudesQuery.data.length > 0 && (
              <ul className="flex max-h-96 flex-col gap-2.5 overflow-y-auto pr-0.5">
                {solicitudesQuery.data.map((req) => (
                  <li
                    key={req.id}
                    className="flex flex-col gap-2 rounded-panel-control border border-panel-hairline bg-panel-raised p-3"
                  >
                    <div className="flex items-center justify-between gap-2">
                      <span className="font-mono type-panel-caption font-bold text-on-surface">
                        {req.code}
                      </span>
                      <EstadoSolicitudCompraBadge valor={req.status} />
                    </div>
                    <p className="line-clamp-2 type-panel-caption text-on-surface">
                      {req.productTitle}
                    </p>
                    <div className="flex items-center justify-between gap-2">
                      <span className="type-panel-caption font-semibold tabular-nums text-on-surface">
                        {formatUsd(req.totalUsd)}
                      </span>
                      <Link
                        to="/admin/compras/$id"
                        params={{ id: req.id }}
                        className={claseDeBoton('tonal', 'sm')}
                      >
                        Abrir en Superadmin <ArrowUpRight size={13} aria-hidden />
                      </Link>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </Card>
        </aside>
      </div>
    </div>
  )
}

// ── Renderizado de burbujas, botones interactivos y carrusel ───────────────

function BurbujaSimulada({
  mensaje,
  deshabilitado,
  onPulsarBoton,
}: {
  mensaje: MensajeSimulador
  deshabilitado: boolean
  onPulsarBoton: (id: string, title: string) => void
}) {
  // En el simulador la vista es desde el teléfono del médico:
  // 'in' = mensaje enviado POR el médico (derecha, bg-primary/14)
  // 'out' = mensaje enviado POR el bot Helios (izquierda, bg-panel-raised)
  const delMedico = mensaje.direction === 'in'
  const payload = mensaje.payload
  const botones = leerBotonesPayload(payload)
  const tarjetas = leerCarruselPayload(payload)
  const receiptPath = payload ? textoONulo(payload.receipt_path) : null
  const ms = new Date(mensaje.createdAt).getTime()

  return (
    <div className={`flex flex-col gap-1.5 ${delMedico ? 'items-end' : 'items-start'}`}>
      <div
        className={`max-w-[min(34rem,88%)] rounded-panel-card px-3.5 py-2.5 ${
          delMedico ? 'bg-primary/14' : 'border border-panel-hairline bg-panel-raised'
        }`}
      >
        {receiptPath && <PreviaCapturaEnChat ruta={receiptPath} />}

        {mensaje.body && (
          <p className="whitespace-pre-wrap break-words type-panel-body text-on-surface">
            {renderizarTextoNegritas(mensaje.body)}
          </p>
        )}

        <p className="mt-1 flex items-center justify-end gap-1 type-panel-caption text-panel-muted">
          {!delMedico && <span>Helios Bot ·</span>}
          <span className="tabular-nums">{Number.isFinite(ms) ? hora(ms) : ''}</span>
          {delMedico && <CheckCheck size={14} className="text-primary" aria-hidden />}
        </p>
      </div>

      {/* Botones interactivos WhatsApp (máx 3) */}
      {!delMedico && botones.length > 0 && (
        <div className="flex max-w-[min(34rem,88%)] flex-wrap gap-1.5">
          {botones.slice(0, 3).map((b) => (
            <button
              key={b.id}
              type="button"
              disabled={deshabilitado}
              onClick={() => onPulsarBoton(b.id, b.title)}
              className="rounded-panel-control border border-panel-hairline bg-panel-card px-3.5 py-2 type-panel-caption font-semibold text-on-surface transition-colors duration-[var(--transition-fast)] hover:bg-panel-control disabled:opacity-45"
            >
              {b.title}
            </button>
          ))}
        </div>
      )}

      {/* Carrusel horizontal de Media Cards (WhatsApp Interactive Carousel) */}
      {!delMedico && tarjetas.length > 0 && (
        <div className="flex w-full max-w-full gap-3 overflow-x-auto pb-2 pt-1">
          {tarjetas.map((card) => (
            <div
              key={card.asin}
              className="flex w-64 shrink-0 flex-col overflow-hidden rounded-panel-card border border-panel-hairline bg-panel-card"
            >
              <div className="relative h-36 w-full bg-panel-raised">
                {card.imageUrl && (
                  <img
                    src={card.imageUrl}
                    alt={card.title}
                    className="size-full object-cover"
                  />
                )}
                {card.restricted && (
                  <span className="absolute left-2 top-2">
                    <Badge tone="warning" icono={ShieldAlert}>
                      Aduana
                    </Badge>
                  </span>
                )}
              </div>

              <div className="flex flex-1 flex-col gap-1.5 p-3">
                <p className="line-clamp-2 type-panel-caption font-semibold text-on-surface">
                  {card.title}
                </p>
                <p className="flex items-center gap-1 type-panel-caption text-on-surface-variant">
                  <Star size={12} className="text-warning" aria-hidden />
                  <span className="tabular-nums">{card.rating.toFixed(1)}</span>
                  <span>({card.reviewCount.toLocaleString('es-VE')})</span>
                </p>
                <div className="mt-1 rounded-panel-control bg-panel-raised p-2">
                  <p className="type-panel-caption text-on-surface-variant">
                    Amazon: <span className="font-semibold text-on-surface">{formatUsd(card.priceUsd)}</span>
                  </p>
                  <p className="type-panel-caption font-semibold text-on-surface">
                    Puesto en VE: ~{formatUsd(card.estimatedDeliveredUsd)}
                  </p>
                  {card.estimatedDeliveredVes !== null && (
                    <p className="type-panel-caption text-panel-muted">
                      ≈ {formatVes(card.estimatedDeliveredVes)}
                    </p>
                  )}
                  <p className="mt-0.5 type-panel-caption text-panel-muted">{card.shippingHint}</p>
                </div>
                <Button
                  size="sm"
                  className="mt-auto w-full"
                  disabled={deshabilitado}
                  onClick={() => onPulsarBoton(card.actionId, `Cotizar ${card.asin}`)}
                >
                  {card.actionLabel}
                </Button>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

function PreviaCapturaEnChat({ ruta }: { ruta: string }) {
  const [url, setUrl] = useState<string | null>(null)

  useEffect(() => {
    let viva = true
    enlaceDelComprobanteDePago(ruta)
      .then((u) => {
        if (viva) setUrl(u)
      })
      .catch(() => {
        if (viva) setUrl(null)
      })
    return () => {
      viva = false
    }
  }, [ruta])

  if (!url) {
    return (
      <div className="mb-2 flex items-center gap-2 rounded-panel-control bg-panel-control px-3 py-2 type-panel-caption text-on-surface-variant">
        <Paperclip size={13} aria-hidden /> Comprobante adjunto
      </div>
    )
  }

  return (
    <a href={url} target="_blank" rel="noopener noreferrer" className="mb-2 block">
      <img
        src={url}
        alt="Comprobante de pago enviado"
        className="max-h-52 w-full rounded-panel-control border border-panel-hairline object-contain bg-panel-card"
      />
    </a>
  )
}

/** Convierte `*texto*` en `<strong>texto</strong>` sin HTML crudo. */
function renderizarTextoNegritas(textoOriginal: string): ReactNode {
  const partes = textoOriginal.split(/(\*[^*\n]+\*)/g)
  return partes.map((parte, i) => {
    if (parte.startsWith('*') && parte.endsWith('*') && parte.length > 2) {
      return (
        <strong key={i} className="font-semibold text-on-surface">
          {parte.slice(1, -1)}
        </strong>
      )
    }
    return <Fragment key={i}>{parte}</Fragment>
  })
}

function leerBotonesPayload(payload: Record<string, unknown> | null): BotonSimulador[] {
  if (!payload) return []
  return filas(payload.buttons)
    .map((b) => ({ id: texto(b.id), title: texto(b.title) }))
    .filter((b) => b.id !== '' && b.title !== '')
}

function leerCarruselPayload(payload: Record<string, unknown> | null): TarjetaCarruselSimulador[] {
  if (!payload) return []
  return filas(payload.cards)
    .map((c) => {
      const r = comoFila(c)
      return {
        asin: texto(r.asin),
        title: texto(r.title),
        imageUrl: textoONulo(r.imageUrl ?? r.image_url),
        rating: numero(r.rating) || 4.7,
        reviewCount: numero(r.reviewCount ?? r.review_count),
        priceUsd: numero(r.priceUsd ?? r.price_usd),
        estimatedDeliveredUsd: numero(r.estimatedDeliveredUsd ?? r.estimated_delivered_usd),
        estimatedDeliveredVes: numeroONulo(r.estimatedDeliveredVes ?? r.estimated_delivered_ves),
        shippingHint: texto(r.shippingHint ?? r.shipping_hint),
        restricted: booleano(r.restricted),
        weightEstimated: booleano(r.weightEstimated ?? r.weight_estimated),
        actionId: texto(r.actionId ?? r.action_id),
        actionLabel: texto(r.actionLabel ?? r.action_label, 'Cotizar'),
      }
    })
    .filter((c) => c.asin !== '' && c.actionId !== '')
}

// ── Motor puro del bot en el Simulador (persiste 100% vía RPCs) ────────────

async function procesarTurnoUsuario({
  texto: entrada,
  adjunto,
  medico,
  ajustes,
  ctx,
  solicitudes,
  onActualizarCtx,
}: {
  texto: string
  adjunto: File | null
  medico: { merchantId: string; merchantName: string; phone: string }
  ajustes: AjustesComprasConfig
  ctx: ContextoSesionSim
  solicitudes: SolicitudCompraResumen[]
  onActualizarCtx: (next: ContextoSesionSim) => void
}) {
  const normal = entrada.toLowerCase().trim()

  // Si estamos esperando pago o mandó adjunto con una solicitud pendiente de pago
  const solicitudPendientePago = buscarSolicitudParaPagar(ctx.requestIdPago, solicitudes)
  if ((ctx.estado === 'compra_pago_datos' || adjunto !== null) && solicitudPendientePago) {
    let receiptPath: string | null = null
    if (adjunto) {
      receiptPath = await subirComprobanteCompra({
        requestId: solicitudPendientePago.id,
        file: adjunto,
      })
    }

    await agregarMensajeSimulador({
      phone: medico.phone,
      direction: 'in',
      kind: receiptPath ? 'image' : 'text',
      body: entrada || 'Comprobante de pago adjunto',
      payload: receiptPath ? { receipt_path: receiptPath } : null,
    })

    const parseado = parsearDatosPagoTexto(entrada, solicitudPendientePago, ajustes)
    await reportarPagoSimulador({
      requestId: solicitudPendientePago.id,
      method: ctx.metodoPago,
      bank: parseado.bank,
      reference: parseado.reference,
      payerPhone: medico.phone,
      amountVes: parseado.amountVes,
      receiptPath,
      note: 'Reportado desde Simulador WhatsApp',
    })

    await agregarMensajeSimulador({
      phone: medico.phone,
      direction: 'out',
      kind: 'buttons',
      body:
        `Recibimos tu reporte de pago para *${solicitudPendientePago.code}*:\n` +
        `• Banco: *${parseado.bank}*\n` +
        `• Referencia: *${parseado.reference}*\n` +
        `• Monto: *${formatVes(parseado.amountVes)}*\n\n` +
        `Nuestro equipo lo conciliará en breve y te avisaremos por aquí apenas quede confirmado.`,
      payload: {
        buttons: [
          { id: 'mis_compras', title: 'Mis compras' },
          { id: 'buscar_nuevo', title: 'Cotizar otro producto' },
        ],
      },
    })
    onActualizarCtx({ ...CONTEXTO_INICIAL, estado: 'menu' })
    return
  }

  // Registramos el mensaje del médico
  await agregarMensajeSimulador({
    phone: medico.phone,
    direction: 'in',
    kind: 'text',
    body: entrada,
    payload: null,
  })

  if (normal === 'hola' || normal === 'menu' || normal === 'menú' || normal === 'inicio') {
    await enviarMenuPrincipal(medico.phone, medico.merchantName)
    onActualizarCtx({ ...CONTEXTO_INICIAL, estado: 'menu' })
    return
  }

  if (normal.includes('mis compras') || normal.includes('mis pedidos') || normal === 'estado') {
    await enviarResumenCompras(medico.phone, solicitudes)
    onActualizarCtx({ ...ctx, estado: 'menu' })
    return
  }

  // Cualquier otro texto o link de Amazon dispara búsqueda en catálogo
  await ejecutarBusquedaCatalogo({
    consulta: entrada,
    phone: medico.phone,
    ajustes,
    onActualizarCtx,
  })
}

async function procesarAccionInteractiva({
  actionId,
  tituloBoton,
  medico,
  ajustes,
  ctx,
  solicitudes,
  onActualizarCtx,
}: {
  actionId: string
  tituloBoton: string
  medico: { merchantId: string; merchantName: string; phone: string }
  ajustes: AjustesComprasConfig
  ctx: ContextoSesionSim
  solicitudes: SolicitudCompraResumen[]
  onActualizarCtx: (next: ContextoSesionSim) => void
}) {
  // Registramos la selección del médico como mensaje entrante
  await agregarMensajeSimulador({
    phone: medico.phone,
    direction: 'in',
    kind: 'text',
    body: tituloBoton,
    payload: { action_id: actionId },
  })

  if (actionId === 'menu' || actionId === 'cancelar') {
    await enviarMenuPrincipal(medico.phone, medico.merchantName)
    onActualizarCtx({ ...CONTEXTO_INICIAL, estado: 'menu' })
    return
  }

  if (actionId === 'buscar_nuevo') {
    await agregarMensajeSimulador({
      phone: medico.phone,
      direction: 'out',
      kind: 'text',
      body: '¿Qué equipo o insumo médico buscas en Amazon? Escribe el nombre o pega directamente el enlace del producto.',
      payload: null,
    })
    onActualizarCtx({ ...CONTEXTO_INICIAL, estado: 'compra_buscar' })
    return
  }

  if (actionId === 'como_funciona') {
    await agregarMensajeSimulador({
      phone: medico.phone,
      direction: 'out',
      kind: 'buttons',
      body:
        `*¿Cómo funcionan las Compras Amazon con Helios?*\n\n` +
        `1. Buscas el producto o pegas el link de Amazon.\n` +
        `2. Te cotizamos puesto en Venezuela (Amazon + Tax USA + envío aéreo o marítimo + tarifa de gestión).\n` +
        `3. Pagas en bolívares a tasa BCV del día por Pago Móvil o transferencia.\n` +
        `4. Compramos, importamos y te avisamos cada paso hasta la entrega.`,
      payload: {
        buttons: [
          { id: 'buscar_nuevo', title: 'Buscar en Amazon' },
          { id: 'mis_compras', title: 'Mis compras' },
        ],
      },
    })
    onActualizarCtx({ ...CONTEXTO_INICIAL, estado: 'menu' })
    return
  }

  if (actionId === 'mis_compras') {
    await enviarResumenCompras(medico.phone, solicitudes)
    onActualizarCtx({ ...CONTEXTO_INICIAL, estado: 'menu' })
    return
  }

  if (actionId.startsWith('cotizar:')) {
    const asin = actionId.slice('cotizar:'.length)
    const prod = buscarProductoPorAsin(asin) ?? buscarEnCatalogoMock(asin, 1).at(0) ?? null
    if (!prod) {
      await agregarMensajeSimulador({
        phone: medico.phone,
        direction: 'out',
        kind: 'text',
        body: 'No encontré ese producto en el catálogo. Intenta otra búsqueda.',
        payload: null,
      })
      return
    }
    const cotAir = cotizarProductoCompra({
      unitPriceUsd: prod.priceUsd,
      quantity: 1,
      weightLb: prod.weightLb,
      volumetricWeightLb: prod.volumetricWeightLb,
      volumeFt3: prod.volumeFt3,
      weightEstimated: prod.weightEstimated,
      shippingMethod: 'aereo',
      ajustes,
    })
    const cotSea = cotizarProductoCompra({
      unitPriceUsd: prod.priceUsd,
      quantity: 1,
      weightLb: prod.weightLb,
      volumetricWeightLb: prod.volumetricWeightLb,
      volumeFt3: prod.volumeFt3,
      weightEstimated: prod.weightEstimated,
      shippingMethod: 'maritimo',
      ajustes,
    })
    const sugerido = elegirEnvioSugerido(prod, 1)

    await agregarMensajeSimulador({
      phone: medico.phone,
      direction: 'out',
      kind: 'buttons',
      body:
        `*${prod.title}*\n` +
        `ASIN: ${prod.asin}${prod.variantLabel ? ` · ${prod.variantLabel}` : ''}\n\n` +
        `Elige cómo deseas traerlo a Venezuela:\n` +
        `✈️ *Aéreo (7–10 días)*: ${formatUsd(cotAir.totalUsd)}${cotAir.totalVes !== null ? ` (≈ ${formatVes(cotAir.totalVes)})` : ''}\n` +
        `🚢 *Marítimo (3–4 semanas)*: ${formatUsd(cotSea.totalUsd)}${cotSea.totalVes !== null ? ` (≈ ${formatVes(cotSea.totalVes)})` : ''}` +
        (sugerido === 'maritimo' ? `\n\n💡 _Recomendado *Marítimo* por peso/volumen._` : '') +
        (prod.weightEstimated
          ? `\n\n⚠️ _Amazon no listó el peso exacto; usamos un estimado de ${ajustes.fallbackWeightLb} lb._`
          : ''),
      payload: {
        buttons: [
          { id: 'envio:aereo', title: '✈️ Envío Aéreo' },
          { id: 'envio:maritimo', title: '🚢 Envío Marítimo' },
          { id: 'buscar_nuevo', title: 'Buscar otro' },
        ],
      },
    })
    onActualizarCtx({
      ...ctx,
      estado: 'compra_envio',
      producto: prod,
      shippingMethod: sugerido,
    })
    return
  }

  if (actionId === 'envio:aereo' || actionId === 'envio:maritimo') {
    const prod = ctx.producto
    if (!prod) {
      await enviarMenuPrincipal(medico.phone, medico.merchantName)
      return
    }
    const method: MetodoEnvioCompra = actionId === 'envio:maritimo' ? 'maritimo' : 'aereo'
    const cot = cotizarProductoCompra({
      unitPriceUsd: prod.priceUsd,
      quantity: 1,
      weightLb: prod.weightLb,
      volumetricWeightLb: prod.volumetricWeightLb,
      volumeFt3: prod.volumeFt3,
      weightEstimated: prod.weightEstimated,
      shippingMethod: method,
      ajustes,
    })

    const avisoAduana = prod.restrictedFlag
      ? `\n\n⚠️ *Revisión aduanal:* ${prod.restrictedReason ?? 'Este insumo requiere validación de nuestro equipo antes de habilitar el pago.'}`
      : ''

    await agregarMensajeSimulador({
      phone: medico.phone,
      direction: 'out',
      kind: 'buttons',
      body:
        `*Resumen de cotización (${etiquetaDeEnvio(method)})*\n` +
        `${prod.title}\n\n` +
        `• Producto Amazon: ${formatUsd(cot.subtotalUsd)}\n` +
        `• Tax USA (${ajustes.taxUsaPct} %): ${formatUsd(cot.taxUsaUsd)}\n` +
        `• Envío ${etiquetaDeEnvio(method)}: ${formatUsd(cot.shippingUsd)}\n` +
        `• Tarifa de gestión (${ajustes.serviceFeePct} %): ${formatUsd(cot.serviceFeeUsd)}\n` +
        `*Total: ${formatUsd(cot.totalUsd)}*` +
        (cot.totalVes !== null && cot.bcvRate !== null
          ? `\nEquivalente hoy: *${formatVes(cot.totalVes)}* (BCV ${cot.bcvRate.toLocaleString('es-VE', { maximumFractionDigits: 4 })} Bs/$)`
          : '') +
        avisoAduana,
      payload: {
        buttons: [
          { id: 'confirmar_solicitud', title: 'Confirmar solicitud' },
          {
            id: method === 'aereo' ? 'envio:maritimo' : 'envio:aereo',
            title: method === 'aereo' ? 'Cambiar a Marítimo' : 'Cambiar a Aéreo',
          },
          { id: 'cancelar', title: 'Cancelar' },
        ],
      },
    })
    onActualizarCtx({ ...ctx, estado: 'compra_confirmar', shippingMethod: method })
    return
  }

  if (actionId === 'confirmar_solicitud') {
    const prod = ctx.producto
    if (!prod) {
      await enviarMenuPrincipal(medico.phone, medico.merchantName)
      return
    }
    const creada = await crearSolicitudSimulador({
      merchantId: medico.merchantId,
      phone: medico.phone,
      asin: prod.asin,
      productTitle: prod.title,
      productUrl: prod.productUrl,
      imageUrl: prod.imageUrl,
      variantLabel: prod.variantLabel,
      quantity: 1,
      category: prod.category,
      weightLb: prod.weightLb,
      volumetricWeightLb: prod.volumetricWeightLb,
      volumeFt3: prod.volumeFt3,
      weightEstimated: prod.weightEstimated,
      restrictedFlag: prod.restrictedFlag,
      restrictedReason: prod.restrictedReason,
      shippingMethod: ctx.shippingMethod,
      unitPriceUsd: prod.priceUsd,
    })

    if (creada.status === 'revision_aduanal') {
      await agregarMensajeSimulador({
        phone: medico.phone,
        direction: 'out',
        kind: 'buttons',
        body:
          `✅ Solicitud *${creada.code}* registrada en *Revisión aduanal*.\n\n` +
          `Nuestro equipo validará el permiso aduanal para este artículo y te avisaremos por aquí apenas quede habilitado para pago.`,
        payload: {
          buttons: [
            { id: 'mis_compras', title: 'Mis compras' },
            { id: 'buscar_nuevo', title: 'Cotizar otro' },
          ],
        },
      })
      onActualizarCtx({ ...CONTEXTO_INICIAL, estado: 'menu' })
      return
    }

    const montoBs =
      creada.totalVesToday ??
      creada.totalVesQuote ??
      (ajustes.bcvRateToday ? Math.round(creada.totalUsd * ajustes.bcvRateToday * 100) / 100 : null)

    await agregarMensajeSimulador({
      phone: medico.phone,
      direction: 'out',
      kind: 'buttons',
      body: creada.paymentBlock
        ? `✅ Solicitud *${creada.code}* confirmada.\n\n${creada.paymentBlock}`
        : `✅ Solicitud *${creada.code}* confirmada por *${formatUsd(creada.totalUsd)}*` +
          (montoBs !== null ? ` (*${formatVes(montoBs)}* hoy)` : '') +
          `.\n\nCuando realices el pago en bolívares, pulsa *Reportar pago ahora* para enviarnos la referencia y la captura.`,
      payload: {
        buttons: [
          { id: `pagar:${creada.id}`, title: 'Reportar pago ahora' },
          { id: 'mis_compras', title: 'Mis compras' },
          { id: 'menu', title: 'Menú' },
        ],
      },
    })
    onActualizarCtx({
      ...CONTEXTO_INICIAL,
      estado: 'compra_pago',
      requestIdPago: creada.id,
    })
    return
  }

  if (actionId.startsWith('pagar:')) {
    const reqId = actionId.slice('pagar:'.length)
    await agregarMensajeSimulador({
      phone: medico.phone,
      direction: 'out',
      kind: 'buttons',
      body: '¿Con qué método en bolívares realizaste el pago?',
      payload: {
        buttons: [
          { id: `metodo_pago:pago_movil:${reqId}`, title: 'Pago Móvil' },
          { id: `metodo_pago:transferencia:${reqId}`, title: 'Transferencia' },
          { id: 'menu', title: 'Cancelar' },
        ],
      },
    })
    onActualizarCtx({ ...ctx, estado: 'compra_pago', requestIdPago: reqId })
    return
  }

  if (actionId.startsWith('metodo_pago:')) {
    const [, metodoRaw, reqId] = actionId.split(':')
    const metodo: MetodoPagoCompra = metodoRaw === 'transferencia' ? 'transferencia' : 'pago_movil'
    const req = buscarSolicitudParaPagar(reqId, solicitudes)
    const montoSugerido =
      req?.totalVesToday ??
      req?.totalVesQuote ??
      (req && ajustes.bcvRateToday ? Math.round(req.totalUsd * ajustes.bcvRateToday * 100) / 100 : null)

    await agregarMensajeSimulador({
      phone: medico.phone,
      direction: 'out',
      kind: 'buttons',
      body:
        `Perfecto (*${metodo === 'transferencia' ? 'Transferencia' : 'Pago Móvil'}*).\n` +
        `Envíame la captura del comprobante (puedes usar *Adjuntar* o *Captura prueba* abajo) o escribe *Banco, Referencia y Monto en Bs*.` +
        (montoSugerido !== null
          ? `\nEjemplo: _Banesco 482910 ${montoSugerido.toFixed(2)}_`
          : '\nEjemplo: _Banesco 482910 15420,50_'),
      payload: {
        buttons: [
          { id: `pago_rapido:${reqId}:${metodo}`, title: 'Enviar pago de prueba' },
          { id: 'menu', title: 'Cancelar' },
        ],
      },
    })
    onActualizarCtx({
      ...ctx,
      estado: 'compra_pago_datos',
      requestIdPago: reqId,
      metodoPago: metodo,
    })
    return
  }

  if (actionId.startsWith('pago_rapido:')) {
    const [, reqId, metodoRaw] = actionId.split(':')
    const metodo: MetodoPagoCompra = metodoRaw === 'transferencia' ? 'transferencia' : 'pago_movil'
    const req = buscarSolicitudParaPagar(reqId, solicitudes)
    if (!req) {
      await enviarResumenCompras(medico.phone, solicitudes)
      return
    }
    const ref = String(Math.floor(100000 + Math.random() * 899999))
    const montoBs =
      req.totalVesToday ??
      req.totalVesQuote ??
      (ajustes.bcvRateToday ? Math.round(req.totalUsd * ajustes.bcvRateToday * 100) / 100 : Math.round(req.totalUsd * 65 * 100) / 100)

    const archivo = await crearImagenComprobantePrueba({
      codigo: req.code,
      montoVes: montoBs,
      referencia: ref,
    })
    const receiptPath = await subirComprobanteCompra({ requestId: req.id, file: archivo })

    await agregarMensajeSimulador({
      phone: medico.phone,
      direction: 'in',
      kind: 'image',
      body: `Banesco · Ref. ${ref} · ${formatVes(montoBs)}`,
      payload: { receipt_path: receiptPath },
    })

    await reportarPagoSimulador({
      requestId: req.id,
      method: metodo,
      bank: 'Banesco',
      reference: ref,
      payerPhone: medico.phone,
      amountVes: montoBs,
      receiptPath,
      note: 'Pago de prueba enviado desde Simulador WhatsApp',
    })

    await agregarMensajeSimulador({
      phone: medico.phone,
      direction: 'out',
      kind: 'buttons',
      body:
        `✅ Comprobante recibido para *${req.code}*.\n` +
        `• Banco: *Banesco*\n` +
        `• Referencia: *${ref}*\n` +
        `• Monto: *${formatVes(montoBs)}*\n\n` +
        `Ya aparece en la cola de conciliación del Superadmin.`,
      payload: {
        buttons: [
          { id: 'mis_compras', title: 'Mis compras' },
          { id: 'buscar_nuevo', title: 'Cotizar otro' },
        ],
      },
    })
    onActualizarCtx({ ...CONTEXTO_INICIAL, estado: 'menu' })
  }
}

async function enviarMenuPrincipal(phone: string, merchantName: string) {
  await agregarMensajeSimulador({
    phone,
    direction: 'out',
    kind: 'buttons',
    body:
      `Hola *${merchantName}* 👋\n` +
      `Bienvenido al canal de *Compras Amazon de Helios*. Traemos equipos e insumos médicos directo a Venezuela pagando en bolívares a tasa BCV.`,
    payload: {
      buttons: [
        { id: 'buscar_nuevo', title: 'Buscar en Amazon' },
        { id: 'mis_compras', title: 'Mis compras' },
        { id: 'como_funciona', title: 'Cómo funciona' },
      ],
    },
  })
}

async function enviarResumenCompras(phone: string, solicitudes: SolicitudCompraResumen[]) {
  if (solicitudes.length === 0) {
    await agregarMensajeSimulador({
      phone,
      direction: 'out',
      kind: 'buttons',
      body: 'Todavía no tienes solicitudes de compra registradas.',
      payload: {
        buttons: [{ id: 'buscar_nuevo', title: 'Buscar en Amazon' }],
      },
    })
    return
  }

  const top = solicitudes.slice(0, 5)
  const lineas = top.map(
    (s) =>
      `• *${s.code}* — ${s.productTitle.slice(0, 48)}${s.productTitle.length > 48 ? '…' : ''}\n  Estado: *${s.status.replaceAll('_', ' ')}* · ${formatUsd(s.totalUsd)}`,
  )
  const pendiente = solicitudes.find((s) => s.status === 'esperando_pago')

  const botones: BotonSimulador[] = []
  if (pendiente) {
    botones.push({ id: `pagar:${pendiente.id}`, title: `Pagar ${pendiente.code}` })
  }
  botones.push({ id: 'buscar_nuevo', title: 'Cotizar otro' })

  await agregarMensajeSimulador({
    phone,
    direction: 'out',
    kind: 'buttons',
    body: `*Tus compras recientes:*\n\n${lineas.join('\n\n')}`,
    payload: { buttons: botones.slice(0, 3) },
  })
}

async function ejecutarBusquedaCatalogo({
  consulta,
  phone,
  ajustes,
  onActualizarCtx,
}: {
  consulta: string
  phone: string
  ajustes: AjustesComprasConfig
  onActualizarCtx: (next: ContextoSesionSim) => void
}) {
  const resultados = buscarEnCatalogoMock(consulta, 5)

  if (resultados.length === 0) {
    await agregarMensajeSimulador({
      phone,
      direction: 'out',
      kind: 'buttons',
      body: `No encontré resultados para «${consulta}». Prueba con otro término (ej. estetoscopio, oxímetro, tensiómetro, camilla) o pega directamente el enlace de Amazon.`,
      payload: {
        buttons: [
          { id: 'buscar_nuevo', title: 'Intentar de nuevo' },
          { id: 'menu', title: 'Menú principal' },
        ],
      },
    })
    onActualizarCtx({ ...CONTEXTO_INICIAL, estado: 'compra_buscar' })
    return
  }

  const cards: TarjetaCarruselSimulador[] = resultados.map((p) => {
    const sugerido = elegirEnvioSugerido(p, 1)
    const cot = cotizarProductoCompra({
      unitPriceUsd: p.priceUsd,
      quantity: 1,
      weightLb: p.weightLb,
      volumetricWeightLb: p.volumetricWeightLb,
      volumeFt3: p.volumeFt3,
      weightEstimated: p.weightEstimated,
      shippingMethod: sugerido,
      ajustes,
    })
    return {
      asin: p.asin,
      title: p.title,
      imageUrl: p.imageUrl,
      rating: p.rating,
      reviewCount: p.reviewCount,
      priceUsd: p.priceUsd,
      estimatedDeliveredUsd: cot.totalUsd,
      estimatedDeliveredVes: cot.totalVes,
      shippingHint:
        sugerido === 'maritimo'
          ? `Sugerido Marítimo (${cot.billableVolumeFt3} ft³)`
          : `Sugerido Aéreo (${cot.billableWeightLb} lb${cot.weightEstimated ? ' est.' : ''})`,
      restricted: p.restrictedFlag,
      weightEstimated: p.weightEstimated,
      actionId: `cotizar:${p.asin}`,
      actionLabel: 'Cotizar',
    }
  })

  await agregarMensajeSimulador({
    phone,
    direction: 'out',
    kind: 'carousel',
    body: `Encontré *${cards.length}* ${cards.length === 1 ? 'opción' : 'opciones'} en Amazon para «${consulta}». Desliza el carrusel y pulsa *Cotizar* en la que prefieras:`,
    payload: { cards },
  })

  onActualizarCtx({
    ...CONTEXTO_INICIAL,
    estado: 'compra_resultados',
  })
}

function buscarSolicitudParaPagar(
  requestId: string | null,
  solicitudes: SolicitudCompraResumen[],
): SolicitudCompraResumen | null {
  if (requestId) {
    const encontrada = solicitudes.find((s) => s.id === requestId)
    if (encontrada) return encontrada
  }
  return solicitudes.find((s) => s.status === 'esperando_pago') ?? null
}

function parsearDatosPagoTexto(
  textoUsuario: string,
  req: SolicitudCompraResumen,
  ajustes: AjustesComprasConfig,
): { bank: string; reference: string; amountVes: number } {
  const lower = textoUsuario.toLowerCase()
  const bancoEncontrado =
    BANKS.find((b) => lower.includes(b.name.toLowerCase()) || lower.includes(b.code))?.name ??
    'Banesco'

  const refMatch = textoUsuario.match(/\b(\d{5,12})\b/)
  const reference = refMatch
    ? refMatch[1]
    : String(Math.floor(100000 + Math.random() * 899999))

  // Buscar un posible monto distinto de la referencia
  const sinRef = refMatch ? textoUsuario.replace(refMatch[0], ' ') : textoUsuario
  const posiblesMontos = sinRef.match(/\d[\d.,]+/g) ?? []
  let amountVes: number | null = null
  for (const candidato of posiblesMontos) {
    const n = leerMonto(candidato)
    if (n !== null && n > 10) {
      amountVes = n
      break
    }
  }

  const fallbackVes =
    req.totalVesToday ??
    req.totalVesQuote ??
    (ajustes.bcvRateToday ? Math.round(req.totalUsd * ajustes.bcvRateToday * 100) / 100 : Math.round(req.totalUsd * 65 * 100) / 100)

  return {
    bank: bancoEncontrado,
    reference,
    amountVes: amountVes ?? fallbackVes,
  }
}

/** Genera una imagen PNG realista de comprobante bancario en un `<canvas>` local. */
async function crearImagenComprobantePrueba(params: {
  codigo: string
  montoVes: number
  referencia: string
}): Promise<File> {
  const canvas = document.createElement('canvas')
  canvas.width = 560
  canvas.height = 360
  const ctx = canvas.getContext('2d')
  if (ctx) {
    ctx.fillStyle = 'white'
    ctx.fillRect(0, 0, canvas.width, canvas.height)
    ctx.fillStyle = 'midnightblue'
    ctx.fillRect(0, 0, canvas.width, 72)
    ctx.fillStyle = 'white'
    ctx.font = 'bold 22px system-ui, sans-serif'
    ctx.fillText('Comprobante Pago Móvil · Simulador', 28, 45)

    ctx.fillStyle = 'darkslategray'
    ctx.font = 'bold 28px system-ui, sans-serif'
    ctx.fillText(formatVes(params.montoVes), 28, 136)

    ctx.fillStyle = 'slategray'
    ctx.font = '18px system-ui, sans-serif'
    ctx.fillText(`Referencia: ${params.referencia}`, 28, 188)
    ctx.fillText(`Banco origen: Banesco (0134) → BNC (0191)`, 28, 224)
    ctx.fillText(`Concepto: Compra Amazon ${params.codigo}`, 28, 260)
    ctx.fillText(`Operación generada en Modo Simulador`, 28, 312)
  }

  const blob = await new Promise<Blob>((resolve, reject) => {
    canvas.toBlob((b) => {
      if (b) resolve(b)
      else reject(new Error('No se pudo generar la captura PNG.'))
    }, 'image/png')
  })
  return new File([blob], `comprobante-${params.referencia}.png`, { type: 'image/png' })
}
