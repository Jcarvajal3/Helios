import { parteDelTotal } from '@/components/charts/comun'
import { limpio } from '@/components/charts/geometria'
import {
  GloboFlotante,
  Muestra,
  lecturaDelPunto,
  useRecorridoDeMarcas,
} from '@/components/charts/lectura'
import type { ContenidoDelGlobo } from '@/components/charts/lectura'
import { SERIE, colorDeTono } from '@/components/charts/tonos'
import type { TonoDeMarca } from '@/components/charts/tonos'

// ═══════════════════════════════════════════════════════════════════════════
// Los gráficos que caben dentro de una cifra o de una tarjeta pequeña: la
// semana en barras mínimas y la barra apilada al 100 %. Sin eje y sin tabla:
// la cifra que acompañan ya está escrita al lado, y cada número va en el
// rótulo accesible y en el globo, que sale al pasar el ratón o al llegar con
// el teclado (las flechas recorren las barras o los segmentos).
// ═══════════════════════════════════════════════════════════════════════════

export type PuntoDeMiniBarras = {
  rotulo: string
  /** El nombre entero, para el globo: «lunes 21». Sin él, el rótulo. */
  titulo?: string
  /** `null` es futuro (una marca tenue); 0 es una marca gris en la base. */
  valor: number | null
  /** El de hoy: su rótulo va en blanco. */
  destacado?: boolean
}

export type MiniBarrasProps = {
  puntos: ReadonlyArray<PuntoDeMiniBarras>
  /** 36 px para la ranura de una cifra; 96 px para una tarjeta con «pocos datos». */
  alto?: 'sm' | 'md'
  formato?: (n: number) => string
  /** Qué son las barras, para el lector de pantalla: «Registrado esta semana». */
  rotulo: string
  /** El nombre corto de la serie en el globo, junto a la cifra: «Consumos». */
  serie?: string
}

/** Se señala al entrar con Tab: la destacada o, si no hay, la última con dato. */
function puntoDeEntrada(puntos: ReadonlyArray<PuntoDeMiniBarras>, valores: ReadonlyArray<number | null>) {
  const destacado = puntos.findIndex((p) => p.destacado)
  if (destacado >= 0) return destacado
  for (let i = valores.length - 1; i >= 0; i--) if (valores[i] !== null) return i
  return puntos.length - 1
}

/**
 * Barras mínimas: la semana de una tarjeta de Inicio, o catorce días con
 * pocos datos. Con siete o menos, cada barra lleva su rótulo debajo; con más,
 * solo la primera y la última.
 */
export function MiniBarras({ puntos, alto = 'sm', formato = String, rotulo, serie = '' }: MiniBarrasProps) {
  const valores = puntos.map((p) => limpio(p.valor))
  const recorrido = useRecorridoDeMarcas(puntos.length, { alEnfocar: puntoDeEntrada(puntos, valores) })
  const punto = recorrido.senalada
  const max = Math.max(0, ...valores.map((v) => v ?? 0))
  const lectura = puntos
    .map((p, i) => {
      const v = valores[i]
      return `${p.rotulo}: ${v === null ? 'todavía no' : formato(v)}`
    })
    .join(', ')
  const primero = puntos.at(0)
  const ultimo = puntos.at(-1)

  const globo = (i: number): ContenidoDelGlobo => {
    const v = valores[i] ?? null
    const p = puntos.at(i)
    return {
      titulo: p?.titulo ?? p?.rotulo ?? '',
      filas: [
        {
          key: 'valor',
          rotulo: serie,
          valor: v === null ? 'Todavía no' : formato(v),
          color: v === null ? SERIE.futuro : v > 0 ? SERIE.principal : SERIE.tenue,
          forma: 'punto',
        },
      ],
    }
  }
  const activo = punto === null ? null : globo(punto)

  return (
    <div className="w-full">
      <div
        {...recorrido.caja}
        role="img"
        aria-label={`${rotulo}. ${lectura}`}
        // Encima del enlace estirado de la tarjeta, para que el ratón llegue.
        className={`relative z-10 flex touch-pan-y items-end gap-1.5 rounded-extra-small ${
          alto === 'md' ? 'h-24 border-b border-panel-hairline-strong' : 'h-9'
        }`}
      >
        {puntos.map((p, i) => {
          const v = valores[i]
          const parte = v !== null && max > 0 ? (v / max) * 100 : 0
          return (
            <div
              key={`${i}-${p.rotulo}`}
              {...recorrido.marca(i)}
              className="flex h-full min-w-0 flex-1 items-end justify-center transition-opacity duration-[var(--transition-fast)]"
              style={{ opacity: punto === null || punto === i ? 1 : 0.5 }}
            >
              {v !== null && v > 0 ? (
                <span
                  className="w-full max-w-6 rounded-t-extra-small"
                  // Tres píxeles como mínimo: un día flojo no es un día a cero.
                  style={{ height: `max(3px, ${parte}%)`, backgroundColor: SERIE.principal }}
                />
              ) : (
                <span
                  className="h-0.75 w-full max-w-6 rounded-full"
                  style={{ backgroundColor: v === null ? SERIE.futuro : SERIE.tenue }}
                />
              )}
            </div>
          )
        })}
      </div>

      {activo && <GloboFlotante ancla={recorrido.ancla} {...activo} />}
      <p aria-live="polite" className="sr-only">
        {activo ? lecturaDelPunto(activo.titulo, activo.filas) : ''}
      </p>

      {puntos.length <= 7 ? (
        <div className="mt-1 flex gap-1.5" aria-hidden>
          {puntos.map((p, i) => (
            <span
              key={`${i}-${p.rotulo}`}
              className={`min-w-0 flex-1 truncate text-center type-panel-caption ${
                p.destacado || i === punto
                  ? 'font-semibold text-on-surface'
                  : valores[i] === null
                    ? 'text-on-surface-faint'
                    : 'text-panel-muted'
              }`}
            >
              {p.rotulo}
            </span>
          ))}
        </div>
      ) : (
        primero &&
        ultimo && (
          <div className="mt-1 flex justify-between type-panel-caption text-panel-muted" aria-hidden>
            <span>{primero.rotulo}</span>
            <span>{ultimo.rotulo}</span>
          </div>
        )
      )}
    </div>
  )
}

