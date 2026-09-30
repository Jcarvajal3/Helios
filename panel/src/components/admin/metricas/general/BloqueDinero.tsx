import { Stat, StatGrid, formatUsd } from '@/components/ui'
import { CifraConTendencia } from '@/components/admin/metricas/kit'
import { contar, pieCargos, pieDeCuotas, piePerdido, piePorPagar } from '@/features/admin/metricas/general/cifras'
import { CIFRAS_GENERAL as T } from '@/features/admin/metricas/general/textos'
import { BloqueGeneral } from './BloqueGeneral'
import { DesgloseEnTarjeta } from './DesgloseEnTarjeta'
import type { LecturaGeneral } from './lectura'

/**
 * El dinero, en dos bloques según el periodo, que va en su título: la
 * pantalla dice «Desde el inicio», pero lo que se debe, la caja y lo que se
 * les debe a los locales son fotos de HOY.
 *
 *   Dinero hoy              por cobrar, de ello vencido, la caja y lo que
 *                           se les debe a los locales.
 *   Dinero desde el inicio  en una fila, lo movido y lo cobrado; en otra, lo
 *                           ganado (service fee sin IVA y cargos por atraso)
 *                           y lo perdido.
 *
 * La regla del fee, cifra por cifra:
 *   - Movido, por cobrar, vencido y cobrado son importes de cuotas (con el service
 *     fee y su IVA dentro), y por eso dicen «(facturado + fee)» o van debajo
 *     de uno que lo dice, y llevan SIEMPRE su desglose «Facturado / Service
 *     fee + IVA» dentro de la tarjeta.
 *   - Lo ganado va en dos tarjetas: el service fee SIN IVA y los cargos por
 *     atraso. Ninguna se suma a la otra ni al facturado.
 *   - Lo perdido va sin fee: es lo que Helios ya le pagó al local.
 *   - La caja y lo que se debe a los locales son del libro y de Pagos a
 *     locales, las mismas cifras que en Caja.
 */
export function BloqueDinero({ lectura }: { lectura: LecturaGeneral }) {
  const { datos: g, estado, local, reintentar } = lectura
  const conLocal = local ?? undefined
  const d = g?.dinero

  return (
    <>
      <BloqueGeneral titulo="Dinero hoy" lectura={lectura}>
        <StatGrid cols={4}>
          {/* Las cuotas van en el `Stat` del panel directamente: el desglose es
              su forma (`visual`), que la tarjeta del kit no tiene. */}
          <Stat
            label={T.porCobrar.titulo}
            info={T.porCobrar.que}
            value={d ? formatUsd(d.porCobrar.payableUsd) : ''}
            visual={d && <DesgloseEnTarjeta desglose={d.porCobrar} />}
            hint={d && pieDeCuotas(d.porCobrar.cuotas, d.porCobrar.personas)}
            link={{ to: '/admin/metricas', search: { vista: 'mora', local: conLocal } }}
            estado={estado}
            onReintentar={reintentar}
          />
          <Stat
            label={T.vencido.titulo}
            info={T.vencido.que}
            value={d ? formatUsd(d.vencido.payableUsd) : ''}
            visual={d && <DesgloseEnTarjeta desglose={d.vencido} />}
            hint={d && pieDeCuotas(d.vencido.cuotas, d.vencido.personas)}
            link={{ to: '/admin/metricas', search: { vista: 'mora', local: conLocal } }}
            estado={estado}
            onReintentar={reintentar}
          />
          <CifraConTendencia
            titulo={T.caja.titulo}
            info={T.caja.que}
            valor={d?.cajaUsd == null ? '' : formatUsd(d.cajaUsd)}
            pie="Del libro, no del banco"
            noSeParte={local !== null && 'La caja es de todo Helios y no de una clínica. Quita la clínica de arriba para verla.'}
            link={{ to: '/admin/metricas', search: { vista: 'caja', sub: 'balance' } }}
            estado={estado}
            onReintentar={reintentar}
          />
          <CifraConTendencia
            titulo={T.porPagarLocales.titulo}
            info={T.porPagarLocales.que}
            valor={d ? formatUsd(d.porPagarLocales.totalUsd) : ''}
            pie={g && piePorPagar(g)}
            link={{ to: '/admin/pagos-clinicas' }}
            estado={estado}
            onReintentar={reintentar}
          />
        </StatGrid>
      </BloqueGeneral>

      <BloqueGeneral titulo="Dinero desde el inicio" lectura={lectura}>
        {/* Lo movido, y de ello lo cobrado: los dos en cuotas y con su desglose. */}
        <StatGrid cols={d?.movido === null ? 4 : 2}>
          {d?.movido !== null && (
            <Stat
              label={T.movido.titulo}
              info={T.movido.que}
              value={d ? formatUsd(d.movido.payableUsd) : ''}
              visual={d && <DesgloseEnTarjeta desglose={d.movido} />}
              hint={
                d &&
                `${contar(d.movido.consumos, 'financiamiento', 'financiamientos')} · ${contar(d.movido.cuotas, 'cuota', 'cuotas')}`
              }
              link={{ to: '/admin/metricas', search: { vista: 'semana', sub: 'rendimiento', local: conLocal } }}
              estado={estado}
              onReintentar={reintentar}
            />
          )}
          <Stat
            label={T.cobrado.titulo}
            info={T.cobrado.que}
            value={d ? formatUsd(d.cobrado.payableUsd) : ''}
            visual={d && <DesgloseEnTarjeta desglose={d.cobrado} />}
            hint={
              d &&
              (d.cobrado.cuotas === 0
                ? 'Ninguna cuota pagada todavía'
                : contar(d.cobrado.cuotas, 'cuota pagada', 'cuotas pagadas'))
            }
            link={{ to: '/admin/metricas', search: { vista: 'caja', sub: 'balance', local: conLocal } }}
            estado={estado}
            onReintentar={reintentar}
          />
        </StatGrid>
        <StatGrid cols={3} className="mt-4">
          <CifraConTendencia
            titulo={T.servicio.titulo}
            info={T.servicio.que}
            valor={d ? formatUsd(d.servicioUsd) : ''}
            pie="Nunca se suma al financiado"
            link={{ to: '/admin/metricas', search: { vista: 'semana', sub: 'rendimiento', local: conLocal } }}
            estado={estado}
            onReintentar={reintentar}
          />
          <CifraConTendencia
            titulo={T.cargos.titulo}
            info={T.cargos.que}
            valor={d ? formatUsd(d.cargos.devengadoUsd) : ''}
            pie={g && pieCargos(g)}
            link={{ to: '/admin/metricas', search: { vista: 'semana', sub: 'rendimiento', local: conLocal } }}
            estado={estado}
            onReintentar={reintentar}
          />
          <CifraConTendencia
            titulo={T.perdido.titulo}
            info={T.perdido.que}
            valor={d ? formatUsd(d.perdido.financedUsd) : ''}
            pie={g && piePerdido(g)}
            link={{ to: '/admin/metricas', search: { vista: 'mora', local: conLocal } }}
            estado={estado}
            onReintentar={reintentar}
          />
        </StatGrid>
      </BloqueGeneral>
    </>
  )
}
