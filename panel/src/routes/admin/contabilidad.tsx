import { createFileRoute, useNavigate } from '@tanstack/react-router'

import { ExportacionContable } from '@/components/admin/ExportacionContable'
import { Libro } from '@/components/admin/Libro'
import type { FiltrosLibro } from '@/components/admin/Libro'
import { DevengadoDelMes } from '@/components/admin/caja/DevengadoDelMes'
import { ListaDelCierre } from '@/components/admin/caja/ListaDelCierre'
import { SaludConciliacion } from '@/components/admin/caja/SaludConciliacion'
import { SelectorDeMes } from '@/components/admin/tableros/SelectorDeMes'
import { Tabs, diaOperativo } from '@/components/ui'
import { comoMes, mesAnteriorA, mesDe, nombreDelMes } from '@/features/admin/cierreMes'
import { VALORES_TIPO_DE_ASIENTO } from '@/features/admin/contabilidad'
import { comoDia, comoId, unoDe } from '@/lib/busqueda'

type Vista = 'cierre' | 'libro' | 'exportacion'

const VISTAS: Array<{ value: Vista; label: string }> = [
  { value: 'cierre', label: 'Cierre de mes' },
  { value: 'libro', label: 'Libro de asientos' },
  { value: 'exportacion', label: 'Exportación contable' },
]

/**
 * La vista, el mes (del cierre y de la exportación; por defecto, el anterior)
 * y los filtros del libro, todo en la URL.
 */
type ContabilidadSearch = FiltrosLibro & { vista?: Vista; mes?: string }

export const Route = createFileRoute('/admin/contabilidad')({
  staticData: { title: 'Libro y cierre de mes', width: 'wide' },
  component: ContabilidadPage,
  validateSearch: (search: Record<string, unknown>): ContabilidadSearch => ({
    vista: VISTAS.find((v) => v.value === search.vista)?.value,
    mes: comoMes(search.mes),
    tipo: unoDe(VALORES_TIPO_DE_ASIENTO, search.tipo),
    desde: comoDia(search.desde),
    hasta: comoDia(search.hasta),
    persona: comoId(search.persona),
    local: comoId(search.local),
  }),
})

/**
 * Libro y cierre de mes: lo que se cuadra a final de mes y se le manda al
 * contador. El cierre es una lista de comprobación del mes, con lo devengado
 * y la salud de la conciliación debajo. El mes se elige con las flechas de
 * arriba a la derecha, igual en el cierre y en la exportación.
 */
function ContabilidadPage() {
  const navigate = useNavigate({ from: '/admin/contabilidad' })
  const search = Route.useSearch()
  const vista = search.vista ?? 'cierre'

  const hoy = diaOperativo(new Date())
  const mesActual = mesDe(hoy)
  // Por defecto se cierra el mes anterior; uno futuro no se puede cerrar.
  const mes = search.mes && search.mes <= mesActual ? search.mes : mesAnteriorA(mesActual)

  function cambiar(patch: Partial<ContabilidadSearch>, reemplazar = false) {
    void navigate({ search: (prev) => ({ ...prev, ...patch }), replace: reemplazar })
  }

  return (
    <>
      <Tabs
        options={VISTAS}
        value={vista}
        onChange={(v) => cambiar({ vista: v === 'cierre' ? undefined : v })}
      />

      {vista === 'cierre' && (
        <div className="flex flex-col gap-10">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <p className="type-panel-caption text-panel-muted">
              El cierre de {nombreDelMes(mes)}, por día operativo.
            </p>
            <SelectorDeMes mes={mes} maximo={mesActual} onMes={(m) => cambiar({ mes: m }, true)} />
          </div>
          <ListaDelCierre mes={mes} hoy={hoy} />
          <DevengadoDelMes mes={mes} />
          <SaludConciliacion mes={mes} hoy={hoy} />
        </div>
      )}

      {vista === 'libro' && (
        <Libro
          filtros={{
            tipo: search.tipo,
            desde: search.desde,
            hasta: search.hasta,
            persona: search.persona,
            local: search.local,
          }}
          onCambiar={(patch) => cambiar(patch)}
        />
      )}

      {vista === 'exportacion' && (
        <ExportacionContable
          mes={mes}
          maximo={mesActual}
          onMes={(m) => cambiar({ mes: m }, true)}
        />
      )}
    </>
  )
}