export type SegmentoApilado = {
  rotulo: string
  valor: number
  tono: TonoDeMarca
  /**
   * Un paso de `rampaOrdinal`, para repartir categorías que no son un estado
   * ni se comparan contra un contexto (sexo, sistema del teléfono): con solo
   * `area` y `neutro`, la tercera no se distinguía. Manda sobre `tono`.
   */
  color?: string
}

/** El color de un segmento: el suyo, si lo trae, o el de su tono. */
function colorDeSegmento(s: SegmentoApilado): string {
  return s.color ?? colorDeTono(s.tono)
}

export type StackedBarProps = {
  segmentos: ReadonlyArray<SegmentoApilado>
  /** Debajo, cada segmento con su cifra. Por defecto sí: el color solo no identifica. */
  leyenda?: boolean
  formato?: (n: number) => string
  /** Qué se reparte, para el lector de pantalla: «Personas por estado». */
  rotulo: string
}

/**
 * Una barra al 100 %: cómo se reparte un todo (personas por estado, cupos
 * usados). Dos píxeles de aire entre segmentos, y ninguno tan fino que
 * desaparezca. Lo que vale cero no ocupa barra, pero sigue en la leyenda,
 * apagado: «Suspendidas 0» también es un dato.
 *
 * Cada segmento se lee en su globo —su cifra y qué parte es del total— al
 * pasar el ratón; con el teclado, la barra es una parada de Tab y las
 * flechas van de un segmento al siguiente. El globo no escribe ningún total:
 * si los segmentos son cuotas, su suma sería un total con la comisión de
 * servicio dentro.
 */
export function StackedBar({ segmentos, leyenda = true, formato = String, rotulo }: StackedBarProps) {
  const valores = segmentos.map((s) => Math.max(0, limpio(s.valor) ?? 0))
  const total = valores.reduce((a, b) => a + b, 0)
  const lectura = segmentos.map((s, i) => `${s.rotulo} ${formato(valores[i])}`).join(', ')
  const r = useRecorridoDeMarcas(segmentos.length, { saltar: (i) => !(valores[i] > 0) })

  const globo = (i: number): ContenidoDelGlobo => {
    const s = segmentos[i]
    return {
      titulo: s.rotulo,
      filas: [
        {
          key: 'valor',
          rotulo: `${parteDelTotal(valores[i], total)} del total`,
          valor: formato(valores[i]),
          color: colorDeSegmento(s),
          forma: 'punto',
        },
      ],
    }
  }
  const activo = r.senalada === null ? null : globo(r.senalada)

  return (
    <div>
      <div
        {...r.caja}
        role="img"
        aria-label={`${rotulo}: ${lectura}`}
        className="relative z-10 flex h-2.5 touch-pan-y gap-0.5 overflow-hidden rounded-full"
        style={{ backgroundColor: total === 0 ? SERIE.vacio : undefined }}
      >
        {segmentos.map((s, i) =>
          valores[i] > 0 ? (
            <span
              key={`${i}-${s.rotulo}`}
              {...r.marca(i)}
              className="h-full min-w-0.75 transition-opacity duration-[var(--transition-fast)]"
              style={{
                flex: `${valores[i]} 1 0`,
                backgroundColor: colorDeSegmento(s),
                opacity: r.senalada === null || r.senalada === i ? 1 : 0.5,
              }}
            />
          ) : null,
        )}
      </div>

      {activo && <GloboFlotante ancla={r.ancla} {...activo} />}
      <p aria-live="polite" className="sr-only">
        {activo ? lecturaDelPunto(activo.titulo, activo.filas) : ''}
      </p>

      {leyenda && (
        <ul aria-label={rotulo} className="mt-3 flex flex-wrap gap-x-3.5 gap-y-1.5">
          {segmentos.map((s, i) => (
            <li
              key={`${i}-${s.rotulo}`}
              className={`inline-flex items-center gap-1.5 type-panel-caption ${
                valores[i] > 0 ? 'text-on-surface' : 'text-panel-muted'
              }`}
            >
              <Muestra color={valores[i] > 0 ? colorDeSegmento(s) : SERIE.tenue} />
              {s.rotulo} {formato(valores[i])}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
