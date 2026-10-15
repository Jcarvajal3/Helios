import { Link } from '@tanstack/react-router'
import { FileDown } from 'lucide-react'

import { CabeceraDeFicha } from '@/components/admin/ficha'
import type { HuecoDeMenu } from '@/components/admin/ficha'
import { LogoLocal } from '@/components/admin/directorio/LogoLocal'
import { Badge, Button, claseDeBoton, formatDateTime } from '@/components/ui'
import { MERCHANT_CATEGORY_LABEL } from '@/features/admin/api'
import type { MerchantRow } from '@/features/admin/api'
import { ESTADOS_LOCAL } from '@/features/admin/estados'

/**
 * Quién es el local y dónde está lo suyo, siempre a la vista.
 *
 * El nombre solo estaba en la barra de arriba y el estado al fondo de la
 * pestaña Resumen. Aquí van con su RIF y su empresa —con eso se reclama—, y
 * las puertas a sus listas: sus consumos y sus pagos. Lo que se le debe va
 * en el carril; terminarlo, en el «⋯». Los datos de alta para el contrato
 * van a la vista y no en el «⋯»: es lo que se busca al redactarlo.
 */
export function Cabecera({
  merchant,
  menu,
  datosDeAlta,
}: {
  merchant: MerchantRow
  menu: ReadonlyArray<HuecoDeMenu>
  /** Bajar en CSV los datos de alta de esta clínica y su titular. */
  datosDeAlta: { pendiente: boolean; onDescargar: () => void }
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
          <Button
            size="sm"
            variant="tonal"
            disabled={datosDeAlta.pendiente}
            title="Los datos de alta de esta clínica, con su médico titular y su cuenta de pago, para redactar el contrato"
            onClick={datosDeAlta.onDescargar}
          >
            <FileDown size={15} aria-hidden />
            {datosDeAlta.pendiente ? 'Leyendo…' : 'Datos de alta (CSV)'}
          </Button>
        </>
      }
      menu={menu}
    />
  )
}
