import { AccionesDeFicha, ResumenDeFicha } from '@/components/admin/ficha'
import { Button } from '@/components/ui'
import type { MerchantRow } from '@/features/admin/api'
import type { Parametros } from '@/features/admin/parametros'
import { cifrasDelCarril } from './Cifras'
import type { useCifrasDelLocal } from './Cifras'
import type { EstadoDelLocal } from './Estado'

/**
 * El carril de la ficha de un local: lo que se le debe y cómo paga su gente,
 * y pausarlo, reactivarlo o marcarlo de prueba. Terminarlo va en el «⋯».
 */
export function CarrilLocal({
  merchant,
  pendingUsd,
  cifras,
  parametros,
  estado,
}: {
  merchant: MerchantRow
  pendingUsd: number
  cifras: ReturnType<typeof useCifrasDelLocal>
  parametros: Parametros | undefined
  estado: EstadoDelLocal
}) {
  const apagado = estado.sinPermiso !== undefined

  return (
    <>
      <ResumenDeFicha cifras={cifrasDelCarril({ pendingUsd, cifras, parametros })} />

      <AccionesDeFicha
        info="Pausar le impide registrar financiamientos nuevos; terminar hace lo mismo como fin del acuerdo y exige no deberle nada. Ninguno borra nada, y de los dos se vuelve con Reactivar. Una clínica de prueba queda fuera de las cifras, también si quien se financia es un paciente real."
        aviso={apagado ? 'Son del super admin: desde tu cuenta se consultan, pero no se aplican.' : undefined}
      >
        {merchant.status !== 'active' ? (
          <Button
            size="sm"
            variant="tonal"
            disabled={apagado}
            title={estado.sinPermiso}
            onClick={() => estado.abrir('active')}
          >
            Reactivar
          </Button>
        ) : (
          <Button
            size="sm"
            variant="tonal"
            disabled={apagado}
            title={estado.sinPermiso}
            onClick={() => estado.abrir('paused')}
          >
            Pausar
          </Button>
        )}
        <Button
          size="sm"
          variant="tonal"
          disabled={apagado}
          title={estado.sinPermiso}
          onClick={estado.marcarPrueba}
        >
          {merchant.isTest ? 'Ya no es de prueba' : 'Marcar como prueba'}
        </Button>
      </AccionesDeFicha>
    </>
  )
}
