import { useEffect, useRef } from 'react'
import { useQuery } from '@tanstack/react-query'
import { ArrowLeft, CircleCheck, Send } from 'lucide-react'

import {
  Button,
  Callout,
  Card,
  DataLabel,
  ErrorBox,
  SkeletonList,
  Tecla,
  formatMoneda,
  formatUsd,
} from '@/components/ui'
import type { Moneda } from '@/components/ui'
import {
  esRechazoDeLaBase,
  pasoDelError,
  reglaDelAtraso,
} from '@/features/merchant/registro'
import type { PasoDelAlta } from '@/features/merchant/registro'
import { fetchVistaPrevia } from '@/features/merchant/registroApi'
import { describeError } from '@/lib/supabase'

import { BotonConFoco } from './Campo'
import { DesgloseDelServicio, PlanDePagos } from './PlanDePagos'

const IR_A: Record<PasoDelAlta, string> = {
  cedula: 'Cambiar la cédula',
  datos: 'Corregir los datos',
  monto: 'Cambiar el monto',
  confirmar: 'Volver',
}

/**
 * PASO 4 · LA VISTA PREVIA Y EL SÍ.
 *
 * `preview_patient_charge` no crea nada: devuelve las dos cuotas con sus
 * fechas y el desglose, que es lo que la secretaria le enseña al paciente en
 * la pantalla y le confirma de palabra (plan §2, paso 6 del diagrama).
 *
 * Solo aquí se puede confirmar, y solo con la vista previa a la vista: sin
 * ella el paciente estaría aceptando unas cuotas que nadie le ha dicho.
 *
 * Con la confirmación del paciente (`conConfirmacion`, contrato §1.3.1) el
 * botón ya no confirma: le envía al paciente un WhatsApp con este resumen, y
 * el pago en cuotas existe cuando responde Sí.
 *
 * Todo en la moneda en la que cobra la clínica (`_cur`), con cada cuota en
 * bolívares a la tasa de hoy. El cargo por atraso es la excepción: la base lo
 * fija en dólares y así se dice.
 */
