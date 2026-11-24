import { useLayoutEffect, useRef, useState } from 'react'
import type { FormEvent, KeyboardEvent } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Paperclip, RotateCcw, Send, Smartphone, X } from 'lucide-react'

import {
  Badge,
  Button,
  Card,
  EmptyState,
  ErrorBox,
  Select,
  SkeletonCard,
  formatPhone,
} from '@/components/ui'
import {
  CLAVE_COMPRAS,
  consultaDiagnosticoSimulador,
  consultaMedicosSimulador,
  consultaMensajesSimulador,
} from '@/features/admin/compras/consultas'
import {
  reiniciarSimulador,
  subirCapturaSimulador,
  turnoSimulador,
} from '@/features/admin/compras/simulador'
import type { MedicoSimulador } from '@/features/admin/compras/tipos'
import { motivoDeArchivo } from '@/features/admin/pagosRegistrados/registrarPago'
import { describeError } from '@/lib/supabase'
import { Burbuja } from './simulador/Burbuja'
import type { HojaAbierta, Respuesta } from './simulador/Burbuja'
import { Inspector } from './simulador/Inspector'
import { HojaDeLista } from './simulador/Lista'

/**
 * Simulador de WhatsApp de Compras Amazon. No implementa el bot: cada turno va a la Edge
 * Function `compras-simulador`, que corre el flujo real; aquí solo se elige al médico, se
 * mandan los turnos y se leen los mensajes que quedaron en la base.
 */
export function SimuladorWhatsAppCompras() {
  const medicos = useQuery(consultaMedicosSimulador())
  const [clave, setClave] = useState('')

  if (medicos.isPending) return <SkeletonCard />
  if (medicos.isError) {
    return (
      <ErrorBox
        title="No se pudieron cargar los médicos para el simulador"
        detail={describeError(medicos.error)}
      />
    )
  }
  if (medicos.data.length === 0) {
    return (
      <EmptyState
        icon={<Smartphone size={44} />}
        title="No hay médicos con WhatsApp registrado"
        description="Registra el número de WhatsApp de al menos un médico para probar el simulador."
      />
    )
  }

  const medico = medicos.data.find((m) => m.key === clave) ?? medicos.data[0]
  return (
    <div className="flex flex-col gap-shell-gap-inner">
      <Select
        id="sim-medico"
        label="Médico simulado"
        value={medico.key}
        options={medicos.data.map((m) => ({
          value: m.key,
          label: `${m.merchantName}${m.doctorName ? ` · ${m.doctorName}` : ''} (${formatPhone(m.phone)})`,
        }))}
        onChange={setClave}
        className="max-w-xl"
      />
      <Conversacion key={medico.key} medico={medico} />
    </div>
  )
}

