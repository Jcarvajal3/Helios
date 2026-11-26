import { useState } from 'react'

import { Badge, Button, ConfirmDialog, formatUsd, formatVes } from '@/components/ui'
import { revisarPago } from '@/features/lab/admin'
import type { LecturaPago, MuestraFila } from '@/features/lab/admin'

import { useEscritura } from './comun'

/** Lo que leyó el lector de comprobantes, frente a lo que anotó el médico. */
export function LecturaDelPago({ muestra }: { muestra: MuestraFila }) {
  const l: LecturaPago | null = muestra.lectura
  if (!l) {
    return <span className="type-panel-caption text-panel-muted">Sin lectura</span>
  }
  const montoCuadra =
    l.montoVes !== null && muestra.montoVes !== null && Math.abs(l.montoVes - muestra.montoVes) < 0.01
  const refCuadra =
    l.referencia !== null &&
    muestra.pagoReferencia !== null &&
    (l.referencia.replace(/\D/g, '').endsWith(muestra.pagoReferencia.replace(/\D/g, '')) ||
      muestra.pagoReferencia.replace(/\D/g, '').endsWith(l.referencia.replace(/\D/g, '')))

  return (
    <div className="flex flex-col gap-1 type-panel-caption">
      {l.cuadra !== null && (
        <Badge tone={l.cuadra ? 'success' : 'warning'} icono>
          {l.cuadra ? 'Cuadra' : 'No cuadra'}
        </Badge>
      )}
      {l.estado === 'fallida' && <span className="text-error">El lector no pudo leerla{l.error ? `: ${l.error}` : ''}</span>}
      <span className={l.montoVes === null ? 'text-panel-muted' : montoCuadra ? 'text-success' : 'text-warning'}>
        Monto leído: {l.montoVes === null ? '—' : formatVes(l.montoVes)}
      </span>
      <span className={l.referencia === null ? 'text-panel-muted' : refCuadra ? 'text-success' : 'text-warning'}>
        Referencia leída: {l.referencia ?? '—'}
      </span>
      {l.banco && <span className="text-on-surface-variant">Banco leído: {l.banco}</span>}
      {l.fecha && <span className="text-on-surface-variant">Fecha leída: {l.fecha}</span>}
    </div>
  )
}

/** El monto del pago en bolívares, con su tasa. */
export function MontoEnBs({ muestra }: { muestra: MuestraFila }) {
  return (
    <div className="flex flex-col">
      <span className="font-semibold">{muestra.montoVes === null ? '—' : formatVes(muestra.montoVes)}</span>
      <span className="type-panel-caption text-panel-muted">
        {formatUsd(muestra.precioUsd)}
        {muestra.tasaBcv !== null && ` · tasa ${muestra.tasaBcv.toLocaleString('es-VE', { maximumFractionDigits: 4 })}`}
      </span>
    </div>
  )
}

/** «Verificar» y «Rechazar» (el rechazo pide motivo). */
export function AccionesDelPago({
  muestra,
  alTerminar,
}: {
  muestra: MuestraFila
  alTerminar?: () => void
}) {
  const [dialogo, setDialogo] = useState<'verificar' | 'rechazar' | null>(null)
  const cerrar = () => {
    setDialogo(null)
    alTerminar?.()
  }
  const verificar = useEscritura(
    (nota: string) => revisarPago({ id: muestra.id, aprobar: true, nota }),
    'Pago verificado.',
    cerrar,
  )
  const rechazar = useEscritura(
    (nota: string) => revisarPago({ id: muestra.id, aprobar: false, nota }),
    'Pago rechazado.',
    cerrar,
  )

  const enCola = muestra.pagoEstado === 'por_leer' || muestra.pagoEstado === 'cuadra' || muestra.pagoEstado === 'para_revisar'
  if (!enCola) return null

  const resumen = `${muestra.codigo} · ${muestra.paciente} · ${formatUsd(muestra.precioUsd)}`

  return (
    <>
      <div className="flex flex-wrap gap-2">
        <Button size="sm" onClick={() => setDialogo('verificar')}>
          Verificar
        </Button>
        <Button size="sm" variant="outlined" onClick={() => setDialogo('rechazar')}>
          Rechazar
        </Button>
      </div>

      {dialogo === 'verificar' && (
        <ConfirmDialog
          title="Verificar el pago"
          summary={`El pago de ${resumen} llegó a la cuenta de Helios. ¿Lo verificas?`}
          reasonLabel="Nota (opcional)"
          motivoMinimo={0}
          confirmLabel="Verificar"
          busy={verificar.isPending}
          error={verificar.mensaje}
          onConfirm={(nota) => verificar.mutate(nota)}
          onClose={() => setDialogo(null)}
        />
      )}
      {dialogo === 'rechazar' && (
        <ConfirmDialog
          title="Rechazar el pago"
          summary={`Vas a rechazar el pago de ${resumen}. El médico verá que no se pudo confirmar.`}
          nivel="sensible"
          reasonLabel="Motivo del rechazo"
          reasonPlaceholder="Ej. la referencia no aparece en la cuenta"
          confirmLabel="Rechazar"
          danger
          busy={rechazar.isPending}
          error={rechazar.mensaje}
          onConfirm={(nota) => rechazar.mutate(nota)}
          onClose={() => setDialogo(null)}
        />
      )}
    </>
  )
}

