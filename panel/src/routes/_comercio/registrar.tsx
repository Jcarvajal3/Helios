import { createFileRoute } from '@tanstack/react-router'
import { Construction } from 'lucide-react'

import { EmptyState } from '@/components/ui'

export const Route = createFileRoute('/_comercio/registrar')({
  staticData: { title: 'Nuevo financiamiento' },
  component: RegistrarPage,
})

/**
 * Nuevo financiamiento: la secretaria registra al paciente y la consulta en un
 * solo paso (plan §2.1): cédula → datos del paciente → monto y concepto →
 * vista previa con las dos cuotas → confirmar → «comprobante enviado».
 *
 * FASE 2. Aquí vivía `/facturar` de Ronda (el QR que el cliente escaneaba con
 * la app). Helios no tiene app: la pantalla nueva se construye sobre
 * `helios_patient_eligibility`, `preview_patient_charge` y
 * `create_patient_charge` (docs/01-CONTRATO-RPC.md). Mientras tanto queda el
 * marco, para que el menú, los permisos y el login ya apunten aquí.
 */
function RegistrarPage() {
  return (
    <EmptyState
      icon={<Construction size={48} />}
      title="Nuevo financiamiento — en construcción"
      description="Aquí vas a registrar al paciente y su consulta en un solo paso, con la vista previa de las dos cuotas antes de confirmar."
    />
  )
}
