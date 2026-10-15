import { useQuery, useQueryClient } from '@tanstack/react-query'

import { PersonalDelLocal } from '@/components/PersonalDelLocal'
import { MarcoDeFicha, VolverA } from '@/components/admin/ficha'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import { usePageTitle } from '@/components/layouts/PageAction'
import { ErrorBox, SkeletonList, Tabs } from '@/components/ui'
import { fetchMerchantDetail, fetchMerchants } from '@/features/admin/api'
import type { MerchantDetail, MerchantRow } from '@/features/admin/api'
import { useDatosDeContrato } from '@/features/admin/clinicas/useDatosDeContrato'
import { valorDe } from '@/features/admin/parametros'
import { useParametros } from '@/features/admin/useParametros'
import { AlertasDeLaClinica } from './Alertas'
import { Cabecera } from './Cabecera'
import { CuentaDePago } from './CuentaDePago'
import { CarrilLocal } from './Carril'
import { LoVendido, useCifrasDelLocal } from './Cifras'
import type { VentanaLocal } from './Cifras'
import { Condiciones } from './Condiciones'
import { useEstadoDelLocal } from './Estado'
import { Perfil } from './Perfil'

export { VENTANAS_LOCAL } from './Cifras'
export type { VentanaLocal } from './Cifras'

/*
 * La ficha de un local, partida en un archivo por bloque.
 *
 * La clínica es la unidad de riesgo: si deja pasar altas falsas, se ve aquí
 * antes que en ningún otro sitio. Por eso la ficha junta lo que vende, lo que
 * se le paga, con qué condiciones y quién cobra en su nombre.
 */

export type PestanaLocal = 'resumen' | 'perfil' | 'condiciones' | 'cuenta' | 'personal' | 'alertas'

/** En el orden de las pestañas. Sirve también para validar la URL. */
export const PESTANAS_LOCAL: ReadonlyArray<PestanaLocal> = [
  'resumen',
  'perfil',
  'condiciones',
  'cuenta',
  'personal',
  'alertas',
]

const ROTULO: Record<PestanaLocal, string> = {
  resumen: 'Resumen',
  perfil: 'Perfil',
  condiciones: 'Condiciones',
  cuenta: 'Cuenta de pago',
  personal: 'Personal',
  alertas: 'Alertas',
}

const PESTANAS = PESTANAS_LOCAL.map((value) => ({ value, label: ROTULO[value] }))

type Props = {
  merchantId: string
  tab: PestanaLocal
  dias: VentanaLocal
  onTab: (tab: PestanaLocal) => void
  onDias: (dias: VentanaLocal) => void
}

/**
 * La página de un local: la cabecera y el carril siempre a la vista y el
 * resto en pestañas.
 *
 * El local llega por id y no como fila: la página tiene que poder abrirse
 * desde un enlace. Se lee de la misma consulta que usa la lista (misma
 * clave), así que abrirla desde la lista no cuesta una llamada más.
 */
export function PaginaLocal(props: Props) {
  const { merchantId } = props
  const merchants = useQuery({ queryKey: ['merchants'], queryFn: fetchMerchants })
  const merchant = merchants.data?.find((m) => m.id === merchantId) ?? null

  const detalle = useQuery({
    queryKey: ['merchant-detail', merchantId],
    queryFn: () => fetchMerchantDetail(merchantId),
  })

  usePageTitle(merchant?.name ?? null)

  return (
    <>
      <VolverA link={{ to: '/admin/clinicas' }}>Clínicas</VolverA>

      {(detalle.isPending || merchants.isPending) && <SkeletonList rows={4} />}

      {merchants.isError && (
        <SeccionSinLeer
          titulo="No se pudo leer la clínica"
          error={merchants.error}
          onReintentar={() => void merchants.refetch()}
        />
      )}

      {detalle.isError && (
        <SeccionSinLeer
          titulo="No se pudo abrir la ficha de la clínica"
          error={detalle.error}
          onReintentar={() => void detalle.refetch()}
        />
      )}

      {merchants.isSuccess && !merchant && (
        <ErrorBox
          title="Esta clínica no existe"
          detail="Puede que el enlace sea viejo o que el id esté mal escrito."
        />
      )}

      {detalle.data && merchant && <FichaLocal {...props} merchant={merchant} detalle={detalle.data} />}
    </>
  )
}

/**
 * La ficha ya leída. Aquí vive el estado del local porque sus botones están
 * repartidos entre el carril y el «⋯»; el diálogo se monta una vez, abajo.
 */
function FichaLocal({
  merchantId,
  tab,
  dias,
  onTab,
  onDias,
  merchant,
  detalle,
}: Props & { merchant: MerchantRow; detalle: MerchantDetail }) {
  const queryClient = useQueryClient()
  const parametros = useParametros()
  const cifras = useCifrasDelLocal(merchantId, dias)

  function refrescar() {
    void queryClient.invalidateQueries({ queryKey: ['merchant-detail', merchantId] })
    void queryClient.invalidateQueries({ queryKey: ['merchants'] })
    void queryClient.invalidateQueries({ queryKey: ['merchant-payables'] })
  }

  const estado = useEstadoDelLocal({ merchant, pendingUsd: detalle.pendingUsd, onDone: refrescar })
  const datosDeAlta = useDatosDeContrato()

  return (
    <>
      <MarcoDeFicha
        cabecera={
          <>
            <Cabecera
              merchant={merchant}
              menu={estado.menu}
              datosDeAlta={{
                pendiente: datosDeAlta.pendiente,
                onDescargar: () => datosDeAlta.descargar({ de: 'ficha', id: merchant.id, nombre: merchant.name }),
              }}
            />
            {datosDeAlta.error && (
              <ErrorBox title="No se pudieron bajar los datos de alta" detail={datosDeAlta.error} />
            )}
          </>
        }
        carril={
          <CarrilLocal
            merchant={merchant}
            pendingUsd={detalle.pendingUsd}
            cifras={cifras}
            parametros={parametros.data}
            estado={estado}
          />
        }
      >
        <Tabs options={PESTANAS} value={tab} onChange={onTab} className="mb-0" />

        {tab === 'resumen' && (
          <LoVendido
            merchantId={merchantId}
            cifras={cifras}
            parametros={parametros.data}
            dias={dias}
            onDias={onDias}
          />
        )}

        {tab === 'perfil' && (
          <Perfil merchantId={merchantId} initial={detalle.profile} datos={detalle.datos} titular={detalle.titular} onDone={refrescar} />
        )}

        {tab === 'condiciones' && (
          <Condiciones
            merchantId={merchantId}
            initial={detalle.terms}
            comisionGlobal={valorDe(parametros.data, 'staff_commission_usd')}
            onDone={refrescar}
          />
        )}

        {tab === 'cuenta' && <CuentaDePago merchantId={merchantId} />}

        {/* La misma pantalla que ve el gerente en el panel de su local, más
            el acceso al bot dentro de cada tarjeta (`conBot`), que es cosa
            del equipo de Helios. Quién puede hacer qué lo decide el servidor,
            no desde dónde se abre. */}
        {tab === 'personal' && <PersonalDelLocal merchantId={merchantId} conBot />}

        {tab === 'alertas' && <AlertasDeLaClinica merchantId={merchantId} />}
      </MarcoDeFicha>

      {estado.dialogo}
    </>
  )
}
