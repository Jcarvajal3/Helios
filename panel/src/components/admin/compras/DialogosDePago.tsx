import type { ReactNode } from 'react'
import { useMutation } from '@tanstack/react-query'

import { useToast } from '@/components/Toast'
import { ConfirmDialog, formatUsd, formatVes } from '@/components/ui'
import {
  conciliarPagoCompra,
  marcarPagoCompraDuplicado,
  marcarPagoCompraEnRevision,
} from '@/features/admin/compras/api'
import type {
  PagoCompraReporte,
  SolicitudCompraResumen,
} from '@/features/admin/compras/tipos'
import { explicarErrorDeAprobacion } from '@/features/admin/pagosRegistrados/registrarPago'
import { describeError } from '@/lib/supabase'

export type TipoDialogoPago = 'aprobar' | 'rechazar' | 'revision' | 'duplicado'

type Configuracion = {
  title: string
  summary: string
  detail?: ReactNode
  nivel?: 'sensible'
  reasonLabel: string
  reasonPlaceholder: string
  confirmLabel: string
  danger?: boolean
  motivoMinimo?: number
  exito: string
  accion: (reportId: string, nota: string) => Promise<void>
}

function parrafo(texto: string): ReactNode {
  return <p className="type-panel-body text-on-surface-variant">{texto}</p>
}

function configuracion(
  tipo: TipoDialogoPago,
  request: SolicitudCompraResumen,
  pago: PagoCompraReporte,
): Configuracion {
  const monto =
    pago.amountVes !== null ? formatVes(pago.amountVes) : 'monto no declarado'
  switch (tipo) {
    case 'aprobar':
      return {
        title: 'Aprobar pago de compra',
        summary: `Vas a aprobar el pago (${monto}) de ${formatUsd(request.totalUsd)} para ${request.code} · Ref. ${pago.reference ?? '—'}.`,
        detail: parrafo(
          'La solicitud pasará a «Pagado», lista para comprar en Amazon, y se enviará la confirmación al médico.',
        ),
        reasonLabel: 'Nota interna (opcional)',
        reasonPlaceholder: 'Verificado en cuenta BNC',
        motivoMinimo: 0,
        confirmLabel: 'Aprobar pago',
        exito: `Pago aprobado para ${request.code}. El médico ya fue notificado.`,
        accion: (reportId, nota) =>
          conciliarPagoCompra({ reportId, approve: true, note: nota || null }),
      }
    case 'rechazar':
      return {
        title: 'Rechazar pago reportado',
        summary: `Se rechazará el comprobante (${monto}) y la solicitud volverá a «Esperando pago».`,
        detail: parrafo(
          'El médico recibirá el motivo por WhatsApp (o en el Simulador) para que vuelva a reportar el pago.',
        ),
        nivel: 'sensible',
        reasonLabel: 'Motivo del rechazo',
        reasonPlaceholder: 'La referencia no aparece acreditada en el banco',
        confirmLabel: 'Rechazar pago',
        danger: true,
        exito: `Pago rechazado para ${request.code}. Se avisó al médico para que reenvíe el comprobante.`,
        accion: (reportId, nota) =>
          conciliarPagoCompra({ reportId, approve: false, note: nota }),
      }
    case 'revision':
      return {
        title: 'Marcar pago en revisión',
        summary: `El pago de ${request.code} queda apartado «En revisión» para seguimiento del equipo.`,
        nivel: 'sensible',
        reasonLabel: 'Nota para el equipo',
        reasonPlaceholder:
          'Confirmar titular de la cuenta origen antes de aprobar',
        confirmLabel: 'Marcar en revisión',
        exito: 'El pago quedó marcado en revisión.',
        accion: (reportId, nota) =>
          marcarPagoCompraEnRevision({ reportId, note: nota }),
      }
    case 'duplicado':
      return {
        title: 'Marcar pago como duplicado',
        summary:
          'Se cerrará este reporte como duplicado sin enviar mensaje de rechazo al médico.',
        detail: parrafo(
          'Usa esta opción cuando el mismo pago ya fue reportado o conciliado en otro registro.',
        ),
        nivel: 'sensible',
        reasonLabel: 'Por qué es duplicado',
        reasonPlaceholder: 'El médico reenvió la misma captura dos veces',
        confirmLabel: 'Marcar como duplicado',
        exito: 'Pago cerrado como duplicado (sin aviso al médico).',
        accion: (reportId, nota) =>
          marcarPagoCompraDuplicado({ reportId, note: nota }),
      }
  }
}

/**
 * Diálogo de decisión sobre un pago abierto. Se monta solo mientras está abierto: su mutación
 * (y su error) nacen y mueren con él, y siempre recibe un pago real, nunca un id vacío.
 */
export function DialogoDePago({
  tipo,
  request,
  pago,
  registradoPorMi,
  onCerrar,
  onHecho,
}: {
  tipo: TipoDialogoPago
  request: SolicitudCompraResumen
  pago: PagoCompraReporte
  registradoPorMi: boolean
  onCerrar: () => void
  onHecho: () => void
}) {
  const avisar = useToast()
  const c = configuracion(tipo, request, pago)
  const mutacion = useMutation({
    mutationFn: (nota: string) => c.accion(pago.id, nota),
    onSuccess: () => {
      onHecho()
      avisar(c.exito)
    },
  })

  const error = mutacion.isError
    ? tipo === 'aprobar'
      ? explicarErrorDeAprobacion(
          mutacion.error,
          describeError(mutacion.error),
          registradoPorMi,
        )
      : describeError(mutacion.error)
    : undefined

  return (
    <ConfirmDialog
      title={c.title}
      summary={c.summary}
      detail={c.detail}
      nivel={c.nivel}
      reasonLabel={c.reasonLabel}
      reasonPlaceholder={c.reasonPlaceholder}
      motivoMinimo={c.motivoMinimo}
      confirmLabel={c.confirmLabel}
      danger={c.danger}
      busy={mutacion.isPending}
      error={error}
      onConfirm={(nota) => mutacion.mutate(nota)}
      onClose={() => {
        mutacion.reset()
        onCerrar()
      }}
    />
  )
}
