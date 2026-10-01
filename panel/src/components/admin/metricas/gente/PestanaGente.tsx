import { CrecimientoCohortes } from '@/components/admin/CrecimientoCohortes'
import type { EstadoDeCohortes } from '@/components/admin/CrecimientoCohortes'
import { CrecimientoGente } from '@/components/admin/CrecimientoGente'
import { CrecimientoUso } from '@/components/admin/CrecimientoUso'
import type { BusquedaGente } from '@/features/admin/metricas/gente/busqueda'
import {
  VENTANA_POR_DEFECTO,
  comparacionDeLaVentana,
  rangoDeLaVentana,
  ventanaAMedias,
} from '@/features/admin/metricas/gente/ventana'
import type { IdSubpestana } from '@/features/admin/metricas/pestanas'
import type { PropsSubpestana } from '@/features/admin/metricas/tipos'
import { BarraDeVentana } from './BarraDeVentana'

type SubpestanaGente = IdSubpestana<'gente'>

/** Las sub-pestañas que cuentan lo que pasó en unos días, y por eso llevan ventana. */
function llevaVentana(sub: SubpestanaGente): boolean {
  return sub === 'resumen' || sub === 'uso'
}

/**
 * Métricas › Pacientes: ¿quién llega, quién se financia y quién vuelve?
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Lo que era Crecimiento (Resumen, Uso y las cohortes de registro,
 * que aquí se llaman Retención para no chocar con las de consumo, en Cobros) y el
 * Perfil de la gente, cada uno con su pregunta. Son las sub-pestañas de
 * Gente, que elige el marco (`pestanas.ts`):
 *
 *   Resumen    ¿cuántas entran y hasta qué escalón llegan?
 *   Uso        ¿cuánto gasta cada quien, y de cuántos depende el total?
 *   Retención  la que entró junta, ¿siguió junta?
 *
 * Las dos primeras miran una ventana que acaba en la semana elegida arriba
 * (la semana, 4, 12 o desde el inicio). La Retención tiene su propio eje
 * —el cubo y cuántos— y abre por la cohorte de la semana elegida. El Perfil
 * no sigue a la semana: es de la gente, no de unos días.
 *
 * Con un local, todo es de la gente que consumió en él; lo del padrón
 * (registros, estados) dice «No se parte».
 */
export function PestanaGente({
  sub,
  semana,
  enCurso,
  hoy,
  local,
  busqueda,
  cambiarBusqueda,
}: PropsSubpestana<BusquedaGente, SubpestanaGente>) {
  const ventana = busqueda.ventana ?? VENTANA_POR_DEFECTO
  const rango = rangoDeLaVentana(ventana, semana, hoy)
  const comparacion = comparacionDeLaVentana(ventana, ventanaAMedias(rango, semana))

  const cohortes: EstadoDeCohortes = {
    cubo: busqueda.cubo ?? 'semana',
    cuantos: busqueda.cuantos,
    ver: busqueda.ver ?? 'una',
    medida: busqueda.medida ?? 'gente',
    cohorte: busqueda.cohorte,
  }

  return (
    <div className="flex flex-col gap-6">
      {llevaVentana(sub) && (
        <BarraDeVentana
          ventana={ventana}
          rango={rango}
          local={local}
          comparacion={comparacion}
          onVentana={(v) =>
            cambiarBusqueda({ ventana: v === VENTANA_POR_DEFECTO ? undefined : v }, { reemplazar: true })
          }
        />
      )}

      {sub === 'resumen' && <CrecimientoGente rango={rango} local={local} comparar={comparacion !== null} />}
      {sub === 'uso' && <CrecimientoUso rango={rango} local={local} />}
      {sub === 'retencion' && (
        <CrecimientoCohortes
          estado={cohortes}
          onCambiar={(cambios) => cambiarBusqueda(cambios, { reemplazar: true })}
          local={local}
          lunes={semana}
          enCurso={enCurso}
        />
      )}
    </div>
  )
}
