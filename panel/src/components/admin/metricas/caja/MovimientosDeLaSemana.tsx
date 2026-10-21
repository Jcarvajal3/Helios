import { useQuery } from '@tanstack/react-query'

import { Callout, NoSePudoLeer, StatGrid, estadoDeConsulta, formatUsd } from '@/components/ui'
import { CifraConTendencia, FraseConCifras, SeccionMetricas } from '@/components/admin/metricas/kit'
import type { ChispaProps } from '@/components/admin/metricas/kit'
import {
  descuadreDelLibro,
  etiquetaConDesglose,
  etiquetaDeSemana,
  fraseDeLaSemana,
} from '@/features/admin/metricas/caja/calculos'
import { consultaDeLaSemana } from '@/features/admin/metricas/caja/consultas'
import type { CajaDeLaSemana, SemanaDeCaja } from '@/features/admin/metricas/caja/lectura'
import { MOTIVO_CAJA } from '@/features/admin/metricas/caja/textos'
import { delta, textoDeDesglose } from '@/features/admin/metricas/formato'
import type { Delta } from '@/features/admin/metricas/formato'

const QUE_ES =
  'Los cobros, las transferencias a clínicas y la Comisión Helios de la semana elegida arriba, por el día operativo en que ocurrieron: una cuota cuenta el día en que se aprobó su pago; una transferencia, el día de su asiento. Todas las cifras se calculan de las cuotas, los cargos por atraso, las transferencias y los financiamientos, salvo «Dinero en caja al cierre», que sale del libro contable. Las flechas comparan con la semana anterior a la misma altura.'

type Campo = (s: SemanaDeCaja) => number | null

/**
 * La chispa de las ocho semanas de una cifra, la elegida la última.
 *
 * `serie` es el nombre que va junto a la cifra en el globo de cada barra
 * («Cobrado en cuotas (consumo + comisión)»): así el globo también dice si lleva
 * la comisión.
 */
function chispaDe(
  c: CajaDeLaSemana,
  campo: Campo,
  serie: string,
  etiqueta: (s: SemanaDeCaja) => string = etiquetaDeSemana,
): Omit<ChispaProps, 'alto'> & { serie: string } {
  return {
    valores: c.semanas.map(campo),
    etiquetas: c.semanas.map(etiqueta),
    rotulo: `${serie}, las últimas ocho semanas`,
    formato: formatUsd,
    serie,
  }
}

/**
 * Métricas › Caja: lo que se movió en la semana.
 *
 * Una frase con los números dentro y seis cifras: lo que entró de cuotas
 * (siempre con su consumo y su service fee), los cargos por atraso cobrados
 * (aparte), lo que salió a los locales, el service fee sin IVA ganado y el
 * cobrado, y la caja al cierre. Con un local, lo de sus consumos y lo que se
 * le transfirió; la caja no se parte.
 *
 * Cada chispa enseña el globo del kit al señalar una semana; la de lo que
 * entró de cuotas lleva en él sus dos partes, como la tarjeta.
 *
 * Si el libro de caja no dice lo mismo que las cuotas, se avisa: es la
 * comprobación de que la cifra se puede creer.
 */
