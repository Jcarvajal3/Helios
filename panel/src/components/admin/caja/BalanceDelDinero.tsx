import { useQuery } from '@tanstack/react-query'

import {
  InfoDot,
  Seccion,
  Stat,
  StatGrid,
  estadoDeConsulta,
  estadoDeConsultas,
  formatDayShort,
  formatUsd,
} from '@/components/ui'
import { NoSeParte } from '@/components/admin/metricas/kit'
import { DEFINICIONES } from '@/features/admin/definitions'
import { consultaDeLaFoto, consultaDeLaSemana } from '@/features/admin/metricas/caja/consultas'
import type { FotoDeCaja } from '@/features/admin/metricas/caja/lectura'
import { MOTIVO_CAJA } from '@/features/admin/metricas/caja/textos'
import { textoDeDesglose } from '@/features/admin/metricas/formato'

/** Una parte de una cifra, pintada dentro de su tarjeta. */
type Parte = { clave: string; rotulo: string; valor: number; que?: string }

/** Por debajo de un céntimo, dos importes son el mismo. */
const CENTIMO = 0.005

/** Lo que se debe, partido: cuotas (consumo + service fee) y cargos por atraso aparte. */
function partesDeLoQueSeDebe(d: FotoDeCaja['porCobrar']): Parte[] {
  return [
    { clave: 'consumo', rotulo: 'Financiamiento', valor: d.financedUsd, que: DEFINICIONES.principalCalle.what },
    { clave: 'servicio', rotulo: 'Service fee (IVA incluido)', valor: d.feeUsd, que: DEFINICIONES.comisionEnDeuda.what },
    {
      clave: 'cargos',
      rotulo: 'Cargos por atraso',
      valor: d.cargosUsd,
      que: 'Los cargos por atraso: van aparte de las cuotas y son ingreso de Helios, sin IVA.',
    },
  ]
}

/**
 * La provisión del libro lleva el consumo, su service fee con IVA y los cargos
 * castigados: se dice en el InfoDot para que nadie la busque en la tarjeta.
 */
function perdidoEnElLibro(f: FotoDeCaja): string {
  if (f.perdidoLibroUsd === null || f.perdidoLibroUsd < CENTIMO) return ''
  return ` En el libro contable, la provisión es ${formatUsd(f.perdidoLibroUsd)}: ese financiamiento, su service fee con IVA y los cargos por atraso castigados.`
}

/** Si el libro contable dice lo mismo que lo calculado, se dice; si no, cuánto dice. */
function segunElLibro(partes: number, libro: number | null): string {
  if (libro === null) return ''
  if (Math.abs(libro - partes) < CENTIMO) return ' Cuadra con el libro contable.'
  return ` El libro contable dice ${formatUsd(libro)}: la diferencia es lo que falta por asentar.`
}

/**
 * El balance de hoy: qué hay, qué nos deben, qué debemos, qué ganamos y qué
 * se perdió. No sigue a la semana: es una foto de ahora.
 *
 * La caja es el titular; lo que quedaría si hoy se le pagara a todos los
 * locales va en su pie. Todo lo que se paga en cuotas va con sus partes
 * DENTRO de su tarjeta (consumo, service fee con IVA, y los cargos por atraso
 * aparte): la regla del fee no deja enseñar un total sin sus sumandos. El
 * service fee ganado es el SIN IVA de los consumos (el mismo de General y de
 * Semana), y lo cobrado es la parte que ya pagó la gente.
 *
 * Con un local, la caja no se parte (es de todo Ronda) y el resto es lo de
 * sus consumos y lo que se le debe a él.
 */
