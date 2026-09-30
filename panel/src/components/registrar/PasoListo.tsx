import { useEffect, useRef, useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation } from '@tanstack/react-query'
import { CircleCheck, FilePlus2, Mail } from 'lucide-react'

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
  formatUsd,
} from '@/components/ui'
import { COMPROBANTE, fraseDelComprobante } from '@/features/merchant/registro'
import type { EstadoDelComprobante, Financiamiento } from '@/features/merchant/registro'
import { reenviarComprobante } from '@/features/merchant/registroApi'
import { describeError } from '@/lib/supabase'

import { BotonConFoco } from './Campo'
import { DesgloseDelServicio, PlanDePagos } from './PlanDePagos'

/**
 * PASO 5 · REGISTRADO.
 *
 * El número de orden, el paciente, sus cuotas y qué pasó con el comprobante
 * (plan §2.1, paso 6). El comprobante sale solo al confirmar; «Reenviar» es
 * para cuando el paciente dice que no le llegó, y va al correo REGISTRADO:
 * la clínica no puede cambiarlo (lo corrige Helios).
 *
 * El foco cae en «Registrar otro», que es lo siguiente que se hace en una
 * recepción con cola.
 */
export function PasoListo({
  financiamiento,
  coincide,
  onOtro,
  onRegistrarElQueQueria,
}: {
  financiamiento: Financiamiento
  /**
   * `false` si la base devolvió un alta anterior con la misma clave: la
   * respuesta de aquel alta se perdió y esto no es lo que se acaba de pedir.
   */
  coincide: boolean
  onOtro: () => void
  onRegistrarElQueQueria: () => void
}) {
  const avisar = useToast()
  const otroRef = useRef<HTMLButtonElement>(null)
  const [comprobante, setComprobante] = useState<{
    estado: EstadoDelComprobante | null
    correo: string | null
  }>({ estado: financiamiento.receipt, correo: financiamiento.emailEnmascarado })

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

  const f = financiamiento
  const estado = comprobante.estado

  return (
    <div className="flex flex-col gap-5">
      {!coincide && (
        <Callout
          tone="warning"
          titulo="Esto es un financiamiento que ya estaba registrado"
          accion={
            <Button size="sm" variant="tonal" onClick={onRegistrarElQueQueria}>
              Registrar el que querías
            </Button>
          }
        >
          La conexión falló en un intento anterior y ese financiamiento sí se había
          registrado: es este. No se creó uno nuevo con los datos que acabas de confirmar.
        </Callout>
      )}

      <Card variant="hero" className="flex flex-col gap-5">
        <div className="flex items-start gap-3">
          <CircleCheck size={28} aria-hidden className="mt-1 shrink-0 text-success" />
          <div className="min-w-0">
            <p role="status" className="type-panel-page text-on-surface">
              Financiamiento #{f.orderNumber} registrado
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
            {formatUsd(f.merchantSaleUsd)}
          </p>
        </div>

        {f.cuotas.length > 0 && (
          <div>
            <DataLabel className="mb-2">Las cuotas del paciente</DataLabel>
            <PlanDePagos cuotas={f.cuotas} />
          </div>
        )}

        <DesgloseDelServicio
          baseUsd={f.merchantSaleUsd}
          feePct={f.feePct}
          feeUsd={f.feeUsd}
          feeVatUsd={f.feeVatUsd}
          concepto={f.concept}
        />

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

        {reenvio.isError && (
          <ErrorBox title="No se pudo reenviar el comprobante" detail={describeError(reenvio.error)} />
        )}
      </Card>

      <div className="flex flex-wrap items-center gap-3">
        <BotonConFoco botonRef={otroRef} onClick={onOtro}>
          <FilePlus2 size={16} aria-hidden />
          Registrar otro
          <Tecla enBoton>Enter</Tecla>
        </BotonConFoco>
        <Link
          to="/financiamientos/$id"
          params={{ id: f.id }}
          className={claseDeBoton('text', 'md')}
        >
          Ver el financiamiento
        </Link>
      </div>
    </div>
  )
}
