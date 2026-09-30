import { useQuery } from '@tanstack/react-query'

import { TablaDeAlertas } from '@/components/admin/alertas/TablaDeAlertas'
import { Card, NoSePudoLeer, Seccion, SkeletonTable } from '@/components/ui'
import { alertasDeLaClinica } from '@/features/admin/riesgo/alertas'
import { CLAVES_RIESGO, fetchAlertas } from '@/features/admin/riesgo/consultas'

/** El mismo tope y la misma clave que la pantalla de Alertas: no cuesta otra llamada. */
const TOPE = 500

/**
 * Las alertas de esta clínica: las suyas (ráfagas, impago de la primera
 * cuota, exposición) y las de su personal (altas concentradas, consultas de
 * cédula de más). Es donde se ve primero una clínica que deja pasar altas
 * falsas (plan H10). Ninguna bloquea nada.
 */
export function AlertasDeLaClinica({ merchantId }: { merchantId: string }) {
  const consulta = useQuery({
    queryKey: [...CLAVES_RIESGO.alertas, TOPE, 'todas'],
    queryFn: () => fetchAlertas({ limite: TOPE, tipos: null }),
  })

  const suyas = consulta.data ? alertasDeLaClinica(consulta.data.filas, merchantId) : []
  const pendientes = suyas.filter((a) => !a.revisada).length

  return (
    <Seccion
      titulo="Alertas de la clínica"
      info="Las de la clínica y las de su personal, revisadas o no. Salen también en Alertas, con las de sus pacientes."
    >
      {consulta.isError ? (
        <Card>
          <NoSePudoLeer onReintentar={() => void consulta.refetch()} />
        </Card>
      ) : !consulta.data ? (
        <SkeletonTable rows={3} columns={4} />
      ) : suyas.length === 0 ? (
        <Card>
          <p className="type-panel-body text-on-surface-variant">Esta clínica no ha disparado ninguna alerta.</p>
        </Card>
      ) : (
        <TablaDeAlertas
          alertas={suyas}
          resumen={pendientes > 0 ? `${pendientes} sin revisar` : 'ninguna sin revisar'}
        />
      )}
    </Seccion>
  )
}
