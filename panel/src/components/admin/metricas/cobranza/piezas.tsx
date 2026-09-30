import type { ReactNode } from 'react'

import { NoSePudoLeer, SkeletonList } from '@/components/ui'
import { SeccionMetricas } from '@/components/admin/metricas/kit'
import type { ParteDeFrase } from '@/components/admin/metricas/kit'
import { textoDelDesglose } from '@/features/admin/metricas/cobranza/semana'
import type { Desglose } from '@/features/admin/metricas/lectura'

// ═══════════════════════════════════════════════════════════════════════════
// Las piezas pequeñas que repiten los bloques de Cobranza y riesgo.
// ═══════════════════════════════════════════════════════════════════════════

/** Lo que un bloque necesita de su `useQuery`. */
export type ConsultaDeBloque<T> = {
  data: T | undefined
  isError: boolean
  isPlaceholderData?: boolean
  refetch: () => unknown
}

/**
 * Un bloque de la pestaña: su tarjeta con título y lo que sale de UNA
 * consulta. Mientras carga, un esqueleto; si falla, «No se pudo leer» con su
 * botón. Nunca un cero ni una lista vacía que no se ha leído. Al cambiar de
 * semana se queda lo anterior, atenuado, hasta que llega lo nuevo.
 */
export function Bloque<T>({
  titulo,
  info,
  ayuda,
  acciones,
  consulta,
  filas = 3,
  className = '',
  children,
}: {
  titulo: string
  info?: string
  ayuda?: string
  acciones?: ReactNode
  consulta: ConsultaDeBloque<T>
  filas?: number
  className?: string
  children: (data: T) => ReactNode
}) {
  return (
    <SeccionMetricas titulo={titulo} info={info} ayuda={ayuda} acciones={acciones} className={className}>
      {consulta.isError ? (
        <NoSePudoLeer onReintentar={() => void consulta.refetch()} />
      ) : consulta.data === undefined ? (
        <SkeletonList rows={filas} />
      ) : (
        <div
          className={`transition-opacity duration-[var(--duration-medium1)] ${
            consulta.isPlaceholderData ? 'opacity-60' : 'opacity-100'
          }`}
        >
          {children(consulta.data)}
        </div>
      )}
    </SeccionMetricas>
  )
}

/**
 * «Facturado €146,72 (sin fee) · service fee + IVA €34,04»: la línea que
 * acompaña SIEMPRE a una suma de cuotas (la regla del fee).
 */
export function LineaDeDesglose({ desglose, className = '' }: { desglose: Desglose; className?: string }) {
  return <span className={`type-panel-caption text-panel-muted ${className}`}>{textoDelDesglose(desglose)}</span>
}

/**
 * Una fila de «rótulo … cifra», con una línea debajo si hace falta (el
 * desglose de un importe). Es la lista del paso entre tramos y de la
 * recuperación.
 */
export function FilaDeCifra({
  rotulo,
  valor,
  debajo,
  tono = 'normal',
}: {
  rotulo: ReactNode
  valor: ReactNode
  debajo?: ReactNode
  /** El color del número, cuando ES la lectura (mejor, peor). */
  tono?: 'normal' | 'bueno' | 'malo' | 'alerta'
}) {
  const color =
    tono === 'bueno'
      ? 'text-success'
      : tono === 'malo'
        ? 'text-error'
        : tono === 'alerta'
          ? 'text-warning'
          : 'text-on-surface'
  return (
    <li className="flex flex-col gap-0.5 border-t border-panel-hairline py-2 first:border-t-0">
      <span className="flex items-baseline justify-between gap-4 type-panel-body">
        <span className="text-on-surface-variant">{rotulo}</span>
        <span className={`font-semibold tabular-nums ${color}`}>{valor}</span>
      </span>
      {debajo && <span className="text-right">{debajo}</span>}
    </li>
  )
}

/**
 * Las partes de una frase con cifras, sin su párrafo: para ir dentro de otro
 * (la línea de resumen de un gráfico ya es un `<p>`). Las cifras en blanco.
 */
export function PartesEnLinea({ partes }: { partes: ReadonlyArray<ParteDeFrase> }) {
  return (
    <>
      {partes.map((parte, i) =>
        typeof parte === 'string' ? (
          <span key={i}>{parte}</span>
        ) : (
          <strong key={i} className="font-semibold text-on-surface">
            {parte.cifra}
          </strong>
        ),
      )}
    </>
  )
}

/** «1 usuario», «3 usuarios». */
export function usuarios(n: number): string {
  return `${n} ${n === 1 ? 'paciente' : 'pacientes'}`
}
