import { Seccion } from '@/components/ui'
import { BalanceDelDinero } from '@/components/admin/caja/BalanceDelDinero'
import { ProyeccionDeCaja } from '@/components/admin/caja/ProyeccionDeCaja'

import { SaldoDelBanco } from '@/components/admin/caja/SaldoDelBanco'
import { NoSeParte } from '@/components/admin/metricas/kit'
import type { BusquedaCaja } from '@/features/admin/metricas/caja/busqueda'
import { MOTIVO_BANCO } from '@/features/admin/metricas/caja/textos'
import type { IdSubpestana } from '@/features/admin/metricas/pestanas'
import type { PropsSubpestana } from '@/features/admin/metricas/tipos'
import { CapitalComprometido } from './CapitalComprometido'
import { MovimientosDeLaSemana } from './MovimientosDeLaSemana'


/**
 * Métricas › Caja: ¿cuánto dinero hay y cuánto hará falta?
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Lo que era Dinero, más el capital comprometido del Resumen y lo que se
 * movió en la semana elegida arriba. Pinta las dos sub-pestañas de Caja, que
 * elige el marco (`pestanas.ts`):
 *
 *   Balance             lo que entró y salió en la semana (con su frase), el
 *                       balance de hoy según el libro y el capital con su
 *                       semáforo
 *   Proyección y banco  lo que vendrá desde hoy, lo que se proyectó cada
 *                       lunes frente a lo que pasó, y el saldo del banco
 *                       (donde se apunta: es la acción de la pestaña)
 *
 * Solo lo de la semana sigue a la semana elegida; el balance, el capital y
 * la proyección son de hoy, y cada bloque lo dice. Con un local, lo del local
 * se parte (lo que deben por sus consumos, lo que se le debe y se le
 * transfirió) y la caja no, que es de todo Helios.
 */
export function PestanaCaja({
  sub,
  semana,
  local,
  nombreLocal,
  busqueda,
}: PropsSubpestana<BusquedaCaja, IdSubpestana<'caja'>>) {
  return (
    <div className="flex flex-col gap-6">
      {sub === 'balance' && (
        <div className="flex flex-col gap-10">
          <MovimientosDeLaSemana semana={semana} local={local} nombreLocal={nombreLocal} />
          <BalanceDelDinero semana={semana} local={local} />
          <CapitalComprometido local={local} />
        </div>
      )}

      {sub === 'proyeccion' && (
        <div className="flex flex-col gap-10">
          <ProyeccionDeCaja local={local} />
          {local ? (
            <Seccion titulo="Saldo del banco">
              <NoSeParte variante="bloque" motivo={MOTIVO_BANCO} />
            </Seccion>
          ) : (
            <SaldoDelBanco key={busqueda.corte ?? 'hoy'} corteInicial={busqueda.corte} />
          )}
        </div>
      )}
    </div>
  )
}
