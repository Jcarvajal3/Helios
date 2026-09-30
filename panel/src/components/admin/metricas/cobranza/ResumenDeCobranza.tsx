import { Link } from '@tanstack/react-router'
import { ArrowRight } from 'lucide-react'

import { SeccionMetricas } from '@/components/admin/metricas/kit'
import { corteDeLaSemana } from '@/features/admin/metricas/cobranza/semana'
import { CifrasDeLaSemana } from './CifrasDeLaSemana'
import { MoraPorTramoAlCorte } from './MoraPorTramoAlCorte'
import { ParaActuar } from './ParaActuar'
import { PasoDeLaSemana } from './PasoDeLaSemana'
import { VenciaYEntroPorDia } from './VenciaYEntroPorDia'

const CLASE_ENLACE =
  'group flex items-center justify-between gap-3 rounded-panel-control px-3 py-2.5 transition-colors duration-[var(--transition-fast)] hover:bg-panel-raised'

/**
 * El resumen de Cobranza y riesgo, como la maqueta: las seis cifras (con la
 * cuota 1 y la 2 sin pagar tras la gracia, cada una en su tarjeta); lo que
 * vencía y entró cada día junto a la mora por tramo; el paso entre tramos; y
 * los enlaces para actuar.
 *
 * La recuperación de lo vencido y el cupo ocupado por nivel no se repiten
 * aquí: son las sub-pestañas Rendimiento y Cupos de Riesgo, y este resumen
 * enlaza a ellas con la misma semana y el mismo local.
 *
 * Cada bloque pide su lectura y carga o falla por su cuenta. Los que miran la
 * misma lectura (las cifras y la mora por tramo) comparten la llamada.
 */
export function ResumenDeCobranza({
  semana,
  domingo,
  enCurso,
  hoy,
  local,
  nombreLocal,
  enlace,
}: {
  semana: string
  domingo: string
  enCurso: boolean
  hoy: string
  local: string | null
  nombreLocal: string | null
  /** La semana y el local de ahora, tal como van en la URL: para enlazar otra sub-vista. */
  enlace: { semana?: string; local?: string }
}) {
  const corte = corteDeLaSemana(domingo, hoy)

  return (
    <div className="flex flex-col gap-4">
      <CifrasDeLaSemana
        semana={semana}
        domingo={domingo}
        local={local}
        enlaceAPrimeraCuota={enlace}
      />

      <div className="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,1.7fr)_minmax(0,1fr)]">
        <VenciaYEntroPorDia domingo={domingo} enCurso={enCurso} hoy={hoy} local={local} />
        <MoraPorTramoAlCorte semana={semana} local={local} />
      </div>

      <div className="grid grid-cols-1 gap-4 xl:grid-cols-2">
        <PasoDeLaSemana corte={corte} local={local} />
        <SeccionMetricas titulo="Más en Riesgo">
          <ul className="-mx-3 -mt-2 flex flex-col">
            <li>
              <Link to="/admin/metricas" search={{ vista: 'mora', sub: 'rendimiento', ...enlace }} className={CLASE_ENLACE}>
                <span className="flex flex-col">
                  <span className="type-panel-label text-on-surface">Recuperación de lo vencido</span>
                  <span className="type-panel-caption text-panel-muted">
                    Cobrado de cuotas vencidas, gestiones, promesas y cargos por atraso: Riesgo › Rendimiento
                  </span>
                </span>
                <ArrowRight size={16} aria-hidden className="shrink-0 text-on-surface-variant" />
              </Link>
            </li>
            <li>
              <Link to="/admin/metricas" search={{ vista: 'mora', sub: 'cupos', ...enlace }} className={CLASE_ENLACE}>
                <span className="flex flex-col">
                  <span className="type-panel-label text-on-surface">
                    Cupo ocupado por nivel{nombreLocal ? ` · ${nombreLocal}` : ''}
                  </span>
                  <span className="type-panel-caption text-panel-muted">Lo ocupado sobre el cupo de cada nivel, hoy: Riesgo › Cupos</span>
                </span>
                <ArrowRight size={16} aria-hidden className="shrink-0 text-on-surface-variant" />
              </Link>
            </li>
          </ul>
        </SeccionMetricas>
      </div>

      <ParaActuar local={local} />
    </div>
  )
}
