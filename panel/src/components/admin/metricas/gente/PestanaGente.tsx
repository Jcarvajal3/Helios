import { CrecimientoGente } from '@/components/admin/CrecimientoGente'
import { EstadosYNiveles } from '@/components/admin/crecimiento/EstadosYNiveles'
import type { BusquedaGente } from '@/features/admin/metricas/gente/busqueda'
import {
  VENTANA_POR_DEFECTO,
  comparacionDeLaVentana,
  rangoDeLaVentana,
  ventanaAMedias,
} from '@/features/admin/metricas/gente/ventana'
import type { PropsPestana } from '@/features/admin/metricas/tipos'
import { BarraDeVentana } from './BarraDeVentana'

/**
 * Métricas › Pacientes: ¿cuántos registran las clínicas y cuántos pagan en
 * cuotas?
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Una sola vista, sin sub-pestañas: el Resumen de la ventana que acaba en la
 * semana elegida arriba (la semana, 4, 12 o desde el inicio) y, debajo, los
 * estados de las cuentas y los niveles, que son de hoy.
 *
 * Las antiguas Uso (medianas, histogramas, concentración del gasto) y
 * Retención (cohortes de registro: «¿siguen financiándose?») eran el análisis
 * de una app de consumo frecuente. En Helios un paciente vuelve cuando tiene
 * otra consulta. Un enlace viejo con `sub=uso` o `sub=retencion` cae aquí.
 *
 * Con una clínica, todo es de los pacientes que se atendieron en ella; lo del
 * padrón (registros, estados) dice «No se parte».
 */
export function PestanaGente({
  semana,
  hoy,
  local,
  busqueda,
  cambiarBusqueda,
}: PropsPestana<BusquedaGente>) {
  const ventana = busqueda.ventana ?? VENTANA_POR_DEFECTO
  const rango = rangoDeLaVentana(ventana, semana, hoy)
  const comparacion = comparacionDeLaVentana(ventana, ventanaAMedias(rango, semana))

  return (
    <div className="flex flex-col gap-6">
      <BarraDeVentana
        ventana={ventana}
        rango={rango}
        local={local}
        comparacion={comparacion}
        onVentana={(v) =>
          cambiarBusqueda({ ventana: v === VENTANA_POR_DEFECTO ? undefined : v }, { reemplazar: true })
        }
      />
      <CrecimientoGente rango={rango} local={local} comparar={comparacion !== null} />
      <EstadosYNiveles rango={rango} local={local} />
    </div>
  )
}
