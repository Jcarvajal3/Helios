import { Link } from '@tanstack/react-router'

import { CabeceraDeFicha } from '@/components/admin/ficha'
import type { HuecoDeMenu } from '@/components/admin/ficha'
import { LogoLocal } from '@/components/admin/directorio/LogoLocal'
import { Badge, claseDeBoton, formatDateTime } from '@/components/ui'
import { MERCHANT_CATEGORY_LABEL } from '@/features/admin/api'
import type { MerchantRow } from '@/features/admin/api'
import { ESTADOS_LOCAL } from '@/features/admin/estados'

/**
 * Quién es el local y dónde está lo suyo, siempre a la vista.
 *
 * El nombre solo estaba en la barra de arriba y el estado al fondo de la
 * pestaña Resumen. Aquí van con su RIF y su empresa —con eso se reclama—, y
 * las puertas a sus listas: sus consumos y sus pagos. Lo que se le debe va
 * en el carril; terminarlo, en el «⋯».
 */
export function Cabecera({
  merchant,
  menu,
}: {
  merchant: MerchantRow
  menu: ReadonlyArray<HuecoDeMenu>
}) {
  const estado = ESTADOS_LOCAL[merchant.status]

  const puerta = `whitespace-nowrap ${claseDeBoton('tonal', 'sm')}`

  return (
    <CabeceraDeFicha
      identidad={<LogoLocal name={merchant.name} logoUrl={merchant.logoUrl} size="lg" />}
      nombre={merchant.name}
      insignias={
        <>
          <Badge tone={estado.tone} icono>
            {estado.label}
          </Badge>
          {merchant.isTest && <Badge>Clínica de prueba</Badge>}
        </>
      }
      datos={[
        merchant.taxId ?? 'Sin RIF',
        merchant.legalName && merchant.legalName !== merchant.name ? merchant.legalName : null,
        merchant.city,
        merchant.category ? MERCHANT_CATEGORY_LABEL[merchant.category] : null,
        `Alta el ${formatDateTime(merchant.createdAt)}`,
      ]}
      acciones={
        <>
          <Link to="/admin/financiamientos" search={{ local: merchant.id }} className={puerta}>
            Sus financiamientos
          </Link>
          <Link to="/admin/pagos-clinicas/$id" params={{ id: merchant.id }} className={puerta}>
            Sus pagos
          </Link>
        </>
      }
      menu={menu}
    />
  )
}
