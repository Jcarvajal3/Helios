import { useQuery } from '@tanstack/react-query'

import { MarcoDeFicha, ResumenDeFicha, VolverA } from '@/components/admin/ficha'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import { usePageTitle } from '@/components/layouts/PageAction'
import { SkeletonList } from '@/components/ui'
import { fetchChargeDetail } from '@/features/admin/consumos'
import type { ChargeDetail } from '@/features/admin/consumos'
import { useAccionesDelConsumo } from './Acciones'
import { Cabecera, Desglose, cifrasDelConsumo, nombreDelConsumo } from './Cabecera'
import { Cuotas } from './Cuotas'
import { Lineas } from './Lineas'

/**
 * UN CONSUMO POR DENTRO: la misma factura que el cliente lee en su teléfono.
 *
 * El orden es el del recibo de la app, porque cuando alguien llama, el
 * operador y el cliente van leyendo la misma pantalla desde arriba:
 *
 *   1. El financiamiento en la clínica y su desglose; en el carril, cómo se paga.
 *   2. Qué se financió.
 *   3. Las cuotas.
 *
 * Anular un pendiente o revertir un confirmado va en el «⋯» de la cabecera.
 */
export function PaginaConsumo({
  chargeId,
  onVolver,
}: {
  chargeId: string
  /** Después de revertir: se vuelve de donde se vino. */
  onVolver: () => void
}) {
  const query = useQuery({
    queryKey: ['charge-detail', chargeId],
    queryFn: () => fetchChargeDetail(chargeId),
  })

  // El título es el número de orden: es el nombre de esta cosa, y lo que hay
  // que poder leer de un vistazo cuando alguien lo está dictando.
  usePageTitle(query.data ? nombreDelConsumo(query.data) : null)

  return (
    <>
      <VolverA link={{ to: '/admin/financiamientos' }}>Financiamientos</VolverA>

      {query.isPending && <SkeletonList rows={4} />}

      {query.isError && (
        <SeccionSinLeer
          titulo="No se pudo leer el financiamiento"
          error={query.error}
          onReintentar={() => void query.refetch()}
        />
      )}

      {query.data && <Detalle detail={query.data} onRevertido={onVolver} />}
    </>
  )
}

function Detalle({ detail, onRevertido }: { detail: ChargeDetail; onRevertido: () => void }) {
  const acciones = useAccionesDelConsumo(detail, onRevertido)

  return (
    <>
      <MarcoDeFicha
        cabecera={<Cabecera detail={detail} menu={acciones.menu} />}
        carril={
          <>
            <ResumenDeFicha cifras={cifrasDelConsumo(detail)} />
            {acciones.aviso}
          </>
        }
      >
        <Desglose detail={detail} />
        {detail.items.length > 0 && <Lineas detail={detail} />}
        {detail.installments.length > 0 && <Cuotas detail={detail} />}
      </MarcoDeFicha>

      {acciones.dialogo}
    </>
  )
}
