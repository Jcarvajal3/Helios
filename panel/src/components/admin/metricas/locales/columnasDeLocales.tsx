import type { ReactNode } from 'react'

import type { Column } from '@/components/DataTable'
import { SERIE } from '@/components/charts'
import { Badge, Tendencia, formatDay, formatUsd, formatPorcentaje } from '@/components/ui'
import { ESTADOS_LOCAL } from '@/features/admin/estados'
import { comoTendencia } from '@/features/admin/metricas/formato'
import { frenteALaAnterior, recurrentes, variacion } from '@/features/admin/metricas/locales/rendimiento'
import { diaConNumero } from '@/features/admin/metricas/locales/semanas'
import type { FilaLocal, LocalesDeLaSemana } from '@/features/admin/metricas/locales/tipos'
import type { Parametros } from '@/features/admin/parametros'
import { tonoCobroATiempo } from '@/features/admin/umbrales'
import { csvDinero } from '@/lib/csv'

import { ImporteConDesglose } from './ImporteConDesglose'
import { MarcaConGlobo } from '@/components/charts/lectura'

/** Una fila de la tabla: un local, o la de todos (siempre la última). */
export type FilaDeTabla = FilaLocal & { esTotal: boolean }

const RAYA = <span className="text-on-surface-variant">—</span>

/**
 * El orden de una columna. La fila de todos devuelve `null`, y `DataTable`
 * manda lo nulo al final en los dos sentidos: así «Todos» se queda abajo
 * ordene quien ordene.
 */
function orden(f: (l: FilaLocal) => string | number | null) {
  return (l: FilaDeTabla) => (l.esTotal ? null : f(l))
}

/** Lo de la fila de todos va en gris: es contexto, no un local más. */
function tenue(l: FilaDeTabla, contenido: ReactNode): ReactNode {
  return l.esTotal ? <span className="text-on-surface-variant">{contenido}</span> : contenido
}

function Linea({ children }: { children: ReactNode }) {
  return <span className="mt-0.5 block type-panel-caption text-on-surface-variant">{children}</span>
}

/**
 * La cabecera de lo que se le paga por la semana: «Liquidación prevista de la
 * semana (neto)» o, si ya pasó, «Liquidación de la semana (neto)». Es lo que
 * se le paga a la clínica (a diario, el día siguiente a cada vencimiento) por
 * las cuotas que vencían en la semana; el último pago cae el lunes siguiente.
 */
export function rotuloDelCierre(cierre: LocalesDeLaSemana['cierre']): string {
  return cierre.pasado
    ? `Liquidación de la semana, pagada hasta el ${diaConNumero(cierre.lunes)} (neto)`
    : `Liquidación prevista de la semana, hasta el ${diaConNumero(cierre.lunes)} (neto)`
}

/**
 * Las columnas de «Clínicas en la semana». Las de la maqueta a la vista;
 * lo que era de Rendimiento (ciudad, estado, días con financiamientos, mejor día) y
 * las partes de cada importe, ocultas pero en el menú y en el CSV.
 */
