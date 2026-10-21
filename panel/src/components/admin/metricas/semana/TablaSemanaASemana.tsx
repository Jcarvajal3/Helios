import { Download } from 'lucide-react'

import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { SeccionMetricas } from '@/components/admin/metricas/kit'
import { Button, EmptyState, InfoDot, Segmented, SkeletonTable } from '@/components/ui'
import type { EstadoCifra } from '@/components/ui'
import type { BusquedaComun } from '@/features/admin/metricas/busqueda'
import { COLUMNAS_DE_SEMANAS } from '@/features/admin/metricas/semana/busqueda'
import type { ColumnasDeSemanas } from '@/features/admin/metricas/semana/busqueda'
import { csvDeSemanas, nombreDelCsv } from '@/features/admin/metricas/semana/csv'
import { etiquetaDeSemana, tramoHastaElCorte } from '@/features/admin/metricas/semana/etiquetas'
import { GRUPOS_DE_FILAS, sinMovimiento } from '@/features/admin/metricas/semana/filas'
import type { RespuestaSemanas } from '@/features/admin/metricas/semana/tipos'
import { descargarCsv } from '@/lib/csv'
import { CLASE_ELEGIDA, FilaDeLaTabla } from './FilaDeLaTabla'

const INFO =
  'Una columna por semana, de lunes a domingo por día operativo, con la elegida a la derecha. El total financiado va sin la Comisión Helios; el importe de las cuotas va con sus dos partes debajo: el financiado (sin comisión) y la Comisión Helios + IVA. «Frente a la anterior» compara la elegida con la semana de antes: entera si la elegida está cerrada; si está en curso, hasta el mismo momento (hace siete días), con lo vencido, la mora y la caja al cierre del mismo día de la semana y el cobro a tiempo con los mismos días de vencimiento. Señala el nombre de una fila para ver qué es.'

/**
 * «Semana a semana»: la tabla de la pestaña. Una fila por cifra, agrupadas
 * como en la maqueta, y una columna por semana (8, 12 o 26, a elegir), con la
 * semana elegida resaltada al final y su cambio frente a la anterior.
 *
 * Se lee de lado: con 12 o 26 semanas la tabla se arrastra y la columna de
 * los nombres se queda quieta.
 */
export function TablaSemanaASemana({
  respuesta,
  estado,
  error,
  onReintentar,
  columnas,
  onColumnas,
  comun,
  local,
  actualizando,
}: {
  respuesta: RespuestaSemanas | undefined
  estado: EstadoCifra
  error: unknown
  onReintentar: () => void
  columnas: ColumnasDeSemanas
  onColumnas: (c: ColumnasDeSemanas) => void
  comun: BusquedaComun
  local: string | null
  /** Hay una respuesta nueva en camino: lo de la vista es la anterior. */
  actualizando: boolean
}) {
  const listo = estado === 'listo' && respuesta !== undefined

  return (
    <SeccionMetricas
      titulo="Semana a semana"
      ayuda="Pulsa una fila para ver su detalle"
      info={INFO}
      acciones={
        <>
          <span className="inline-flex items-center gap-2">
            <span className="type-panel-caption font-semibold text-panel-muted">Ver</span>
            <Segmented
              etiqueta="Semanas en la tabla"
              options={COLUMNAS_DE_SEMANAS.map((c) => ({ value: c, label: c === '8' ? '8 semanas' : c }))}
              value={columnas}
              onChange={onColumnas}
            />
          </span>
          <Button
            size="sm"
            variant="outlined"
            disabled={!listo}
            title={listo ? undefined : 'Espera a que lleguen las cifras'}
            onClick={() => respuesta && descargarCsv(nombreDelCsv(respuesta), csvDeSemanas(respuesta, local))}
          >
            <Download size={14} aria-hidden /> Descargar CSV
          </Button>
        </>
      }
    >
      {estado === 'cargando' && <SkeletonTable rows={10} columns={Number(columnas) > 8 ? 10 : Number(columnas) + 2} />}

      {estado === 'error' && (
        <ErrorConReintento title="No se pudo leer la semana a semana" error={error} onReintentar={onReintentar} />
      )}

      {listo &&
        (sinMovimiento(respuesta) ? (
          <EmptyState
            title={`Sin movimiento en estas ${respuesta.semanas.length} semanas`}
            description="Ni financiamientos, ni cuotas, ni registros, ni pagos a clínicas. Elige otra semana arriba o quita la clínica."
          />
        ) : (
          <Tabla respuesta={respuesta} comun={comun} local={local} actualizando={actualizando} />
        ))}
    </SeccionMetricas>
  )
}

