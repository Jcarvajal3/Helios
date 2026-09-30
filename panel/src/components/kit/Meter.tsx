import type { BadgeTone } from '@/components/ui'
import { useGloboDeMarca } from '@/components/charts/lectura'
import type { ContenidoDelGlobo } from '@/components/charts/lectura'
import { colorDeTono } from '@/components/charts/tonos'

import { RELLENO_DE_TONO } from './tonos'

/** Una posición de 0 a 100 dentro de la pista, sin salirse de ella. */
function porcentaje(valor: number, max: number): number {
  if (!Number.isFinite(valor) || max <= 0) return 0
  return Math.min(Math.max(valor / max, 0), 1) * 100
}

/**
 * Dónde se ancla el rótulo de una marca: centrado, salvo pegado a un borde,
 * donde se saldría de la tarjeta.
 */
function anclaDelRotulo(pct: number): string {
  if (pct < 6) return 'translate-x-0'
  if (pct > 94) return '-translate-x-full'
  return '-translate-x-1/2'
}

/**
 * El globo de un medidor cuando quien llama no da uno: lo de antes de los dos
 * puntos del rótulo es el título y lo de después, la cifra («Cupo en uso» ·
 * «45 %»). Sin dos puntos, el rótulo entero y la parte llena.
 */
export function globoDelMedidor(rotulo: string, parte: number, color: string): ContenidoDelGlobo {
  const corte = rotulo.indexOf(': ')
  const cifra =
    corte > 0 ? rotulo.slice(corte + 2) : `${Math.round(parte).toLocaleString('es-VE')} % lleno`
  return {
    titulo: corte > 0 ? rotulo.slice(0, corte) : rotulo,
    filas: [{ key: 'valor', rotulo: '', valor: cifra, color, forma: 'punto' }],
  }
}

/**
 * Un medidor: cuánto de algo, en una pista de 6 px.
 *
 * Sustituye las seis barras que cada pantalla dibujaba a mano, de 6, 8 o
 * 10 px y con dos grises distintos. Va en el tono del área; en el de un estado
 * solo cuando la cifra cruza un umbral, y los umbrales se pintan como marcas
 * para que se vea cuánto falta.
 *
 * Se lee en su globo al pasar el ratón (la pista cuenta seis píxeles más por
 * arriba y por abajo, que seis solos no se atinan) o al llegar con Tab. Va
 * por encima del enlace estirado de la tarjeta en la que vive.
 */
export function Meter({
  valor,
  max = 1,
  tono = 'area',
  marcas,
  rotulo,
  globo,
  className = '',
}: {
  valor: number
  /** Por defecto 1: el valor es una proporción. */
  max?: number
  tono?: 'area' | BadgeTone
  /** Los umbrales, con su rótulo debajo si lo llevan: `{ valor: 0.07, rotulo: '7 %' }`. */
  marcas?: ReadonlyArray<{ valor: number; rotulo?: string }>
  /** El nombre del medidor para el lector de pantalla, con la cifra dentro. */
  rotulo: string
  /** Lo que dice el globo. Sin esto, sale del `rotulo` (`globoDelMedidor`). */
  globo?: ContenidoDelGlobo
  className?: string
}) {
  const conRotulos = marcas?.some((m) => m.rotulo) ?? false
  const { disparador, globo: globoPintado } = useGloboDeMarca<HTMLDivElement>(
    globo ?? globoDelMedidor(rotulo, porcentaje(valor, max), tono === 'area' ? 'var(--area)' : colorDeTono(tono)),
  )

  return (
    <div className={className}>
      <div
        {...disparador}
        tabIndex={0}
        role="meter"
        aria-label={rotulo}
        aria-valuemin={0}
        aria-valuemax={max}
        aria-valuenow={Number.isFinite(valor) ? Math.min(Math.max(valor, 0), max) : 0}
        className="relative z-10 h-1.5 rounded-full bg-panel-control before:absolute before:inset-x-0 before:-inset-y-1.5"
      >
        <div
          className={`h-full rounded-full transition-all duration-300 motion-reduce:transition-none ${RELLENO_DE_TONO[tono]}`}
          style={{ width: `${porcentaje(valor, max)}%` }}
        />
        {marcas?.map((m) => (
          <span
            key={m.valor}
            aria-hidden
            className="absolute -top-1 h-3.5 w-0.5 -translate-x-1/2 rounded-full bg-panel-muted"
            style={{ left: `${porcentaje(m.valor, max)}%` }}
          />
        ))}
      </div>

      {conRotulos && (
        <div aria-hidden className="relative mt-1.5 h-4 type-panel-caption text-panel-muted">
          {marcas?.map((m) => {
            if (!m.rotulo) return null
            const pct = porcentaje(m.valor, max)
            return (
              <span
                key={m.valor}
                className={`absolute whitespace-nowrap ${anclaDelRotulo(pct)}`}
                style={{ left: `${pct}%` }}
              >
                {m.rotulo}
              </span>
            )
          })}
        </div>
      )}
      {globoPintado}
    </div>
  )
}
