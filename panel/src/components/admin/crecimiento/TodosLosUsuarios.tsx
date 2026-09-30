import { Card, InfoDot, formatPorcentaje } from '@/components/ui'
import { Ring } from '@/components/charts'
import { NoSeParte } from '@/components/admin/metricas/kit'
import { CifrasEnFila } from '@/components/admin/tableros/CifrasEnFila'
import type { GrowthOverview } from '@/features/admin/growth'
import { MOTIVO_PADRON } from '@/features/admin/metricas/gente/textos'

const TITULO = 'Totales desde el inicio'

/**
 * El padrón entero, desde el primer día: cuántos pidieron el código, cuántos
 * se registraron (verificados), cuántos están listos para consumir (ya
 * crearon su PIN, hayan consumido o no) y cuántos han
 * consumido alguna vez, con la proporción de los registros que compraron en
 * un anillo. No sigue a la ventana, y lo dice su explicación, no un párrafo.
 *
 * Con un local, el padrón no se parte: queda cuánta gente ha consumido alguna
 * vez en él, y el resto lo dice `NoSeParte`.
 */
export function TodosLosUsuarios({
  totales,
  conLocal,
}: {
  totales: GrowthOverview['totals']
  conLocal: boolean
}) {
  if (conLocal || totales.registered === null) {
    return (
      <Card as="section" className="flex flex-col gap-4">
        <div className="flex items-center gap-1.5">
          <h3 className="type-panel-section text-on-surface">Pacientes de la clínica desde el inicio</h3>
          <InfoDot
            title="Pacientes de la clínica desde el inicio"
            what="Desde el primer día y sin seguir a la ventana: cuántos pacientes tienen alguna cuota en un financiamiento de esta clínica."
          />
        </div>
        <CifrasEnFila
          cifras={[{ rotulo: 'Pacientes que se han financiado en la clínica', valor: String(totales.everBought) }]}
        />
        <NoSeParte variante="bloque" motivo={MOTIVO_PADRON} />
      </Card>
    )
  }

  const pct = totales.buyersPct ?? 0

  return (
    <Card as="section" className="flex flex-wrap items-center gap-x-8 gap-y-4">
      <Ring
        tamano="lg"
        valor={totales.buyersPct === null ? null : pct / 100}
        centro={formatPorcentaje(pct)}
        rotulo={`Pacientes que se han financiado alguna vez: ${formatPorcentaje(pct)} de los registros`}
      />
      <div className="flex min-w-0 flex-1 basis-80 flex-col gap-4">
        <div className="flex items-center gap-1.5">
          <h3 className="type-panel-section text-on-surface">{TITULO}</h3>
          <InfoDot
            title={TITULO}
            what="El total desde el primer día: estas cifras no siguen a la ventana de arriba. Un registro es un paciente que una clínica dio de alta. El anillo es la parte de los registros que se ha financiado alguna vez."
          />
        </div>
        <CifrasEnFila
          cifras={[
            { rotulo: 'Registros', valor: String(totales.registered) },
            {
              rotulo: 'Pacientes que se han financiado alguna vez',
              valor: String(totales.everBought),
              pie: `El ${formatPorcentaje(pct)} de los registros`,
            },
          ]}
        />
      </div>
    </Card>
  )
}