function Conversacion({ medico }: { medico: MedicoSimulador }) {
  const queryClient = useQueryClient()
  const { phone } = medico
  const mensajes = useQuery(consultaMensajesSimulador(phone))
  const diagnostico = useQuery(consultaDiagnosticoSimulador())

  const [borrador, setBorrador] = useState('')
  // La ruta se conserva tras subir: un reintento no vuelve a subir ni deja archivos huérfanos.
  const [captura, setCaptura] = useState<{
    file: File
    ruta: string | null
  } | null>(null)
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [estado, setEstado] = useState<string | null>(null)
  const [hoja, setHoja] = useState<HojaAbierta | null>(null)
  const enVuelo = useRef(false)
  const logRef = useRef<HTMLDivElement>(null)
  const archivoRef = useRef<HTMLInputElement>(null)

  const lista = mensajes.data ?? []
  const ultimoId = lista.at(-1)?.id ?? null
  useLayoutEffect(() => {
    const el = logRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [ultimoId])

  async function ejecutar(
    accion: () => Promise<string | null>,
    alExito?: () => void,
  ) {
    if (enVuelo.current) return
    enVuelo.current = true
    setOcupado(true)
    setError(null)
    try {
      setEstado(await accion())
      alExito?.()
      await queryClient.invalidateQueries({ queryKey: CLAVE_COMPRAS })
    } catch (e) {
      setError(
        describeError(e) ?? 'No se pudo completar el turno del simulador.',
      )
    } finally {
      enVuelo.current = false
      setOcupado(false)
    }
  }

  function enviar() {
    const texto = borrador.trim()
    if (!texto && !captura) return
    void ejecutar(
      async () => {
        let adjunto: { receipt_path: string } | undefined
        if (captura) {
          const ruta =
            captura.ruta ?? (await subirCapturaSimulador(captura.file))
          setCaptura({ file: captura.file, ruta })
          adjunto = { receipt_path: ruta }
        }
        const r = await turnoSimulador({
          phone,
          texto: texto || undefined,
          adjunto,
        })
        return r.estado
      },
      () => {
        setBorrador('')
        setCaptura(null)
      },
    )
  }

  function responder(respuesta: Respuesta) {
    setHoja(null)
    void ejecutar(
      async () => (await turnoSimulador({ phone, respuesta })).estado,
    )
  }

  function reiniciar() {
    void ejecutar(async () => {
      await reiniciarSimulador(phone)
      return null
    })
  }

  function elegirArchivo(file: File | undefined) {
    if (!file) return
    const motivo = motivoDeArchivo(file)
    if (motivo) setError(motivo)
    else setCaptura({ file, ruta: null })
  }

  function alTeclear(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault()
      enviar()
    }
  }

  function alEnviar(e: FormEvent) {
    e.preventDefault()
    enviar()
  }

  return (
    <div className="grid grid-cols-1 gap-shell-gap-inner lg:grid-cols-[minmax(0,1fr)_20rem]">
      <Card className="flex h-[clamp(20rem,calc(100dvh_-_18rem),44rem)] flex-col gap-3">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <Badge tone={mensajes.isError ? 'error' : 'success'} icono>
            {mensajes.isError ? 'Sin conexión' : 'En vivo · cada 4 s'}
          </Badge>
          <Button
            size="sm"
            variant="tonal"
            disabled={ocupado}
            onClick={reiniciar}
          >
            <RotateCcw size={14} aria-hidden /> Reiniciar conversación
          </Button>
        </div>

        <div className="relative flex min-h-0 flex-1 flex-col">
          <div
            ref={logRef}
            role="log"
            aria-live="polite"
            aria-label="Conversación con el bot"
            className="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto rounded-panel-control bg-shell-inset p-3"
          >
            {mensajes.isError && (
              <ErrorBox
                title="No se pudieron leer los mensajes"
                detail={describeError(mensajes.error)}
              />
            )}
            {mensajes.isSuccess && lista.length === 0 && (
              <p className="m-auto text-center type-panel-body text-on-surface-variant">
                Escribe «Hola» o «Comprar» como lo haría el médico.
              </p>
            )}
            {lista.map((m) => (
              <Burbuja
                key={m.id}
                m={m}
                ocupado={ocupado}
                onResponder={responder}
                onAbrirLista={setHoja}
              />
            ))}
          </div>
          {hoja && (
            <HojaDeLista
              titulo={hoja.button}
              secciones={hoja.sections}
              onElegir={responder}
              onCerrar={() => setHoja(null)}
            />
          )}
        </div>

        {error && <ErrorBox title="El turno no se completó" detail={error} />}

        <form onSubmit={alEnviar} className="flex flex-col gap-2">
          {captura && (
            <p className="flex items-center gap-2 type-panel-caption text-on-surface-variant">
              <Paperclip size={12} aria-hidden />
              <span className="truncate">{captura.file.name}</span>
              <button
                type="button"
                aria-label="Quitar la captura"
                disabled={ocupado}
                onClick={() => setCaptura(null)}
              >
                <X size={12} aria-hidden />
              </button>
            </p>
          )}
          <div className="flex items-end gap-2">
            <input
              ref={archivoRef}
              type="file"
              accept="image/*,application/pdf"
              className="hidden"
              onChange={(e) => {
                elegirArchivo(e.target.files?.[0])
                e.target.value = ''
              }}
            />
            <Button
              size="md"
              variant="tonal"
              disabled={ocupado}
              onClick={() => archivoRef.current?.click()}
            >
              <Paperclip size={15} aria-hidden /> Captura
            </Button>
            <textarea
              aria-label="Mensaje del médico"
              value={borrador}
              onChange={(e) => setBorrador(e.target.value)}
              onKeyDown={alTeclear}
              rows={1}
              maxLength={1000}
              placeholder="Escribe como el médico…"
              className="max-h-32 min-h-[2.75rem] flex-1 resize-none rounded-panel-control border border-transparent bg-panel-control px-panel-pad-control py-2.5 type-panel-body text-on-surface outline-none placeholder:text-placeholder focus:border-primary"
            />
            <Button
              size="md"
              type="submit"
              disabled={ocupado || (!borrador.trim() && !captura)}
              motivoApagado={
                ocupado ? 'Esperando la respuesta del bot…' : undefined
              }
            >
              <Send size={15} aria-hidden /> {ocupado ? 'Enviando…' : 'Enviar'}
            </Button>
          </div>
        </form>
      </Card>

      <Inspector
        medico={medico}
        diagnostico={diagnostico.data}
        errorDiagnostico={
          diagnostico.isError
            ? (describeError(diagnostico.error) ?? 'Sin respuesta')
            : null
        }
        estado={estado}
        mensajes={lista.length}
      />
    </div>
  )
}
