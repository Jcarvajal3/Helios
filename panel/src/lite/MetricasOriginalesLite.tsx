import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'

import { CabeceraLite } from './kit'

/**
 * Una vista de las Métricas de Pro abierta desde «Más vistas del admin
 * original» de Resultados: la cabecera de Lite, la vuelta a «Cobranza y
 * caja» y, debajo, la pantalla de Pro tal cual.
 */
export function MetricasOriginalesLite({ children }: { children: ReactNode }) {
  return (
    <>
      <CabeceraLite
        titulo="Resultados"
        descripcion="Las métricas completas del admin original."
        derecha={
          <Link to="/admin/metricas" className="lt-boton-suave">
            ← Cobranza y caja
          </Link>
        }
      />
      {children}
    </>
  )
}
