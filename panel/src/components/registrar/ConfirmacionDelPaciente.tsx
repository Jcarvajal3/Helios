import { useEffect, useState } from 'react'
import { useMutation } from '@tanstack/react-query'
import { Clock, MessageCircle, Send } from 'lucide-react'

import { useToast } from '@/components/Toast'
import { Badge, Button, Callout, ErrorBox } from '@/components/ui'
import {
  CONFIRMACION,
  fraseDeLaEspera,
  minutosRestantes,
  textoDelPlazo,
} from '@/features/merchant/registro'
import type { Financiamiento } from '@/features/merchant/registro'
import { reenviarConfirmacion } from '@/features/merchant/registroApi'
import { describeError } from '@/lib/supabase'

/**
 * LA RESPUESTA DEL PACIENTE (plan §2.1, pasos 5 y 6; contrato §1.3.1).
 *
 * Desde el 2026-10-05 el paciente acepta respondiendo Sí a un WhatsApp de
 * Helios. Mientras tanto la orden espera (2 horas) y aquí se ve cómo va:
 * enviada, entregada, leída… y cuánto le queda.
 *
 *   · pending  → la espera, con la cuenta atrás y «Reenviar al paciente»
 *                (otro mensaje, sin alargar el plazo).
 *   · expired  → venció sin respuesta. «Reenviar al paciente» la reabre con
 *                otras 2 horas y las fechas de hoy.
 *   · declined → dijo No, o ya no se le podía financiar (con el texto neutro
 *                de siempre: la clínica nunca sabe por qué).
 *
 * Quien la pinta se encarga de volver a pedir el financiamiento mientras
 * espera; aquí solo se enseña y se reenvía (`onCambio` con lo nuevo).
 */
export function ConfirmacionDelPaciente({
  financiamiento,
  onCambio,
}: {
  financiamiento: Financiamiento
  onCambio: (f: Financiamiento) => void
}) {
  const avisar = useToast()
  const f = financiamiento
  const ahora = useAhora(f.status === 'pending')

  const reenvio = useMutation({
    mutationFn: () => reenviarConfirmacion(f.id),
    onSuccess: (nuevo) => {
      onCambio(nuevo)
      const a = nuevo.confirmation?.telefonoEnmascarado
      avisar(`Le reenviamos la pregunta al paciente${a ? ` (${a})` : ''}`)
    },
  })

  const botonReenviar = (
    <Button size="sm" variant="tonal" disabled={reenvio.isPending} onClick={() => reenvio.mutate()}>
      <Send size={15} aria-hidden />
      {reenvio.isPending ? 'Reenviando…' : 'Reenviar al paciente'}
    </Button>
  )
  const errorReenvio = reenvio.isError && (
    <ErrorBox title="No se pudo reenviar" detail={describeError(reenvio.error)} />
  )

  if (f.status === 'declined') {
    return (
      <Callout
        tone="error"
        titulo={
          f.declineReason === 'paciente'
            ? 'El paciente no aceptó el financiamiento'
            : 'No se pudo confirmar el financiamiento'
        }
      >
        {f.declineMessage ??
          'No se creó ninguna deuda. Si fue un error, registra el financiamiento otra vez.'}
      </Callout>
    )
  }

  if (f.status === 'expired') {
    return (
      <div className="flex flex-col gap-3">
        <Callout
          tone="warning"
          titulo="La orden venció sin respuesta del paciente"
          accion={botonReenviar}
        >
          No se creó ninguna deuda. Si el paciente quiere seguir, reenvíale la pregunta: se
          abren otras 2 horas, con las fechas de hoy.
        </Callout>
        {errorReenvio}
      </div>
    )
  }

  if (f.status !== 'pending') return null

  const c = f.confirmation
  const minutos = minutosRestantes(f.expiresAt, ahora)

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-col gap-3 rounded-panel-card bg-panel-raised p-4">
        <div className="flex flex-wrap items-center gap-3">
          <MessageCircle size={20} aria-hidden className="shrink-0 text-on-surface-variant" />
          <p role="status" className="min-w-0 flex-1 basis-60 type-panel-body text-on-surface">
            {fraseDeLaEspera(c)}
          </p>
          {c?.status && (
            <Badge tone={CONFIRMACION[c.status].tone} icono>
              {CONFIRMACION[c.status].texto}
            </Badge>
          )}
        </div>
        <div className="flex flex-wrap items-center gap-3">
          <Clock size={16} aria-hidden className="shrink-0 text-panel-muted" />
          <p className="min-w-0 flex-1 type-panel-caption text-panel-muted">
            {minutos > 0
              ? `Vence en ${textoDelPlazo(minutos)}. No hay deuda hasta que el paciente acepte.`
              : 'El plazo terminó: la orden vence en un momento.'}
          </p>
          {botonReenviar}
        </div>
      </div>
      {errorReenvio}
    </div>
  )
}

/** La hora de ahora, que avanza cada 15 s mientras `activo` (para la cuenta atrás). */
function useAhora(activo: boolean): number {
  const [ahora, setAhora] = useState(() => Date.now())
  useEffect(() => {
    if (!activo) return
    const t = setInterval(() => setAhora(Date.now()), 15_000)
    return () => clearInterval(t)
  }, [activo])
  return ahora
}
