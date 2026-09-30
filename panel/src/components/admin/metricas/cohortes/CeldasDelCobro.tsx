import { InfoDot } from '@/components/ui'
import { aunNoVence, cuotaDe, tramosDeCobro } from '@/features/admin/metricas/cohortes/estados'
import { pct } from '@/features/admin/metricas/cohortes/frases'
import { rotuloDeSemana } from '@/features/admin/metricas/cohortes/semanas'
import { NUMEROS_DE_CUOTA } from '@/features/admin/metricas/cohortes/tipos'
import type { Cohorte, CuotaDeCohorte, ParteDeCuota } from '@/features/admin/metricas/cohortes/tipos'
import { BarraDeEstados } from './BarraDeEstados'
import { ImporteDeCuota } from './ImporteDeCuota'

// ═══════════════════════════════════════════════════════════════════════════
// Las columnas de lo que hay que cobrar, las mismas en «Todas las semanas de
// consumo» y en «Por local»: total a cobrar → cobrado → lo que falta (vencido
// y por vencer), cada importe con su desglose debajo (consumo · fee), y cómo
// va cada cuota. El consumo sin fee queda en el desglose del total.
//
// El desglose va en dos líneas bajo la cifra (`celda`): en una sola, cada
// columna medía lo que la frase y la tabla no cabía ni en un monitor ancho.
// ═══════════════════════════════════════════════════════════════════════════

export const CABECERA = 'px-2.5 py-2 type-panel-caption font-semibold text-on-surface-variant'
export const SEPARADOR = 'border-l border-panel-hairline'
const CELDA = 'px-2.5 py-2'

function ConAyuda({ texto, ayuda }: { texto: string; ayuda: string }) {
  return (
    <span className="inline-flex items-center gap-1">
      {texto}
      <InfoDot title={texto} what={ayuda} />
    </span>
  )
}

export function CabecerasDelCobro() {
  return (
    <>
      <th scope="col" className={`${SEPARADOR} ${CABECERA} text-right`}>
        <ConAyuda
          texto="Total a cobrar"
          ayuda="Cuota 1 + cuota 2 de esos financiamientos, con su desglose debajo: financiado (sin fee) y service fee + IVA."
        />
      </th>
      <th scope="col" className={`${CABECERA} text-left`}>
        <ConAyuda
          texto="Cobrado (%)"
          ayuda="Cobrado (a tiempo o con atraso) ÷ total a cobrar, en dólares con fee; la barra reparte el total por estado."
        />
      </th>
      <th scope="col" className={`${CABECERA} text-right`}>
        Cobrado
      </th>
      <th scope="col" className={`${CABECERA} text-right`}>
        <ConAyuda
          texto="Vencido"
          ayuda="Cuotas sin pagar con el vencimiento ya pasado (también dentro de la gracia), sin lo perdido, en dólares con fee."
        />
      </th>
      <th scope="col" className={`${CABECERA} text-right`}>
        Por vencer
      </th>
      <th scope="col" className={`${SEPARADOR} ${CABECERA} text-left`}>
        <ConAyuda
          texto="Cobrado por cuota (%)"
          ayuda="Cobrado de la cuota 1 y de la cuota 2 ÷ total de cada una, en dólares con fee; cada barra reparte su cuota por estado."
        />
      </th>
    </>
  )
}

/** Un importe de lo que se cobra en una celda, o una raya si es cero. */
function CeldaDeImporte({ parte, clase }: { parte: ParteDeCuota; clase?: string }) {
  return (
    <td className={`${CELDA} text-right`}>
      {parte.importe.payableUsd > 0 ? (
        <ImporteDeCuota
          importe={parte.importe}
          variante="celda"
          claseCifra={clase ?? 'type-panel-body text-on-surface-variant'}
        />
      ) : (
        <span className="type-panel-body text-panel-muted">—</span>
      )}
    </td>
  )
}

/** Las celdas de una semana (o de un local en una semana). `quien` va al título de los globos. */
export function CeldasDelCobro({ cohorte, hoy, quien }: { cohorte: Cohorte; hoy: string; quien?: string }) {
  const a = cohorte.aCobrar
  const de = quien ?? `Semana ${rotuloDeSemana(cohorte.semana)}`
  return (
    <>
      <td className={`${SEPARADOR} ${CELDA} text-right`}>
        <ImporteDeCuota importe={a.importe} variante="celda" claseCifra="type-panel-body font-semibold text-on-surface" />
      </td>
      <td className={CELDA}>
        <span className="flex items-center gap-2.5">
          <BarraDeEstados
            tramos={tramosDeCobro(a)}
            rotulo={`${de}: lo que hay que cobrar, por estado`}
            titulo={`${de} · total a cobrar`}
            total={a.importe}
            alto="media"
            className="w-20 shrink-0"
          />
          <span className="whitespace-nowrap type-panel-body font-bold text-on-surface">
            {a.cobradoPct === null ? '—' : pct(a.cobradoPct)}
          </span>
        </span>
      </td>
      <CeldaDeImporte parte={a.cobrado} />
      <CeldaDeImporte parte={a.estados.vencida} clase="type-panel-body font-semibold text-warning" />
      <CeldaDeImporte parte={a.estados.por_vencer} />
      <td className={`${SEPARADOR} ${CELDA}`}>
        <span className="flex flex-col gap-1.5">
          {NUMEROS_DE_CUOTA.map((n) => (
            <FilaDeCuota key={n} n={n} cuota={cuotaDe(cohorte, n)} hoy={hoy} de={de} />
          ))}
        </span>
      </td>
    </>
  )
}

/** Cómo va una cuota, en una línea: su número, su barra por estado y qué parte se cobró. */
function FilaDeCuota({ n, cuota, hoy, de }: { n: number; cuota: CuotaDeCohorte | null; hoy: string; de: string }) {
  return (
    <span className="flex items-center gap-2">
      <span className="w-3 type-panel-caption text-panel-muted">{n}</span>
      {cuota ? (
        <>
          <BarraDeEstados
            tramos={tramosDeCobro(cuota)}
            rotulo={`${de}: cuota ${n} por estado`}
            titulo={`${de} · cuota ${n}`}
            total={cuota.importe}
            alto="fina"
            className="w-14 shrink-0"
          />
          <span className="whitespace-nowrap type-panel-caption font-semibold text-on-surface">
            {aunNoVence(cuota, hoy) && (cuota.cobradoPct ?? 0) === 0 ? (
              <span className="font-normal text-panel-muted">aún no vence</span>
            ) : cuota.cobradoPct === null ? (
              '—'
            ) : (
              pct(cuota.cobradoPct)
            )}
          </span>
        </>
      ) : (
        <span className="type-panel-caption text-panel-muted">—</span>
      )}
    </span>
  )
}