export function PasoConfirmar({
  merchantId,
  documento,
  amount,
  moneda,
  concepto,
  beneficiario,
  titular,
  correoDestino,
  esNuevo,
  conConfirmacion,
  confirmando,
  errorAlta,
  onConfirmar,
  onIrA,
}: {
  merchantId: string
  documento: string
  /** En `moneda`. */
  amount: number
  moneda: Moneda
  concepto: string | null
  beneficiario: string | null
  titular: string
  /** El correo tecleado (nuevo) o el enmascarado que ya tiene Helios (conocido). */
  correoDestino: string | null
  esNuevo: boolean
  /** La orden espera el Sí del paciente por WhatsApp. */
  conConfirmacion: boolean
  confirmando: boolean
  errorAlta: unknown
  onConfirmar: () => void
  onIrA: (paso: PasoDelAlta) => void
}) {
  const confirmarRef = useRef<HTMLButtonElement>(null)

  const vista = useQuery({
    queryKey: ['vista-previa-financiamiento', merchantId, documento, amount, moneda],
    queryFn: () => fetchVistaPrevia({ merchantId, document: documento, amount, moneda }),
    // Sin efectos, pero cada vuelta es una consulta a la base: con la
    // pestaña quieta no hay nada nuevo que pedir.
    refetchOnWindowFocus: false,
    staleTime: 60_000,
    retry: 1,
  })

  const lista = vista.data !== undefined && vista.data.cabe

  // Con el plan en pantalla, el foco va a Confirmar: Enter y listo.
  useEffect(() => {
    if (lista) confirmarRef.current?.focus()
  }, [lista])

  const mensajeError = errorAlta ? describeError(errorAlta) : undefined
  const corregir = pasoDelError(mensajeError, esNuevo)

  return (
    <div className="flex flex-col gap-5">
      {vista.isPending && <SkeletonList rows={4} />}

      {vista.isError && (
        <Callout
          tone="error"
          titulo="No pudimos calcular las cuotas"
          accion={
            <Button size="sm" variant="tonal" onClick={() => void vista.refetch()}>
              Reintentar
            </Button>
          }
        >
          {describeError(vista.error)}
        </Callout>
      )}

      {vista.data && (
        <form
          onSubmit={(e) => {
            e.preventDefault()
            if (lista && !confirmando) onConfirmar()
          }}
          className="flex flex-col gap-5"
        >
          <Card variant="hero" className="flex flex-col gap-5">
            <div className="flex flex-wrap items-start justify-between gap-4">
              <div className="min-w-0">
                <DataLabel>Titular</DataLabel>
                <p className="mt-1 type-panel-section text-on-surface">{titular}</p>
                {beneficiario && (
                  <p className="mt-0.5 type-panel-body text-on-surface-variant">
                    Paciente atendido: {beneficiario}
                  </p>
                )}
              </div>
              <div className="sm:text-right">
                <DataLabel>{concepto ?? 'Consulta'} · lo que cobra la clínica</DataLabel>
                <p className="mt-1 type-panel-hero tabular-nums text-on-surface">
                  {formatMoneda(vista.data.baseCur, vista.data.moneda)}
                </p>
              </div>
            </div>

            <div>
              <DataLabel className="mb-2">El paciente paga en 2 cuotas</DataLabel>
              <PlanDePagos cuotas={vista.data.cuotas} moneda={vista.data.moneda} />
            </div>

            <DesgloseDelServicio
              base={vista.data.baseCur}
              feePct={vista.data.feePct}
              fee={vista.data.feeCur}
              feeVat={vista.data.feeVatCur}
              moneda={vista.data.moneda}
              concepto={concepto}
            />

            <ul className="flex flex-col gap-1.5 type-panel-body text-on-surface-variant">
              {reglaDelAtraso(vista.data, formatUsd) && (
                <li>{reglaDelAtraso(vista.data, formatUsd)}</li>
              )}
              <li>
                {/* Con la confirmación, nada sale hasta el Sí: ni el comprobante ni la bienvenida. */}
                {conConfirmacion ? 'Cuando responda Sí, le llega el comprobante a ' : 'El comprobante con las cuotas le llega a '}
                <strong className="text-on-surface">{correoDestino ?? 'su correo registrado'}</strong>
                {conConfirmacion ? ' y un WhatsApp con sus cuotas.' : '.'}
              </li>
            </ul>
          </Card>

          {!vista.data.cabe && (
            <Callout tone="warning" titulo="Este monto no cabe en lo disponible del paciente">
              {vista.data.disponibleCur !== null
                ? `Tiene disponible hasta ${formatMoneda(vista.data.disponibleCur, vista.data.moneda)}. Baja el monto para seguir.`
                : 'Baja el monto para seguir.'}
            </Callout>
          )}

          {mensajeError && (
            <div className="flex flex-col gap-2">
              <ErrorBox title="No se registró el pago en cuotas" detail={mensajeError} />
              {!esRechazoDeLaBase(errorAlta) && (
                <p className="type-panel-body text-on-surface-variant">
                  Si el problema fue la conexión, vuelve a confirmar: si el pago en cuotas
                  llegó a registrarse no se duplica, te enseñamos el mismo.
                </p>
              )}
              {corregir && corregir !== 'confirmar' && (
                <div>
                  <Button size="sm" variant="tonal" onClick={() => onIrA(corregir)}>
                    {IR_A[corregir]}
                  </Button>
                </div>
              )}
            </div>
          )}

          <p className="type-panel-body text-on-surface">
            {conConfirmacion
              ? 'Léele al paciente las fechas y los montos de sus cuotas. Al enviar, le llega un WhatsApp con este resumen y tiene 2 horas para responder Sí. Sin su Sí no hay pago en cuotas.'
              : 'Léele al paciente las fechas y los montos de sus cuotas. Si está de acuerdo, confirma.'}
          </p>

          <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap sm:items-center sm:gap-3">
            <BotonConFoco
              type="submit"
              botonRef={confirmarRef}
              disabled={!lista || confirmando}
            >
              {conConfirmacion ? (
                <Send size={16} aria-hidden />
              ) : (
                <CircleCheck size={16} aria-hidden />
              )}
              {confirmando
                ? conConfirmacion
                  ? 'Enviando…'
                  : 'Registrando…'
                : conConfirmacion
                  ? 'Enviar al paciente'
                  : 'Confirmar pago en cuotas'}
              <Tecla enBoton>Enter</Tecla>
            </BotonConFoco>
            <BotonConFoco variant="text" onClick={() => onIrA('monto')} disabled={confirmando}>
              <ArrowLeft size={16} aria-hidden />
              Cambiar el monto
            </BotonConFoco>
          </div>
        </form>
      )}

      {vista.isError && (
        <div>
          <BotonConFoco variant="text" onClick={() => onIrA('monto')}>
            <ArrowLeft size={16} aria-hidden />
            Cambiar el monto
          </BotonConFoco>
        </div>
      )}
    </div>
  )
}
