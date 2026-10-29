import { useEffect, useRef, useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { CircleCheck, FilePlus2, Mail, MessageCircle, XCircle } from 'lucide-react'

import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Callout,
  Card,
  DataLabel,
  ErrorBox,
  Tecla,
  claseDeBoton,
  formatMoneda,
} from '@/components/ui'
import { COMPROBANTE, esperaAlPaciente, fraseDelComprobante } from '@/features/merchant/registro'
import type { EstadoDelComprobante, Financiamiento } from '@/features/merchant/registro'
import { fetchFinanciamiento, reenviarComprobante } from '@/features/merchant/registroApi'
import { describeError } from '@/lib/supabase'

import { BotonConFoco } from './Campo'
import { ConfirmacionDelPaciente } from './ConfirmacionDelPaciente'
import { DesgloseDelServicio, PlanDePagos } from './PlanDePagos'

/**
 * PASO 5 · REGISTRADO.
 *
 * El número de orden, el paciente, sus cuotas y qué pasó con el comprobante
 * (plan §2.1, pasos 5-7). El comprobante sale solo al confirmar; «Reenviar» es
 * para cuando el paciente dice que no le llegó, y va al correo REGISTRADO:
 * la clínica no puede cambiarlo (lo corrige Helios).
 *
 * Con la confirmación del paciente, la orden llega aquí PENDIENTE: la pantalla
 * espera su «Sí» (`ConfirmacionDelPaciente`) y vuelve a pedir el
 * orden cada pocos segundos hasta que acepta, rechaza o vence.
 *
 * El foco cae en «Registrar otro», que es lo siguiente que se hace en una
 * recepción con cola.
 */