export function columnasDeLocales({
  d,
  parametros,
}: {
  d: LocalesDeLaSemana
  parametros: Parametros | undefined
}): Array<Column<FilaDeTabla>> {
  const antes = d.anterior.mismaAltura ? 'la semana pasada a la misma altura' : 'la semana anterior'
  const alCierre = d.semana.enCurso ? 'hoy' : 'al cierre de la semana'

  return [
    {
      key: 'local',
      header: 'Clínica',
      identity: true,
      sort: orden((l) => l.nombre),
      csv: (l) => l.nombre,
      cell: (l) =>
        l.esTotal ? (
          <span className="font-semibold text-on-surface-variant">Todas las clínicas</span>
        ) : (
          <div>
            <p className="font-semibold text-on-surface">{l.nombre}</p>
            {/* Solo se marca lo que no es normal: casi todos están activos. */}
            {l.estado !== null && l.estado !== 'active' && (
              <Badge tone={ESTADOS_LOCAL[l.estado].tone} icono>
                {ESTADOS_LOCAL[l.estado].label}
              </Badge>
            )}
          </div>
        ),
    },

    {
      key: 'consumo',
      header: 'Financiado (sin fee)',
      info: 'Sin el service fee: la suma de los financiamientos confirmados en la clínica esta semana. Los de prueba no cuentan.',
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.consumoUsd),
      csv: (l) => csvDinero(l.consumoUsd),
      cell: (l) => tenue(l, l.consumoUsd > 0 || l.esTotal ? <span className="font-semibold">{formatUsd(l.consumoUsd)}</span> : RAYA),
    },

    {
      key: 'anterior',
      header: 'Financiado frente a la anterior (%)',
      info: `El financiado (sin fee) frente al de ${antes}. Sin financiamientos antes no hay porcentaje.`,
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => variacion(l.consumoUsd, l.consumoAnteriorUsd)),
      csv: (l) => {
        const v = variacion(l.consumoUsd, l.consumoAnteriorUsd)
        return v === null ? null : csvDinero(v, 1)
      },
      cell: (l) => {
        const cambio = frenteALaAnterior(l)
        if (!cambio) return RAYA
        return (
          <span className="inline-flex flex-col items-end">
            <Tendencia {...comoTendencia(cambio)} />
            <Linea>antes {formatUsd(l.consumoAnteriorUsd)}</Linea>
          </span>
        )
      },
    },

    {
      key: 'consumo-anterior',
      header: 'Financiado anterior (sin fee)',
      hidden: true,
      info: `Sin el service fee: el financiado de ${antes}.`,
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.consumoAnteriorUsd),
      csv: (l) => csvDinero(l.consumoAnteriorUsd),
      cell: (l) => tenue(l, formatUsd(l.consumoAnteriorUsd)),
    },

    {
      key: 'consumos',
      header: 'Financiamientos',
      info: 'Financiamientos confirmados de la clínica esta semana.',
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.consumos),
      csv: (l) => l.consumos,
      cell: (l) => tenue(l, l.consumos),
    },

    {
      key: 'personas',
      header: 'Pacientes',
      info: 'Pacientes distintos con una cuota en los financiamientos de la clínica esta semana. En «Todas», quien fue a dos clínicas cuenta una vez.',
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.personas),
      csv: (l) => l.personas,
      cell: (l) => tenue(l, l.personas),
    },

    {
      key: 'ticket',
      header: 'Ticket medio (sin fee)',
      info: 'Sin el service fee: el financiado entre el número de financiamientos.',
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.ticketMedioUsd),
      csv: (l) => csvDinero(l.ticketMedioUsd),
      cell: (l) => tenue(l, l.ticketMedioUsd === null ? RAYA : formatUsd(l.ticketMedioUsd)),
    },

    {
      key: 'nuevas',
      header: 'Pacientes nuevos en la clínica',
      info: 'Pacientes cuya primera cuota en ESTA clínica es de esta semana, se hubieran financiado antes en otra o no. Quien estrenó dos clínicas cuenta en las dos; en «Todas», una vez (pacientes nuevos en alguna clínica, que no son los que se financiaron por primera vez en Helios).',
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.nuevas),
      csv: (l) => l.nuevas,
      cell: (l) => tenue(l, l.nuevas),
    },

    {
      key: 'recurrentes',
      header: 'Pacientes que repiten en la clínica',
      hidden: true,
      info: 'Pacientes de la semana que ya habían financiado antes en la clínica: los pacientes menos los nuevos en la clínica.',
      type: 'number',
      sortDir: 'desc',
      sort: orden(recurrentes),
      csv: recurrentes,
      cell: (l) => tenue(l, recurrentes(l)),
    },

    {
      key: 'a-tiempo',
      header: 'Cobrado a tiempo (%)',
      info: `Cuotas de financiamientos en esta clínica que vencían esta semana y ya cerraron su plazo (el vencimiento más ${d.graciaDias} días de gracia): las pagadas dentro de él entre todas ellas. Un pago cuenta el día en que se registró. Las que siguen en plazo todavía no cuentan.`,
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.aTiempo.pct),
      csv: (l) => (l.aTiempo.pct === null ? null : csvDinero(l.aTiempo.pct, 1)),
      cell: (l) => {
        const a = l.aTiempo
        if (a.pct === null) {
          return a.vencen > 0 ? (
            <span className="inline-flex flex-col items-end">
              {RAYA}
              <Linea>{a.vencen === 1 ? '1 cuota en plazo' : `${a.vencen} cuotas en plazo`}</Linea>
            </span>
          ) : (
            RAYA
          )
        }
        const tono = tonoCobroATiempo(a.pct, parametros)
        const pct = formatPorcentaje(a.pct, 0)
        return (
          <span className="inline-flex flex-col items-end">
            {/* El número en blanco; el color, solo si cruza el umbral de Ajustes. */}
            {!l.esTotal && (tono === 'warning' || tono === 'error') ? (
              <Badge tone={tono} icono>
                {pct}
              </Badge>
            ) : (
              tenue(l, <span className="font-semibold">{pct}</span>)
            )}
            <Linea>
              {a.aTiempo} de {a.juzgadas}
            </Linea>
          </span>
        )
      },
    },

    {
      key: 'vencido',
      header: 'Vencido (financiamiento + fee)',
      info: `Financiamiento + fee: las cuotas de financiamientos en esta clínica (de cualquier semana) vencidas y sin pagar ${alCierre}. Debajo, cada parte por separado: su financiamiento y el service fee (IVA incluido). Lo dado por perdido no entra.`,
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.vencido.payableUsd),
      csv: (l) => csvDinero(l.vencido.payableUsd),
      cell: (l) => tenue(l, <ImporteConDesglose desglose={l.vencido} />),
    },

    {
      key: 'vencido-consumo',
      header: 'Vencido: financiamiento (sin fee)',
      hidden: true,
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.vencido.financedUsd),
      csv: (l) => csvDinero(l.vencido.financedUsd),
      cell: (l) => tenue(l, formatUsd(l.vencido.financedUsd)),
    },

    {
      key: 'vencido-servicio',
      header: 'Vencido: service fee (IVA incluido)',
      hidden: true,
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.vencido.feeUsd),
      csv: (l) => csvDinero(l.vencido.feeUsd),
      cell: (l) => tenue(l, formatUsd(l.vencido.feeUsd)),
    },

    {
      key: 'cierre',
      header: rotuloDelCierre(d.cierre),
      info: d.cierre.pasado
        ? `Lo que se le generó por las cuotas que vencieron esta semana (cada mitad se paga el día siguiente a su vencimiento, el último el ${diaConNumero(d.cierre.lunes)}), y lo que falte por transferirle. Es lo mismo que dice Pagos a clínicas.`
        : `Lo que se le transferirá por las cuotas que vencen esta semana, se paguen o no, cada mitad el día siguiente a su vencimiento (el último pago, el ${diaConNumero(d.cierre.lunes)}): lo ya generado más lo que se generará hasta el domingo con sus condiciones. Es su neto: no lleva la comisión de servicio. Si tiene algo atrasado de semanas anteriores, va debajo.`,
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.transferencia.generadoUsd + l.transferencia.previstoUsd),
      csv: (l) => csvDinero(l.transferencia.generadoUsd + l.transferencia.previstoUsd),
      cell: (l) => {
        const t = l.transferencia
        const total = t.generadoUsd + t.previstoUsd
        const atrasado = !d.cierre.pasado && t.atrasadoUsd > 0.005 ? `+ ${formatUsd(t.atrasadoUsd)} atrasado` : null
        if (total <= 0 && !atrasado) return RAYA
        const linea = d.cierre.pasado
          ? t.pendienteUsd > 0.005
            ? `faltan ${formatUsd(t.pendienteUsd)}`
            : 'transferido'
          : t.previstoUsd > 0.005
            ? `${formatUsd(t.previstoUsd)} por generar`
            : null
        return (
          <span className="inline-flex flex-col items-end">
            {tenue(l, formatUsd(total))}
            {linea && <Linea>{linea}</Linea>}
            {atrasado && <Linea>{atrasado}</Linea>}
          </span>
        )
      },
    },

    {
      key: 'cierre-atrasado',
      header: 'Atrasado de semanas anteriores',
      hidden: true,
      info: 'Lo de semanas anteriores que sigue sin transferirse. Solo para una semana cuyos pagos no han terminado.',
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.transferencia.atrasadoUsd),
      csv: (l) => csvDinero(l.transferencia.atrasadoUsd),
      cell: (l) => tenue(l, formatUsd(l.transferencia.atrasadoUsd)),
    },

    {
      key: 'parte',
      header: 'Parte del financiado (%)',
      info: 'El financiado (sin fee) de la clínica entre el de todas las clínicas, esta semana. Al pasar el ratón por la barra, los importes.',
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.partePct),
      csv: (l) => (l.partePct === null ? null : csvDinero(l.partePct, 1)),
      cell: (l) =>
        l.partePct === null ? (
          RAYA
        ) : (
          <span className="inline-flex items-center justify-end gap-2.5">
            {/* La barra lleva el globo del kit con los importes; el
                porcentaje va escrito al lado, que el globo nunca es la única
                lectura. */}
            <MarcaConGlobo
              titulo={l.esTotal ? 'Todas las clínicas' : l.nombre}
              filas={[
                {
                  key: 'parte',
                  rotulo: 'del financiado de todas las clínicas',
                  valor: formatPorcentaje(l.partePct, 1),
                  color: l.esTotal ? SERIE.contexto : SERIE.principal,
                  forma: 'punto',
                },
                {
                  key: 'consumo',
                  rotulo: 'financiado, sin fee',
                  valor: formatUsd(l.consumoUsd),
                  color: 'transparent',
                },
                // En la fila de todos sería el mismo importe dos veces.
                ...(l.esTotal
                  ? []
                  : [
                      {
                        key: 'todos',
                        rotulo: 'entre todos, sin fee',
                        valor: formatUsd(d.totales.consumoUsd),
                        color: 'transparent',
                      },
                    ]),
              ]}
              x={Math.min(100, Math.max(l.partePct, 0))}
              className="flex py-2"
            >
              <span className="flex h-1.5 w-16 overflow-hidden rounded-full" style={{ backgroundColor: SERIE.vacio }}>
                <span
                  className="h-full rounded-full"
                  style={{
                    width: `${Math.min(100, Math.max(l.partePct, l.partePct > 0 ? 2 : 0))}%`,
                    backgroundColor: l.esTotal ? SERIE.contexto : SERIE.principal,
                  }}
                />
              </span>
            </MarcaConGlobo>
            {tenue(l, <span className="w-10 text-right">{formatPorcentaje(l.partePct, 0)}</span>)}
          </span>
        ),
    },

    { key: 'ciudad', header: 'Ciudad', hidden: true, csv: (l) => l.ciudad, cell: (l) => l.ciudad ?? '—' },

    {
      key: 'estado',
      header: 'Estado',
      hidden: true,
      sort: orden((l) => (l.estado ? ESTADOS_LOCAL[l.estado].label : null)),
      csv: (l) => (l.estado ? ESTADOS_LOCAL[l.estado].label : null),
      cell: (l) => (l.estado ? ESTADOS_LOCAL[l.estado].label : '—'),
    },

    {
      key: 'noches',
      header: 'Días con financiamientos',
      hidden: true,
      info: 'Días con al menos un financiamiento. El día operativo va de medianoche a medianoche, hora de Caracas.',
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.noches),
      csv: (l) => l.noches,
      cell: (l) => tenue(l, l.noches),
    },

    {
      key: 'mejor-noche',
      header: 'Mejor día (financiado sin fee)',
      hidden: true,
      info: 'Sin el service fee: el día de la semana con más financiado, y su financiado.',
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.mejorNoche?.consumoUsd ?? null),
      csv: (l) => l.mejorNoche?.fecha ?? null,
      cell: (l) =>
        l.mejorNoche
          ? tenue(
              l,
              <>
                {formatUsd(l.mejorNoche.consumoUsd)}
                <Linea>{formatDay(l.mejorNoche.fecha)}</Linea>
              </>,
            )
          : RAYA,
    },

    {
      key: 'mejor-noche-consumo',
      header: 'Financiado del mejor día (sin fee)',
      hidden: true,
      type: 'number',
      sortDir: 'desc',
      sort: orden((l) => l.mejorNoche?.consumoUsd ?? null),
      csv: (l) => csvDinero(l.mejorNoche?.consumoUsd),
      cell: (l) => (l.mejorNoche ? formatUsd(l.mejorNoche.consumoUsd) : '—'),
    },
  ]
}
