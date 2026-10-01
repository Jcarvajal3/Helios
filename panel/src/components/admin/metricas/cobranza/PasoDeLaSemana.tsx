import { useQuery } from '@tanstack/react-query'

import { MatrizDeFlujo } from '@/components/admin/riesgo/FlujoEntreTramos'
import { consultaFlujo } from '@/features/admin/metricas/cobranza/api'
import { pasoDeLaSemana, periodoDelPaso } from '@/features/admin/metricas/cobranza/semana'
import { Bloque, FilaDeCifra } from './piezas'

/**
 * El paso entre tramos de la semana elegida: del lunes a medianoche a su cierre
 * (o a ahora, si está en curso), cuántos pacientes se pusieron al día, mejoró, empeoró
 * o entró en mora. La mora por tramo es la foto; esto es el movimiento. La
 * matriz entera va plegada debajo.
 */
export function PasoDeLaSemana({ corte, local }: { corte: string; local: string | null }) {
  const flujo = useQuery(consultaFlujo(corte, local, 1))

  return (
    <Bloque
      titulo="Cambio de tramo de atraso (pacientes)"
      info="Pacientes con cuotas, según cómo cambió el tramo de su cuota vencida más atrasada entre el inicio del lunes de la semana y su cierre, o ahora si está en curso; cada paciente cuenta en una sola línea."
      consulta={flujo}
      filas={4}
    >
      {(f) => {
        const semana = f.semanas.at(-1)
        if (!semana) {
          return <p className="type-panel-body text-on-surface-variant">Todavía no hay con qué comparar.</p>
        }
        const p = pasoDeLaSemana(semana)
        return (
          <div className="flex flex-col gap-3">
            <p className="-mt-2 type-panel-body text-on-surface-variant">{periodoDelPaso(semana)}.</p>
            <ul className="flex flex-col">
              <FilaDeCifra rotulo="Se pusieron al día" valor={p.seAlDia} tono={p.seAlDia > 0 ? 'bueno' : 'normal'} />
              <FilaDeCifra
                rotulo="Pasaron a un tramo de menos atraso"
                valor={p.mejoraron}
                tono={p.mejoraron > 0 ? 'bueno' : 'normal'}
              />
              <FilaDeCifra
                rotulo="Pasaron a un tramo de más atraso"
                valor={p.empeoraron}
                tono={p.empeoraron > 0 ? 'malo' : 'normal'}
              />
              <FilaDeCifra
                rotulo="Pasaron de al día a vencido"
                valor={p.entraron}
                tono={p.entraron > 0 ? 'alerta' : 'normal'}
              />
            </ul>
            <details className="group">
              <summary className="inline-flex cursor-pointer items-center gap-1.5 rounded-panel-control py-1 type-panel-caption font-semibold text-on-surface-variant transition-colors duration-[var(--transition-fast)] hover:text-on-surface">
                Ver de qué tramo a qué tramo
              </summary>
              <div className="mt-2">
                <MatrizDeFlujo flujo={f} semana={semana} />
              </div>
            </details>
          </div>
        )
      }}
    </Bloque>
  )
}