export function PasoListo({
  financiamiento,
  coincide,
  conFicha,
  onOtro,
  onRegistrarElQueQueria,
}: {
  financiamiento: Financiamiento
  /**
   * `false` si la base devolvió un alta anterior con la misma clave: la
   * respuesta de aquel alta se perdió y esto no es lo que se acaba de pedir.
   */
  coincide: boolean
  /** La secretaria que solo registra no abre la ficha de la orden. */
  conFicha: boolean
  onOtro: () => void
  onRegistrarElQueQueria: () => void
}) {
  const avisar = useToast()
  const queryClient = useQueryClient()
  const otroRef = useRef<HTMLButtonElement>(null)

  // Lo último que se sabe de la orden. Mientras espera al paciente se vuelve
  // a pedir; en cuanto responde (o vence) se deja de preguntar.
  const actual = useQuery({
    queryKey: ['financiamiento', financiamiento.id],
    queryFn: () => fetchFinanciamiento(financiamiento.id),
    initialData: financiamiento,
    refetchInterval: (q) => (q.state.data && esperaAlPaciente(q.state.data) ? 4_000 : false),
    refetchIntervalInBackground: true,
  })
  const f = actual.data

  const [comprobante, setComprobante] = useState<{
    estado: EstadoDelComprobante | null
    correo: string | null
  }>({ estado: f.receipt, correo: f.emailEnmascarado })

  // Al pasar de esperar a confirmado (o rechazado, o vencido), lo que se sabe
  // del comprobante es lo nuevo, y las listas del panel ya no están al día.
  const statusAnterior = useRef(f.status)
  useEffect(() => {
    if (f.status === statusAnterior.current) return
    statusAnterior.current = f.status
    setComprobante({ estado: f.receipt, correo: f.emailEnmascarado })
    if (f.status === 'confirmed') avisar('El paciente aceptó: pago en cuotas confirmado')
    void queryClient.invalidateQueries({ queryKey: ['merchant-transactions'] })
    void queryClient.invalidateQueries({ queryKey: ['merchant-transactions-summary'] })
    void queryClient.invalidateQueries({ queryKey: ['comisiones'] })
  }, [f.status, f.receipt, f.emailEnmascarado, avisar, queryClient])

  useEffect(() => {
    otroRef.current?.focus()
  }, [])

  const reenvio = useMutation({
    mutationFn: () => reenviarComprobante(financiamiento.id),
    onSuccess: (r) => {
      const correo = r.emailEnmascarado ?? comprobante.correo
      setComprobante({ estado: r.status ?? 'pendiente', correo })
      avisar(`Comprobante reenviado${correo ? ` a ${correo}` : ''}`)
    },
  })

  const estado = comprobante.estado
  const confirmado = f.status === 'confirmed'
  const titulo = confirmado
    ? `Orden #${f.orderNumber} registrada`
    : f.status === 'pending'
      ? `Orden #${f.orderNumber} enviada al paciente`
      : f.status === 'expired'
        ? `Orden #${f.orderNumber} vencida`
        : `Orden #${f.orderNumber} no confirmada`
  const Icono = confirmado ? CircleCheck : f.status === 'pending' ? MessageCircle : XCircle
  const colorDelIcono = confirmado
    ? 'text-success'
    : f.status === 'pending'
      ? 'text-on-surface-variant'
      : 'text-error'

  return (
    <div className="flex flex-col gap-5">
      {!coincide && (
        <Callout
          tone="warning"
          titulo="Esto es un pago en cuotas que ya estaba registrado"
          accion={
            <Button size="sm" variant="tonal" onClick={onRegistrarElQueQueria}>
              Registrar el que querías
            </Button>
          }
        >
          La conexión falló en un intento anterior y ese pago en cuotas sí se había
          registrado: es este. No se creó uno nuevo con los datos que acabas de confirmar.
        </Callout>
      )}

      <Card variant="hero" className="flex flex-col gap-5">
        <div className="flex items-start gap-3">
          <Icono size={28} aria-hidden className={`mt-1 shrink-0 ${colorDelIcono}`} />
          <div className="min-w-0">
            <p role="status" className="type-panel-page text-on-surface">
              {titulo}
            </p>
            <p className="mt-1 type-panel-body text-on-surface-variant">
              {f.patientName ?? 'Paciente'}
              {f.documentoEnmascarado && ` · ${f.documentoEnmascarado}`}
              {f.beneficiaryName && ` · atendido: ${f.beneficiaryName}`}
            </p>
          </div>
        </div>

        <div>
          <DataLabel>{f.concept ?? 'Consulta'} · lo que cobra la clínica</DataLabel>
          <p className="mt-1 type-panel-hero tabular-nums text-on-surface">
            {formatMoneda(f.merchantSaleCur, f.moneda)}
          </p>
        </div>

        {f.cuotas.length > 0 && (
          <div>
            <DataLabel className="mb-2">Las cuotas del paciente</DataLabel>
            <PlanDePagos cuotas={f.cuotas} moneda={f.moneda} />
          </div>
        )}

        <DesgloseDelServicio
          base={f.merchantSaleCur}
          feePct={f.feePct}
          fee={f.feeCur}
          feeVat={f.feeVatCur}
          moneda={f.moneda}
          concepto={f.concept}
        />

        <ConfirmacionDelPaciente
          financiamiento={f}
          onCambio={(nuevo) => queryClient.setQueryData(['financiamiento', f.id], nuevo)}
        />

        {confirmado && (
          <div className="flex flex-wrap items-center gap-3 rounded-panel-card bg-panel-raised p-4">
            <Mail size={20} aria-hidden className="shrink-0 text-on-surface-variant" />
            <p className="min-w-0 flex-1 basis-60 type-panel-body text-on-surface">
              {fraseDelComprobante(estado, comprobante.correo)}
            </p>
            {estado && (
              <Badge tone={COMPROBANTE[estado].tone} icono>
                {COMPROBANTE[estado].texto}
              </Badge>
            )}
            <Button
              size="sm"
              variant="tonal"
              disabled={reenvio.isPending || estado === 'sin_configurar'}
              onClick={() => reenvio.mutate()}
            >
              {reenvio.isPending ? 'Reenviando…' : 'Reenviar comprobante'}
            </Button>
          </div>
        )}

        {reenvio.isError && (
          <ErrorBox title="No se pudo reenviar el comprobante" detail={describeError(reenvio.error)} />
        )}
      </Card>

      <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap sm:items-center sm:gap-3">
        <BotonConFoco botonRef={otroRef} onClick={onOtro}>
          <FilePlus2 size={16} aria-hidden />
          Registrar otro
          <Tecla enBoton>Enter</Tecla>
        </BotonConFoco>
        {conFicha && (
          <Link
            to="/financiamientos/$id"
            params={{ id: f.id }}
            className={claseDeBoton('text', 'md')}
          >
            Ver el pago en cuotas
          </Link>
        )}
      </div>
    </div>
  )
}
