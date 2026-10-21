import { Callout, Seccion, SkeletonBlock, Table, Td, Tr, formatDateTime, formatVes } from '@/components/ui'
import { avisoQueRespalda } from '@/features/admin/avisoDelPago'
import type { AvisoDelPago } from '@/features/admin/avisoDelPago'

/**
 * Los avisos del BNC (SMS) que encajan con un pago registrado, debajo del
 * cotejo con el extracto. Sirven de respaldo cuando el extracto de ese día
 * todavía no se ha importado: el SMS llega al momento y el extracto, después.
 *
 * Sin ningún aviso con esa referencia no se pinta nada: no todos los pagos
 * son Pago Móvil al BNC.
 */
export function AvisoDelBnc({
  avisos,
  cargando,
  error,
}: {
  avisos: ReadonlyArray<AvisoDelPago> | undefined
  cargando: boolean
  error: boolean
}) {
  if (cargando) return <SkeletonBlock className="h-14 w-full" />
  if (error || !avisos || avisos.length === 0) return null

  const respalda = avisoQueRespalda(avisos)

  return (
    <Seccion
      titulo="El aviso del BNC"
      info="Los SMS del BNC con la misma referencia que este pago (la regla del bot de avisos). Llegan al momento; el extracto, cuando se importa. Encaja si coinciden la referencia, el monto (±1 Bs) y el día."
    >
      {respalda ? (
        <Callout tone="success" titulo="Llegó el aviso del BNC de este pago">
          Coinciden la referencia, el monto y el día. Si el extracto aún no lo trae, respalda la aprobación:
          el motivo ya va escrito.
        </Callout>
      ) : (
        <Callout tone="warning" titulo="Hay un aviso del BNC con esta referencia, pero no encaja entero">
          Mira el monto y el día antes de fiarte de él.
        </Callout>
      )}
      <Table headers={['Llegó', 'Referencia', 'Monto', 'Encaja']}>
        {avisos.map((a) => (
          <Tr key={a.id}>
            <Td className="whitespace-nowrap">{formatDateTime(a.recibidoEn)}</Td>
            <Td className="font-mono">{a.referencia ?? '—'}</Td>
            <Td className="tabular-nums">{a.montoVes === null ? '—' : formatVes(a.montoVes)}</Td>
            <Td className="type-panel-caption text-on-surface-variant">
              {a.ligadoAOtro
                ? 'Ya respalda otro pago'
                : [a.montoEncaja ? 'monto' : 'otro monto', a.diaEncaja ? 'día' : 'otro día'].join(' · ')}
            </Td>
          </Tr>
        ))}
      </Table>
    </Seccion>
  )
}
