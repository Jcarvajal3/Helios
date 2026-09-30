import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import type { RegisteredRouter, ValidateLinkOptions } from '@tanstack/react-router'

import { parteDelTotal } from '@/components/charts/comun'
import { GloboFlotante, lecturaDelPunto, useRecorridoDeMarcas } from '@/components/charts/lectura'
import type { ContenidoDelGlobo } from '@/components/charts/lectura'
import { SERIE, colorDeTono } from '@/components/charts/tonos'

export type ShareRow = {
  key: string
  label: string
  value: number
  /** `primary` es el tono del área (ya no el lima); `neutral`, gris. El de
   *  estado, solo si esa parte ESTÁ en alerta. */
  tone: 'primary' | 'warning' | 'error' | 'success' | 'neutral'
  /** Una línea de contexto debajo del rótulo. */
  note?: string
}

export type ShareBarsProps<
  TRouter extends RegisteredRouter = RegisteredRouter,
  TLinks extends ReadonlyArray<unknown> = ReadonlyArray<unknown>,
> = {
  /**
   * Las partes del montón. Cada una puede llevar `link`: la lista que esa
   * parte resume, ya filtrada. Tipado contra las rutas como el de `Stat`,
   * fila a fila: `{ to: '/admin/cobranza', search: { tramo: 't2' } }`.
   */
  rows: { [K in keyof TLinks]: ShareRow & { link?: ValidateLinkOptions<TRouter, TLinks[K]> } }
  format: (value: number) => string
  className?: string
}

function colorDeFila(tone: ShareRow['tone']): string {
  if (tone === 'primary') return SERIE.principal
  if (tone === 'neutral') return SERIE.contexto
  return colorDeTono(tone)
}

/**
 * CUÁNTO DE ESTE MONTÓN ES CADA COSA.
 *
 * Las barras se miden contra el total y no contra la fila más grande: medida
 * contra la mayor, una mora repartida en 900/100/50 y otra en 300/290/280 se
 * dibujaban casi igual, y la segunda —la preocupante— parecía más sana. Así,
 * la barra dice lo que dice el porcentaje de al lado.
 *
 * Con `link` en una fila, la fila entera es la puerta a la lista que resume,
 * como la tarjeta de `Stat`: el rótulo es el enlace y un `::after` lo estira.
 *
 * Cada fila se lee también en su globo (cifra y parte del total), al pasar el
 * ratón o recorriendo las filas con las flechas: la lista es una parada de
 * Tab, y los enlaces, las suyas.
 */
export function ShareBars<TRouter extends RegisteredRouter, TLinks extends ReadonlyArray<unknown>>(
  props: ShareBarsProps<TRouter, TLinks>,
): ReactNode
export function ShareBars({ rows, format, className = '' }: ShareBarsProps): ReactNode {
  const total = rows.reduce((s, r) => s + Math.max(r.value, 0), 0)
  const recorrido = useRecorridoDeMarcas(rows.length)

  const globo = (i: number): ContenidoDelGlobo => {
    const r = rows[i]
    return {
      titulo: r.label,
      filas: [
        {
          key: 'valor',
          rotulo: `${parteDelTotal(Math.max(r.value, 0), total)} del total`,
          valor: format(r.value),
          color: colorDeFila(r.tone),
          forma: 'punto',
        },
      ],
      nota: r.note,
    }
  }
  const activo = recorrido.senalada === null ? null : globo(recorrido.senalada)

  return (
    <div
      {...recorrido.caja}
      role="group"
      aria-label="Reparto: las flechas recorren las filas."
      className={`flex flex-col gap-3.5 rounded-panel-control ${className}`}
    >
      {rows.map((r, i) => {
        const parte = total > 0 ? (r.value / total) * 100 : 0
        return (
          <div
            key={r.key}
            {...recorrido.marca(i)}
            className={
              r.link
                ? 'relative -mx-2 -my-1 rounded-panel-control px-2 py-1 transition-colors duration-[var(--transition-fast)] hover:bg-panel-raised'
                : undefined
            }
          >
            <div className="flex items-baseline justify-between gap-4">
              {r.link ? (
                <Link
                  {...r.link}
                  className="type-panel-body text-on-surface-variant hover:text-on-surface after:absolute after:inset-0 after:rounded-panel-control"
                >
                  {r.label}
                </Link>
              ) : (
                <span className="type-panel-body text-on-surface-variant">{r.label}</span>
              )}
              <span className="flex shrink-0 items-baseline gap-2">
                <span className="type-panel-label tabular-nums text-on-surface">
                  {format(r.value)}
                </span>
                <span className="w-12 text-right type-panel-caption tabular-nums text-panel-muted">
                  {total > 0 ? `${parte.toFixed(0)} %` : '—'}
                </span>
              </span>
            </div>

            <div
              aria-hidden
              className="mt-1.5 h-1.5 overflow-hidden rounded-full"
              style={{ backgroundColor: SERIE.vacio }}
            >
              <div
                className="h-full rounded-full transition-opacity duration-[var(--transition-fast)]"
                // Una parte diminuta que no es cero tiene que verse, o se lee
                // como un cero.
                style={{
                  width: `${r.value > 0 ? Math.max(parte, 1) : 0}%`,
                  backgroundColor: colorDeFila(r.tone),
                  opacity: recorrido.senalada === null || recorrido.senalada === i ? 1 : 0.5,
                }}
              />
            </div>

            {r.note && <p className="mt-1 type-panel-caption text-panel-muted">{r.note}</p>}
          </div>
        )
      })}

      {activo && <GloboFlotante ancla={recorrido.ancla} {...activo} />}
      <p aria-live="polite" className="sr-only">
        {activo ? lecturaDelPunto(activo.titulo, activo.filas, activo.nota) : ''}
      </p>
    </div>
  )
}