export function BalanceDelDinero({ semana, local }: { semana: string; local: string | null }) {
  const foto = useQuery(consultaDeLaFoto(local))
  // La misma lectura que «Lo que se movió en la semana»: no es otra consulta.
  const laSemana = useQuery(consultaDeLaSemana(semana, local))

  const estado = estadoDeConsulta(foto)
  const estadoLocales = estadoDeConsultas([laSemana])
  const reintentar = () => void foto.refetch()

  const f = foto.data
  const pp = laSemana.data?.porPagarLocales
  const debe = f ? f.porCobrar.payableUsd + f.porCobrar.cargosUsd : 0

  return (
    <Seccion
      titulo={local ? 'Balance de hoy de esta clínica' : 'Balance de hoy'}
      info="A día de hoy, sea cual sea la semana elegida. «Dinero en caja» sale del libro contable; lo demás se calcula de las cuotas, los cargos por atraso, los financiamientos y las liquidaciones a clínicas. Las cuentas de prueba no suman en ninguna de estas cifras."
    >
      <div className="flex flex-col gap-4">
        {local ? (
          <NoSeParte variante="bloque" motivo={MOTIVO_CAJA} />
        ) : (
          <Stat
            variant="hero"
            label={DEFINICIONES.caja.label}
            value={f ? formatUsd(f.cajaUsd ?? 0) : ''}
            info={`Del libro contable. ${DEFINICIONES.caja.what} El pie: ${DEFINICIONES.capitalLibre.what}`}
            hint={f && f.capitalLibreUsd !== null ? `${DEFINICIONES.capitalLibre.label} ${formatUsd(f.capitalLibreUsd)}` : undefined}
            link={{ to: '/admin/contabilidad', search: { vista: 'libro' } }}
            estado={estado}
            onReintentar={reintentar}
          />
        )}

        <StatGrid cols={4}>
          <Stat
            label={local ? 'Por cobrar por sus financiamientos (financiamiento + fee + cargos)' : 'Por cobrar a pacientes (financiamiento + fee + cargos)'}
            value={f ? formatUsd(debe) : ''}
            info={
              f
                ? `Calculado de las cuotas sin pagar (ni dadas por perdidas) y de los cargos por atraso pendientes. ${DEFINICIONES.deudaUsuarios.what}${segunElLibro(debe, f.porCobrarLibroUsd)}`
                : undefined
            }
            hint={f && (f.vencido.payableUsd > 0 ? `Vencido: ${textoDeDesglose(f.vencido)}` : 'Nada vencido')}
            visual={f && <Partes partes={partesDeLoQueSeDebe(f.porCobrar)} />}
            // Lleva al calendario: cuánto vence cada día y de qué local.
            link={{ to: '/admin/cobranza', search: { vista: 'calendario' } }}
            estado={estado}
            onReintentar={reintentar}
          />
          <Stat
            label={local ? 'Por pagar a la clínica' : DEFINICIONES.porPagarLocales.label}
            value={pp ? formatUsd(pp.totalUsd) : ''}
            info={`Calculado de las liquidaciones a clínicas (lo mismo que Pagos a clínicas), no del libro contable. Es su neto: no lleva el service fee. ${DEFINICIONES.porPagarLocales.what}`}
            hint={
              pp &&
              `Este cierre${pp.fechaCierre ? ` (${formatDayShort(pp.fechaCierre)})` : ''}: ${formatUsd(pp.esteCierreUsd)}${
                pp.atrasadoUsd > CENTIMO ? `, de eso atrasado ${formatUsd(pp.atrasadoUsd)}` : ''
              }`
            }
            link={{ to: '/admin/pagos-clinicas' }}
            estado={estadoLocales}
            onReintentar={() => void laSemana.refetch()}
          />
          <Stat
            label="Service fee ganado desde el inicio, sin IVA"
            value={f ? formatUsd(f.servicio.ganadoUsd) : ''}
            info="Calculado de todos los financiamientos confirmados desde el primer día: su service fee sin el IVA (que se cobra y se remite). Se gana al confirmar el financiamiento y se cobra al pagar la cuota. Los cargos por atraso son otro ingreso y van aparte."
            hint={
              f &&
              `Aparte, cargos por atraso desde el inicio: ${formatUsd(f.servicio.cargosGanadosUsd)} generados, ${formatUsd(f.servicio.cargosCobradosUsd)} cobrados`
            }
            visual={
              f && (
                <Partes
                  partes={[
                    {
                      clave: 'cobrado',
                      rotulo: 'De eso, ya cobrado',
                      valor: f.servicio.cobradoUsd,
                      que: 'Calculado de las cuotas ya pagadas: la parte del service fee, sin IVA, que iba dentro de cada una.',
                    },
                  ]}
                />
              )
            }
            link={{ to: '/admin/contabilidad', search: { vista: 'exportacion' } }}
            estado={estado}
            onReintentar={reintentar}
          />
          <Stat
            label={`${DEFINICIONES.castigado.label} (sin fee)`}
            // En consumo, como en General: es lo que Ronda ya le pagó al local
            // y no volverá. El service fee y los cargos que no se cobrarán van en
            // el pie, aparte: no se suman al consumo.
            value={f ? formatUsd(f.perdido.financedUsd) : ''}
            info={f ? `Sin el service fee: la cifra es el financiamiento perdido, calculado de las cuotas dadas por perdidas y sin pagar. ${DEFINICIONES.castigado.what}${perdidoEnElLibro(f)}` : undefined}
            hint={
              f &&
              (f.perdido.payableUsd > CENTIMO || f.perdido.cargosUsd > CENTIMO
                ? `Además no se cobrarán: service fee ${formatUsd(f.perdido.feeUsd)} · cargos ${formatUsd(f.perdido.cargosUsd)}`
                : 'Nada perdido todavía')
            }
            link={{ to: '/admin/metricas', search: { vista: 'mora' } }}
            estado={estado}
            onReintentar={reintentar}
          />
        </StatGrid>
      </div>
    </Seccion>
  )
}

/**
 * Las partes de una cifra, dentro de su tarjeta. Van por encima del enlace de
 * la tarjeta (`relative z-10`) para que su `InfoDot` se pueda pulsar.
 */
function Partes({ partes }: { partes: Parte[] }) {
  return (
    <dl className="relative z-10 flex flex-col gap-1.5 border-t border-panel-hairline pt-3">
      {partes.map((parte) => (
        <div key={parte.clave} className="flex items-baseline justify-between gap-2">
          <dt className="flex items-center gap-1.5 type-panel-caption text-on-surface-variant">
            {parte.rotulo}
            {parte.que && <InfoDot title={parte.rotulo} what={parte.que} />}
          </dt>
          <dd className="type-panel-label tabular-nums text-on-surface">{formatUsd(parte.valor)}</dd>
        </div>
      ))}
    </dl>
  )
}
