import { createFileRoute, useNavigate } from '@tanstack/react-router'

import { MaintenanceTab } from '@/components/MaintenanceTab'
import { Niveles } from '@/components/admin/Niveles'
import { Bitacora } from '@/components/admin/ajustes/Bitacora'
import type { FiltrosBitacora } from '@/components/admin/ajustes/Bitacora'
import { Contacto } from '@/components/admin/ajustes/Contacto'
import { CuentaDeCobro } from '@/components/admin/ajustes/CuentaDeCobro'
import { Equipo } from '@/components/admin/ajustes/Equipo'
import { Feriados } from '@/components/admin/ajustes/Feriados'
import { NumerosDeCapacitacion } from '@/components/admin/ajustes/NumerosDeCapacitacion'
import { Parametros } from '@/components/admin/ajustes/Parametros'
import { Seguridad } from '@/components/admin/ajustes/Seguridad'
import { SubmenuAjustes } from '@/components/admin/ajustes/SubmenuAjustes'
import { TasaBcv } from '@/components/admin/ajustes/TasaBcv'
import { Terminos } from '@/components/admin/ajustes/Terminos'
import { hoyCaracas } from '@/components/ui'
import { PESTANAS_ANCHAS, leerBusquedaAjustes, pestanaActiva } from '@/features/admin/ajustesNavegacion'

export const Route = createFileRoute('/admin/ajustes')({
  staticData: { title: 'Ajustes', width: 'wide' },
  component: AjustesPage,
  validateSearch: leerBusquedaAjustes,
})

/**
 * Ajustes: las reglas del negocio, las condiciones del comprobante, el
 * equipo, lo que queda escrito y el freno de emergencia.
 *
 * La tasa abre por defecto porque es la única que puede parar el día: sin
 * ella no se cotiza un pago. El operador entra y ve; lo que no le toca se
 * pinta apagado con el motivo, y el servidor lo rechaza igual.
 *
 * Todo lo que decide lo que se ve —la sección, los filtros de la bitácora, el
 * año de los feriados— va en la URL.
 */
function AjustesPage() {
  const navigate = useNavigate({ from: '/admin/ajustes' })
  const search = Route.useSearch()
  const tab = pestanaActiva(search.tab)

  function cambiarBitacora(filtros: FiltrosBitacora) {
    void navigate({ search: { tab: 'bitacora', ...filtros } })
  }

  return (
    <div className="grid gap-5 lg:grid-cols-[13rem_minmax(0,1fr)] lg:gap-8">
      <SubmenuAjustes activa={tab} />

      <div className={PESTANAS_ANCHAS.includes(tab) ? undefined : 'max-w-(--panel-measure-normal)'}>
        {tab === 'tasa' && <TasaBcv />}
        {tab === 'parametros' && <Parametros />}
        {tab === 'niveles' && <Niveles />}
        {tab === 'feriados' && (
          <Feriados
            anio={search.anio ?? Number(hoyCaracas().slice(0, 4))}
            onAnio={(anio) => void navigate({ search: { tab: 'feriados', anio } })}
          />
        )}
        {tab === 'cobro' && <CuentaDeCobro />}
        {tab === 'contacto' && <Contacto />}
        {tab === 'terminos' && <Terminos />}
        {tab === 'equipo' && <Equipo />}
        {tab === 'seguridad' && <Seguridad />}
        {tab === 'demo' && <NumerosDeCapacitacion />}
        {tab === 'bitacora' && (
          <Bitacora
            filtros={{
              tema: search.tema,
              quien: search.quien,
              desde: search.desde,
              hasta: search.hasta,
              pagina: search.pagina,
            }}
            onCambiar={cambiarBitacora}
          />
        )}
        {tab === 'mantenimiento' && <MaintenanceTab />}
      </div>
    </div>
  )
}
