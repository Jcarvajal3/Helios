import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { CircleCheck } from 'lucide-react'

import { Button, ConfirmDialog, EmptyState, ErrorBox, SkeletonTable, Table, Td, Tr, formatDateTime, formatUsd } from '@/components/ui'
import { POR_PAGINA, confirmarCuadrados, consultaCola, consultaMuestras, mensajeDeError } from '@/features/lab/admin'
import type { MuestraFila } from '@/features/lab/admin'
import type { EstadoPago } from '@/features/lab/tipos'

import { Captura, InsigniaPago, Paginacion, useEscritura } from '../muestras/comun'
import { DetalleMuestra } from '../muestras/DetalleMuestra'
import { AccionesDelPago, LecturaDelPago, MontoEnBs } from '../muestras/Pago'

const CABECERAS_COLA = ['Muestra', 'Monto en Bs', 'Referencia anotada', 'Captura', 'Lo que leyó el lector', 'Acciones']
const CABECERAS_HISTORIA = ['Muestra', 'Fecha', 'Monto en Bs', 'Referencia', 'Pago', 'Nota']

/** La cola: lo que espera revisión del equipo. */
export function ColaDeCobros() {
  const q = useQuery(consultaCola())
  const [abierta, setAbierta] = useState<string | null>(null)
  const [confirmando, setConfirmando] = useState(false)

  const filas = q.data ?? []
  const cuadrados = filas.filter((m) => m.pagoEstado === 'cuadra')

  const confirmar = useEscritura(
    () => confirmarCuadrados(cuadrados.map((m) => m.id)),
    'Pagos confirmados.',
    () => setConfirmando(false),
  )

  if (q.isPending) return <SkeletonTable rows={6} />
  if (q.isError) return <ErrorBox title="No se pudo leer la cola de cobros" detail={mensajeDeError(q.error)} />
  if (filas.length === 0) {
    return (
      <EmptyState
        icon={<CircleCheck size={28} aria-hidden />}
        title="No hay pagos por revisar"
        description="Cuando un médico registre una muestra con su pago, aparece aquí."
      />
    )
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="type-panel-body text-on-surface-variant">
          {filas.length} {filas.length === 1 ? 'pago espera' : 'pagos esperan'} revisión
          {cuadrados.length > 0 && ` · ${cuadrados.length} cuadran con lo que se leyó`}
        </p>
        <Button size="md" disabled={cuadrados.length === 0} onClick={() => setConfirmando(true)}>
          Confirmar los que cuadran{cuadrados.length > 0 ? ` (${cuadrados.length})` : ''}
        </Button>
      </div>

      <Table headers={CABECERAS_COLA}>
        {filas.map((m) => (
          <FilaDeCola key={m.id} m={m} onAbrir={() => setAbierta(m.id)} />
        ))}
      </Table>

      {confirmando && (
        <ConfirmDialog
          title="Confirmar los que cuadran"
          summary={`Vas a verificar ${cuadrados.length} ${cuadrados.length === 1 ? 'pago' : 'pagos'} cuyo monto y referencia cuadran con la captura.`}
          detail={
            <ul className="flex max-h-48 flex-col gap-1 overflow-y-auto type-panel-caption">
              {cuadrados.map((m) => (
                <li key={m.id}>
                  {m.codigo} · {m.paciente} · {formatUsd(m.precioUsd)}
                </li>
              ))}
            </ul>
          }
          confirmLabel="Confirmar"
          busy={confirmar.isPending}
          error={confirmar.mensaje}
          onConfirm={() => confirmar.mutate(undefined)}
          onClose={() => setConfirmando(false)}
        />
      )}
      {abierta && <DetalleMuestra id={abierta} onClose={() => setAbierta(null)} />}
    </div>
  )
}

function FilaDeCola({ m, onAbrir }: { m: MuestraFila; onAbrir: () => void }) {
  return (
    <Tr>
      <Td>
        <button type="button" onClick={onAbrir} className="flex flex-col items-start text-left hover:underline">
          <span className="font-semibold">{m.codigo}</span>
          <span className="type-panel-caption text-panel-muted">
            {m.medico} · {m.paciente}
          </span>
          <span className="type-panel-caption text-panel-muted">{formatDateTime(m.creada)}</span>
        </button>
      </Td>
      <Td>
        <MontoEnBs muestra={m} />
      </Td>
      <Td>
        <div className="flex flex-col">
          <span>{m.pagoReferencia ?? '—'}</span>
          {m.pagoBanco && <span className="type-panel-caption text-panel-muted">{m.pagoBanco}</span>}
        </div>
      </Td>
      <Td>
        {m.comprobantePath ? <Captura ruta={m.comprobantePath} compacta /> : <span className="type-panel-caption text-panel-muted">Sin captura</span>}
      </Td>
      <Td>
        <div className="flex flex-col gap-1.5">
          <InsigniaPago pago={m.pagoEstado} />
          <LecturaDelPago muestra={m} />
        </div>
      </Td>
      <Td>
        <AccionesDelPago muestra={m} />
      </Td>
    </Tr>
  )
}

/** El historial de lo ya resuelto: verificados o rechazados. */
export function HistorialDeCobros({
  pago,
  pagina,
  onPagina,
}: {
  pago: Extract<EstadoPago, 'verificado' | 'rechazado'>
  pagina: number
  onPagina: (p: number) => void
}) {
  const q = useQuery(consultaMuestras({ pago, pagina }))
  const [abierta, setAbierta] = useState<string | null>(null)

  if (q.isPending) return <SkeletonTable rows={6} />
  if (q.isError) return <ErrorBox title="No se pudo leer el historial" detail={mensajeDeError(q.error)} />
  const filas = q.data
  if (filas.length === 0) {
    return <EmptyState title={pago === 'verificado' ? 'Todavía no hay pagos verificados' : 'No hay pagos rechazados'} />
  }

  return (
    <>
      <Table headers={CABECERAS_HISTORIA}>
        {filas.map((m) => (
          <Tr key={m.id} onClick={() => setAbierta(m.id)}>
            <Td>
              <div className="flex flex-col">
                <span className="font-semibold">{m.codigo}</span>
                <span className="type-panel-caption text-panel-muted">
                  {m.medico} · {m.paciente}
                </span>
              </div>
            </Td>
            <Td className="whitespace-nowrap">{formatDateTime(m.creada)}</Td>
            <Td>
              <MontoEnBs muestra={m} />
            </Td>
            <Td>{m.pagoReferencia ?? '—'}</Td>
            <Td>
              <InsigniaPago pago={m.pagoEstado} />
            </Td>
            <Td className="max-w-64 whitespace-normal type-panel-caption text-on-surface-variant">{m.pagoNota ?? '—'}</Td>
          </Tr>
        ))}
      </Table>
      <Paginacion pagina={pagina} total={filas[0]?.total ?? 0} porPagina={POR_PAGINA} onPagina={onPagina} />
      {abierta && <DetalleMuestra id={abierta} onClose={() => setAbierta(null)} />}
    </>
  )
}
