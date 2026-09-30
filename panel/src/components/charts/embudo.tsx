import { TriangleAlert } from 'lucide-react'

import { Badge } from '@/components/ui'
import { parteDelTotal } from '@/components/charts/comun'
import { mayorCaida } from '@/components/charts/geometria'
import { GloboFlotante, lecturaDelPunto, useRecorridoDeMarcas } from '@/components/charts/lectura'
import type { ContenidoDelGlobo, FilaDelGlobo } from '@/components/charts/lectura'
import { SERIE, rampaOrdinal } from '@/components/charts/tonos'

export type FunnelStep = {
  key: string
  label: string
  value: number
  /** Una línea de contexto debajo del rótulo. */
  note?: string
}

/**
 * CUÁNTA GENTE SOBREVIVE A CADA PASO.
 *
 * No es un `ShareBars` con otro nombre. Aquel mide partes de un montón que
 * suman el total; esto mide subconjuntos encajados, donde cada escalón está
 * DENTRO del anterior. Las barras se encogen con el valor, contra el primer
 * escalón, y se oscurecen escalón a escalón (rampa ordinal del área).
 *
 * La pregunta de un embudo —«¿dónde se me cae la gente?»— la contesta una
 * pastilla entre los dos escalones de la mayor caída, contada en personas:
 * pintar de aviso cada escalón haría que ninguno destacara.
 *
 * Cada escalón se lee también en su globo (cuántos, qué parte del primero y
 * cuántos se cayeron del anterior), al pasar el ratón o recorriendo los
 * escalones con las flechas: el embudo es una parada de Tab.
 */
export function FunnelSteps({
  steps,
  unit = 'personas',
  className = '',
}: {
  steps: Array<FunnelStep>
  /** Cómo se llama lo que se cuenta: «se caen 12 personas». */
  unit?: string
  className?: string
}) {
  const techo = steps.length > 0 ? steps[0].value : 0
  const tonos = rampaOrdinal(steps.length)
  const peor = mayorCaida(steps.map((s) => s.value))
  const recorrido = useRecorridoDeMarcas(steps.length)

  const globo = (i: number): ContenidoDelGlobo => {
    const paso = steps[i]
    const filas: FilaDelGlobo[] = [
      { key: 'valor', rotulo: unit, valor: String(paso.value), color: tonos[i] ?? SERIE.principal, forma: 'punto' },
      // Sin muestra: no son otra serie, son la misma cifra leída de otra manera.
      { key: 'parte', rotulo: 'del primer escalón', valor: parteDelTotal(paso.value, techo), color: 'transparent' },
    ]
    if (i > 0) {
      const caen = steps[i - 1].value - paso.value
      filas.push({ key: 'caen', rotulo: `se caen desde «${steps[i - 1].label}»`, valor: String(caen), color: 'transparent' })
    }
    return { titulo: paso.label, filas, nota: paso.note }
  }
  const activo = recorrido.senalada === null ? null : globo(recorrido.senalada)

  return (
    <>
      <ol
        {...recorrido.caja}
        aria-label="Embudo: las flechas recorren los escalones."
        className={`flex flex-col gap-2.5 rounded-panel-control ${className}`}
      >
        {steps.map((paso, i) => {
          const parte = techo > 0 ? (paso.value / techo) * 100 : 0
          const anterior = i > 0 ? steps[i - 1].value : 0
          const caen = anterior - paso.value

          return (
            <li key={paso.key}>
              {i === peor && (
                // Va en la columna de las barras, entre los dos escalones que
                // compara: pertenece al hueco y no a ninguno de los dos.
                <div className="mb-2.5 flex items-center gap-3">
                  <div className="w-40 shrink-0" />
                  <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
                    <Badge tone="warning">
                      <span className="inline-flex items-center gap-1">
                        <TriangleAlert size={12} aria-hidden />
                        {`−${Math.round((caen / anterior) * 100)} % · la mayor caída`}
                      </span>
                    </Badge>
                    {/* «se caen» y no «se quedan»: «se quedan 24» se lee como
                        que 24 SIGUEN, justo al revés de lo que cuenta. */}
                    <span className="type-panel-caption text-panel-muted">
                      se caen {caen} {unit}
                    </span>
                  </div>
                </div>
              )}

              {/* El escalón que se señala: la fila, no la pastilla de encima. */}
              <div
                {...recorrido.marca(i)}
                className="flex items-center gap-3 transition-opacity duration-[var(--transition-fast)]"
                style={{ opacity: recorrido.senalada === null || recorrido.senalada === i ? 1 : 0.6 }}
              >
                <div className="w-40 shrink-0">
                  <p className="type-panel-body text-on-surface-variant">{paso.label}</p>
                  {paso.note && <p className="type-panel-caption text-panel-muted">{paso.note}</p>}
                </div>
                <div
                  aria-hidden
                  className="h-2 min-w-0 flex-1 overflow-hidden rounded-full"
                  style={{ backgroundColor: SERIE.vacio }}
                >
                  <div
                    className="h-full rounded-full"
                    // Una parte diminuta que no es cero tiene que verse.
                    style={{
                      width: `${paso.value > 0 ? Math.max(parte, 1) : 0}%`,
                      backgroundColor: tonos[i],
                    }}
                  />
                </div>
                <span className="w-10 shrink-0 text-right type-panel-label tabular-nums text-on-surface">
                  {paso.value}
                </span>
                <span className="w-11 shrink-0 text-right type-panel-caption tabular-nums text-panel-muted">
                  {techo > 0 ? `${parte.toFixed(0)} %` : '—'}
                </span>
              </div>
            </li>
          )
        })}
      </ol>

      {activo && <GloboFlotante ancla={recorrido.ancla} {...activo} />}
      <p aria-live="polite" className="sr-only">
        {activo ? lecturaDelPunto(activo.titulo, activo.filas, activo.nota) : ''}
      </p>
    </>
  )
}