export function MovimientosDeLaSemana({
  semana,
  local,
  nombreLocal,
}: {
  semana: string
  local: string | null
  nombreLocal: string | null
}) {
  const consulta = useQuery(consultaDeLaSemana(semana, local))
  const estado = estadoDeConsulta(consulta)
  const reintentar = () => void consulta.refetch()
  const c = consulta.data
  const m = c?.movimientos
  const a = c?.movimientosAnterior
  const cambio = (actual: number | undefined, anterior: number | undefined, arribaEsBueno: boolean | null): Delta | null =>
    actual === undefined || anterior === undefined ? null : delta(actual, anterior, { tipo: 'relativo', arribaEsBueno })
  const descuadre = m ? descuadreDelLibro(m) : null

  return (
    <SeccionMetricas
      titulo="Movimientos de la semana"
      info={QUE_ES}
      ayuda={c?.semana?.enCurso ? `Van ${c.dias} ${c.dias === 1 ? 'día' : 'días'} de semana` : undefined}
    >
      {consulta.isError ? (
        <NoSePudoLeer onReintentar={reintentar} />
      ) : (
        <FraseConCifras partes={c ? fraseDeLaSemana(c, nombreLocal) : []} cargando={!c} />
      )}

      <StatGrid cols={3}>
        <CifraConTendencia
          titulo="Cobrado en cuotas (financiamiento + comisión)"
          valor={m ? formatUsd(m.cobrado.payableUsd) : ''}
          pie={m && textoDeDesglose(m.cobrado)}
          delta={cambio(m?.cobrado.payableUsd, a?.cobrado.payableUsd, true)}
          chispa={
            c &&
            chispaDe(c, (s) => s.cobrado.payableUsd, 'Cobrado en cuotas (financiamiento + comisión)', etiquetaConDesglose)
          }
          info={`Calculado de las cuotas cuyo pago se aprobó en la semana: el financiamiento más la Comisión Helios (IVA incluido), siempre con sus dos partes. ${
            m ? `Son ${m.cobrado.cuotas} cuotas de ${m.cobrado.personas} pacientes.` : ''
          } Los cargos por atraso van aparte.`}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo="Cargos por atraso cobrados"
          valor={m ? formatUsd(m.cargosCobrados.usd) : ''}
          pie={m && `${m.cargosCobrados.n} ${m.cargosCobrados.n === 1 ? 'cargo' : 'cargos'} · ingreso de Helios, sin IVA`}
          delta={cambio(m?.cargosCobrados.usd, a?.cargosCobrados.usd, null)}
          chispa={c && chispaDe(c, (s) => s.cargosCobradosUsd, 'Cargos por atraso cobrados')}
          info="Calculado de los cargos por atraso pagados en la semana, por el día del pago. Son ingreso de Helios, sin IVA, y van aparte: nunca se suman a lo cobrado en cuotas."
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo={local ? 'Transferido a la clínica' : 'Transferido a clínicas'}
          valor={m ? formatUsd(m.transferido.usd) : ''}
          pie={m && `${m.transferido.n} ${m.transferido.n === 1 ? 'transferencia' : 'transferencias'}`}
          delta={cambio(m?.transferido.usd, a?.transferido.usd, null)}
          chispa={c && chispaDe(c, (s) => s.transferidoUsd, local ? 'Transferido a la clínica' : 'Transferido a clínicas')}
          info="Calculado de las transferencias registradas en Pagos a clínicas, por el día operativo de su asiento: su neto, sin la Comisión Helios."
          link={{ to: '/admin/pagos-clinicas' }}
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo="Comisión Helios ganada, sin IVA"
          valor={m ? formatUsd(m.servicioGanadoUsd) : ''}
          pie={m && `Sobre ${formatUsd(m.consumo.financedUsd)} financiado (sin comisión) en ${m.consumo.consumos} financiamientos`}
          delta={cambio(m?.servicioGanadoUsd, a?.servicioGanadoUsd, true)}
          chispa={c && chispaDe(c, (s) => s.servicioGanadoUsd, 'Comisión Helios ganada, sin IVA')}
          info="Calculado de los financiamientos confirmados en la semana: su Comisión Helios sin IVA, que se gana al confirmar el financiamiento. Nunca se suma al financiado."
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo="Comisión Helios cobrado, sin IVA"
          valor={m ? formatUsd(m.servicioCobradoUsd) : ''}
          pie="La comisión que iba en las cuotas cobradas"
          delta={cambio(m?.servicioCobradoUsd, a?.servicioCobradoUsd, true)}
          chispa={c && chispaDe(c, (s) => s.servicioCobradoUsd, 'Comisión Helios cobrado, sin IVA')}
          info="Calculado de las cuotas cobradas en la semana: la parte de Comisión Helios, sin IVA, que iba dentro de cada una (en proporción a su comisión). Es de financiamientos de semanas anteriores: lo ganado se cobra al pagar la cuota."
          estado={estado}
          onReintentar={reintentar}
        />
        <CifraConTendencia
          titulo="Dinero en caja al cierre"
          valor={c?.caja ? formatUsd(c.caja.alCierreUsd) : ''}
          pie={c?.caja && (c.semana?.enCurso ? 'Hoy, según el libro contable' : 'Al cierre del domingo, según el libro contable')}
          delta={c?.caja ? cambio(c.caja.alCierreUsd, c.caja.alCierreAnteriorUsd, true) : null}
          chispa={c && chispaDe(c, (s) => s.cajaAlCierreUsd, 'Dinero en caja al cierre')}
          info="Del libro contable: lo cobrado a los pacientes menos lo transferido a las clínicas y los ajustes, al cierre de la semana (o hoy, si va a medias). No es el saldo del banco."
          link={{ to: '/admin/contabilidad', search: { vista: 'libro' } }}
          noSeParte={local ? MOTIVO_CAJA : false}
          estado={estado}
          onReintentar={reintentar}
        />
      </StatGrid>

      {descuadre && (
        <Callout tone="warning" titulo="El libro contable no cuadra con lo calculado de las cuotas">
          {Math.abs(descuadre.cobradoUsd) >= 0.005 &&
            `El libro apunta ${formatUsd(descuadre.cobradoUsd)} de diferencia en lo cobrado (cuotas más cargos por atraso). `}
          {Math.abs(descuadre.transferidoUsd) >= 0.005 &&
            `En lo transferido a las clínicas, ${formatUsd(descuadre.transferidoUsd)}. `}
          Suele ser un pago con el asiento en otro día operativo.
        </Callout>
      )}
    </SeccionMetricas>
  )
}
