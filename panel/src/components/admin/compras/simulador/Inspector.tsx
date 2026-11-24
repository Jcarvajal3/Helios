import { Badge, Callout, Card, DataLabel, formatPhone } from '@/components/ui'
import { rotuloDelProveedor } from '@/features/admin/compras/estados'
import type {
  DiagnosticoSimulador,
  MedicoSimulador,
} from '@/features/admin/compras/tipos'

/** Lo que el simulador sabe del turno: proveedor real y estado de la sesión que devolvió la función. */
export function Inspector({
  medico,
  diagnostico,
  errorDiagnostico,
  estado,
  mensajes,
}: {
  medico: MedicoSimulador
  diagnostico: DiagnosticoSimulador | undefined
  errorDiagnostico: string | null
  estado: string | null
  mensajes: number
}) {
  return (
    <Card as="section" className="flex flex-col gap-3">
      <DataLabel>Inspector</DataLabel>
      <dl className="flex flex-col gap-2 type-panel-body">
        <div>
          <dt className="type-panel-label text-on-surface-variant">Médico</dt>
          <dd className="text-on-surface">
            {medico.merchantName}
            {medico.doctorName ? ` · ${medico.doctorName}` : ''}
          </dd>
          <dd className="tabular-nums text-on-surface-variant">
            {formatPhone(medico.phone)}
          </dd>
        </div>
        <div>
          <dt className="type-panel-label text-on-surface-variant">
            Proveedor de catálogo
          </dt>
          <dd>
            {diagnostico ? (
              <Badge
                tone={diagnostico.proveedorListo ? 'success' : 'error'}
                icono
              >
                {rotuloDelProveedor(diagnostico)}
              </Badge>
            ) : (
              <span className="text-on-surface-variant">
                {errorDiagnostico ?? 'Consultando…'}
              </span>
            )}
          </dd>
        </div>
        <div>
          <dt className="type-panel-label text-on-surface-variant">
            Estado de la sesión del bot
          </dt>
          <dd className="font-mono text-on-surface">
            {estado ?? 'Sin turnos en esta sesión'}
          </dd>
        </div>
        <div>
          <dt className="type-panel-label text-on-surface-variant">Mensajes</dt>
          <dd className="tabular-nums text-on-surface">{mensajes}</dd>
        </div>
      </dl>
      {diagnostico && !diagnostico.proveedorListo && (
        <Callout tone="warning" titulo="El bot no puede buscar en Amazon">
          El catálogo real no está listo: el bot responderá que las compras no
          están disponibles.
        </Callout>
      )}
    </Card>
  )
}
