import { useMemo } from 'react'
import { useNavigate } from '@tanstack/react-router'

import { DataTable } from '@/components/DataTable'
import { SeccionMetricas } from '@/components/admin/metricas/kit'
import { busquedaConLocal } from '@/features/admin/metricas/locales/consultas'
import { conVentas } from '@/features/admin/metricas/locales/rendimiento'
import type { LocalesDeLaSemana } from '@/features/admin/metricas/locales/tipos'
import type { Parametros } from '@/features/admin/parametros'

import { columnasDeLocales } from './columnasDeLocales'
import type { FilaDeTabla } from './columnasDeLocales'

/**
 * «Los locales en la semana»: una fila por local y, abajo, todos juntos.
 *
 * Pulsar un local lo pone en el selector de arriba: todas las pestañas de
 * Métricas pasan a mirarlo solo a él, y esta enseña su ficha. La fila de
 * todos no se pulsa ni se mueve al ordenar (sus celdas no tienen orden).
 */
export function TablaDeLocales({ d, parametros }: { d: LocalesDeLaSemana; parametros: Parametros | undefined }) {
  const navigate = useNavigate()
  const columnas = useMemo(() => columnasDeLocales({ d, parametros }), [d, parametros])
  const filas = useMemo<FilaDeTabla[]>(
    () => [...d.locales.map((l) => ({ ...l, esTotal: false })), { ...d.totales, esTotal: true }],
    [d],
  )
  const vendieron = conVentas(d.locales).length

  return (
    <SeccionMetricas
      titulo="Clínicas en la semana"
      ayuda="Pulsa una clínica para ver todas las pestañas solo con él"
      info="Una fila por clínica: los activos y todos los que tuvieron algo esta semana (financiamientos, cuotas que vencían, algo vencido o un cierre), aunque ya no estén activos. Vender cero también es un dato. El financiado y el ticket van sin el service fee; lo vencido lo lleva dentro, con sus dos partes debajo."
    >
      <DataTable
        rows={filas}
        rowKey={(l) => l.merchantId ?? 'todos'}
        columns={columnas}
        noun={['clínica', 'clínicas']}
        total={d.locales.length}
        summary={`${vendieron} con financiamiento`}
        exportar={{ archivo: `locales-${d.semana.desde}` }}
        onRowClick={(l) => {
          if (l.esTotal || l.merchantId === null) return
          void navigate({
            to: '/admin/metricas',
            search: busquedaConLocal({ semana: d.semana.desde, enCurso: d.semana.enCurso, local: l.merchantId }),
          })
        }}
      />
    </SeccionMetricas>
  )
}
