import type { ReactNode } from 'react'

import type { BadgeTone } from '@/components/ui'
import { formatPorcentaje } from '@/components/ui'
import { fraccionDelAnillo, puntoDelAnillo } from '@/components/charts/geometria'
import { useGloboDeMarca } from '@/components/charts/lectura'
import type { ContenidoDelGlobo, FilaDelGlobo } from '@/components/charts/lectura'
import { SERIE, colorDeTono } from '@/components/charts/tonos'

export type RingProps = {
  /** De 0 a 1. Sin dato, `null`: la pista sola y «—» en el centro. */
  valor: number | null
  /** El del área, o el de estado cuando la cifra cruza un umbral. */
  tono?: 'area' | BadgeTone
  /** 56, 72 o 96 px. */
  tamano?: 'sm' | 'md' | 'lg'
  /** Lo que va dentro: «72 %». Sin esto, dentro no va nada (salvo el «—»). */
  centro?: ReactNode
  /** De 0 a 1: una marca en la pista, la meta o el umbral. */
  meta?: number
  /** Lo que lee un lector de pantalla, con la cifra dentro: «Impago de la primera cuota: 12 %». */
  rotulo: string
  /**
   * Lo que dice el globo al pasar el ratón o al llegar con Tab. Sin esto,
   * sale del `rotulo`: lo de antes de los dos puntos es el título y lo de
   * después, la cifra («Impago de la primera cuota» · «12 %»), y la meta, si
   * la hay, en su fila.
   */
  globo?: ContenidoDelGlobo
}

const TAMANO = { sm: 'size-14', md: 'size-18', lg: 'size-24' } as const
const LETRA = {
  sm: 'type-panel-caption font-semibold',
  md: 'type-panel-label',
  lg: 'type-panel-section',
} as const

// El lienzo del anillo: 72 × 72, radio 30 y trazo 8. Escala con el tamaño.
const CENTRO = 36
const RADIO = 30
const GROSOR = 8

/** Un porcentaje de 0 a 1 escrito como en el resto del panel: «12,5 %». */
function pct(f: number): string {
  const n = f * 100
  return formatPorcentaje(n, Number.isInteger(Math.round(n * 10) / 10) ? 0 : 1)
}

/** El globo que sale del rótulo cuando quien llama no da uno. */
export function globoDelAnillo({
  rotulo,
  valor,
  meta,
  color,
}: {
  rotulo: string
  valor: number | null
  meta: number | null
  color: string
}): ContenidoDelGlobo {
  const corte = rotulo.indexOf(': ')
  const titulo = corte > 0 ? rotulo.slice(0, corte) : rotulo
  const cifra = corte > 0 ? rotulo.slice(corte + 2) : valor === null ? 'Sin dato' : pct(valor)
  const filas: FilaDelGlobo[] = [{ key: 'valor', rotulo: '', valor: cifra, color, forma: 'punto' }]
  if (meta !== null) {
    filas.push({ key: 'meta', rotulo: 'la raya: meta o umbral', valor: pct(meta), color: 'var(--color-on-surface)', forma: 'linea' })
  }
  return { titulo, filas }
}

/**
 * UNA proporción: «72 de 100». Para cifras sueltas que son una parte de un
 * todo —impago de la primera cuota, cotejo automático, verificaciones
 * aprobadas—, al lado del número o solo en una tarjeta.
 *
 * Un cero no es un anillo vacío: lleva un punto a las 12, igual que la barra
 * de un día sin ventas lleva su marca en la base. Y sin dato no hay nada que
 * dibujar: la pista sola y «—».
 *
 * Se lee en su globo al pasar el ratón o al llegar con Tab: va por encima del
 * enlace estirado de la tarjeta en la que vive.
 */
export function Ring({ valor, tono = 'area', tamano = 'md', centro, meta, rotulo, globo }: RingProps) {
  const f = fraccionDelAnillo(valor)
  const m = fraccionDelAnillo(meta)
  const dentro = centro ?? (f === null ? '—' : null)
  const { disparador, globo: globoPintado } = useGloboDeMarca<HTMLDivElement>(
    globo ?? globoDelAnillo({ rotulo, valor: f, meta: m, color: colorDeTono(tono) }),
  )

  const marcaDentro = m === null ? null : puntoDelAnillo(m, RADIO - GROSOR / 2 - 2, CENTRO)
  const marcaFuera = m === null ? null : puntoDelAnillo(m, RADIO + GROSOR / 2 + 2, CENTRO)

  return (
    <div
      {...disparador}
      tabIndex={0}
      role="img"
      aria-label={rotulo}
      className={`relative z-10 shrink-0 rounded-full ${TAMANO[tamano]}`}
    >
      <svg viewBox="0 0 72 72" aria-hidden className="size-full">
        <circle
          cx={CENTRO}
          cy={CENTRO}
          r={RADIO}
          fill="none"
          strokeWidth={GROSOR}
          style={{ stroke: SERIE.vacio }}
        />
        {f !== null && f > 0 && (
          <circle
            cx={CENTRO}
            cy={CENTRO}
            r={RADIO}
            fill="none"
            strokeWidth={GROSOR}
            strokeLinecap="round"
            // Con `pathLength` 100 el trazo se mide en tanto por ciento.
            pathLength={100}
            strokeDasharray={`${f * 100} 100`}
            transform={`rotate(-90 ${CENTRO} ${CENTRO})`}
            style={{ stroke: colorDeTono(tono) }}
          />
        )}
        {f === 0 && (
          <circle cx={CENTRO} cy={CENTRO - RADIO} r={2} style={{ fill: SERIE.contexto }} />
        )}
        {marcaDentro && marcaFuera && (
          <line
            x1={marcaDentro.x}
            y1={marcaDentro.y}
            x2={marcaFuera.x}
            y2={marcaFuera.y}
            strokeWidth={2}
            strokeLinecap="round"
            style={{ stroke: 'var(--color-on-surface)' }}
          />
        )}
      </svg>

      {dentro !== null && (
        <span
          aria-hidden
          className={`absolute inset-0 flex items-center justify-center text-on-surface ${LETRA[tamano]}`}
        >
          {dentro}
        </span>
      )}
      {globoPintado}
    </div>
  )
}