function Tabla({
  respuesta,
  comun,
  local,
  actualizando,
}: {
  respuesta: RespuestaSemanas
  comun: BusquedaComun
  local: string | null
  actualizando: boolean
}) {
  const { semanas, comparacion } = respuesta
  const columnasDeDatos = semanas.length + 1

  return (
    <div
      aria-busy={actualizando || undefined}
      className={`-mx-1 overflow-x-auto overscroll-x-contain transition-opacity duration-[var(--transition-fast)] ${
        actualizando ? 'opacity-60' : ''
      }`}
    >
      <table className="w-full min-w-max border-collapse tabular-nums">
        <caption className="sr-only">
          Cifras de las últimas {semanas.length} semanas; la última columna de semanas es la elegida.
        </caption>
        <thead>
          <tr className="border-b border-panel-hairline-strong">
            <th
              scope="col"
              className="sticky left-0 z-10 min-w-56 bg-panel-card pr-4 pb-2 text-left align-bottom type-panel-caption font-semibold text-panel-muted"
            >
              Cifra
            </th>
            {semanas.map((s, i) => {
              const elegida = i === semanas.length - 1
              return (
                <th
                  key={s.desde}
                  scope="col"
                  className={`px-3 pt-1.5 pb-2 text-right align-bottom type-panel-caption whitespace-nowrap ${
                    elegida
                      ? `${CLASE_ELEGIDA} rounded-t-panel-control font-bold text-on-surface`
                      : 'font-semibold text-panel-muted'
                  }`}
                >
                  {etiquetaDeSemana(s.desde, s.hasta)}
                  {s.enCurso && <span className="block font-semibold text-panel-muted">en curso</span>}
                </th>
              )
            })}
            <th
              scope="col"
              className="pr-1 pb-2 pl-3 text-right align-bottom type-panel-caption font-semibold whitespace-nowrap text-panel-muted"
            >
              Frente a la anterior
              {comparacion.mismaAltura && (
                <span className="flex items-center justify-end gap-1">
                  a la misma altura
                  <InfoDot
                    title="A la misma altura"
                    what={`La semana elegida va a medias: se compara con la anterior hasta el mismo momento, ${tramoHastaElCorte(comparacion.desde, comparacion.hasta, comparacion.corte)}. Lo vencido, la mora y la caja, al cierre de ese día.`}
                  />
                </span>
              )}
            </th>
          </tr>
        </thead>

        {GRUPOS_DE_FILAS.map((grupo) => (
          <tbody key={grupo.id}>
            <tr>
              <th
                scope="rowgroup"
                colSpan={columnasDeDatos + 1}
                className="pt-4 pb-1.5 text-left"
              >
                <span className="sticky left-0 inline-flex items-center gap-2">
                  <span data-area={grupo.tono} aria-hidden className="size-1.5 rounded-full bg-area" />
                  {/* En mayúsculas pequeñas, como en la maqueta: separa los
                      bloques de filas igual que las cabeceras del menú separan
                      los suyos. */}
                  <span className="type-panel-overline text-panel-muted">{grupo.titulo}</span>
                </span>
              </th>
            </tr>
            {grupo.filas.map((fila) => (
              <FilaDeLaTabla
                key={fila.id}
                fila={fila}
                semanas={semanas}
                anterior={comparacion.cifras}
                comun={comun}
                local={local}
              />
            ))}
          </tbody>
        ))}
      </table>
    </div>
  )
}
