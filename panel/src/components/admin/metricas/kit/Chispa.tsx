import { SERIE } from '@/components/charts'
import { GloboFlotante, lecturaDelPunto, useRecorridoDeMarcas } from '@/components/charts/lectura'
import type { ContenidoDelGlobo } from '@/components/charts/lectura'

export type ChispaProps = {
  /** Del más viejo al más nuevo. `null` es que todavía no ha pasado (una marca más apagada). */
  valores: ReadonlyArray<number | null>
  /**
   * Qué son las barras, para quien no las ve: «Consumo de las últimas ocho
   * semanas». Va delante de cada valor en el rótulo accesible.
   */
  rotulo: string
  /** El nombre de cada barra, en el mismo orden: «14–20 sep». Sin él, «1», «2»… */
  etiquetas?: ReadonlyArray<string>
  /** Cómo se escribe cada valor en el rótulo y en el globo. */
  formato?: (n: number) => string
  /**
   * El nombre corto de la serie en el globo, junto a la cifra: «Consumo (sin
   * comisión)». Sin él, solo la cifra: el título de la tarjeta ya dice qué es.
   */
  serie?: string
  /** La barra que va en el tono del área. Por defecto, la última: la semana elegida. */
  destacada?: number
  /** Alto en px. */
  alto?: number
}

/**
 * La chispa de una cifra: N barras mínimas, las anteriores en gris y la
 * elegida en el tono del área (`var(--area)`, que pone la pestaña).
 *
 * Como `MiniBarras` y `Sparkline`, va sin eje y sin tabla: la cifra que
 * acompaña ya está escrita al lado, y la serie entera con sus números está en
 * la tabla de la pestaña. Cada valor va en el rótulo accesible y en el globo
 * de su barra, que sale al instante al pasar el ratón; con el teclado, la
 * chispa es una parada de Tab (se entra por la destacada) y las flechas
 * recorren las barras. Un cero deja una marca en la base: no es un hueco.
 */
export function Chispa({
  valores,
  rotulo,
  etiquetas,
  formato = String,
  serie = '',
  destacada = valores.length - 1,
  alto = 28,
}: ChispaProps) {
  const recorrido = useRecorridoDeMarcas(valores.length, { alEnfocar: destacada })
  const punto = recorrido.senalada

  const limpios = valores.map((v) => (v !== null && Number.isFinite(v) ? v : null))
  const max = Math.max(0, ...limpios.map((v) => v ?? 0))
  const nombre = (i: number) => etiquetas?.[i] ?? String(i + 1)
  const leer = (i: number) => {
    const v = limpios[i]
    return `${nombre(i)}: ${v === null ? 'todavía no' : formato(v)}`
  }
  const lectura = limpios.map((_, i) => leer(i)).join(', ')

  const colorDe = (i: number) => {
    const v = limpios[i] ?? null
    if (v === null) return SERIE.futuro
    return i === destacada && v > 0 ? SERIE.principal : SERIE.tenue
  }

  const globo = (i: number): ContenidoDelGlobo => {
    const v = limpios[i] ?? null
    return {
      titulo: nombre(i),
      filas: [
        {
          key: 'valor',
          rotulo: serie,
          valor: v === null ? 'Todavía no' : formato(v),
          // En el globo, la muestra va en el tono del área aunque la barra
          // sea gris: gris es «no es la elegida», no «no es esta serie».
          color: v === null ? SERIE.futuro : SERIE.principal,
          forma: 'punto',
        },
      ],
    }
  }
  const activo = punto === null ? null : globo(punto)

  return (
    <>
      <div
        {...recorrido.caja}
        role="img"
        aria-label={`${rotulo}. ${lectura}`}
        // Encima del enlace estirado de la tarjeta, para que el ratón llegue.
        className="relative z-10 flex w-full touch-pan-y items-end gap-0.75 rounded-extra-small"
        style={{ height: alto }}
      >
        {limpios.map((v, i) => {
          const parte = v !== null && v > 0 && max > 0 ? (v / max) * 100 : 0
          return (
            // La columna entera, de arriba abajo, es lo que se señala: una
            // semana a cero mide tres píxeles y no se atinaría con el ratón.
            <span
              key={`${i}-${nombre(i)}`}
              {...recorrido.marca(i)}
              aria-hidden
              className="flex h-full min-w-0 flex-1 items-end"
              style={{ maxWidth: 12 }}
            >
              <span
                className="w-full rounded-t-[2px] transition-opacity duration-[var(--transition-fast)]"
                // Tres píxeles como mínimo: una semana floja no es una semana
                // en cero, y un cero también deja su marca.
                style={{
                  height: parte > 0 ? `max(3px, ${parte}%)` : '3px',
                  backgroundColor: colorDe(i),
                  opacity: punto === null || punto === i ? 1 : 0.5,
                }}
              />
            </span>
          )
        })}
      </div>

      {activo && <GloboFlotante ancla={recorrido.ancla} {...activo} />}
      <span aria-live="polite" className="sr-only">
        {activo ? lecturaDelPunto(activo.titulo, activo.filas) : ''}
      </span>
    </>
  )
}
