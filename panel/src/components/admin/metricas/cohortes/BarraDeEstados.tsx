import { useState } from 'react'
import type { FocusEvent } from 'react'

import { SERIE } from '@/components/charts'
import { GloboFlotante, lecturaDelPunto, useSenalado } from '@/components/charts/lectura'
import type { FilaDelGlobo } from '@/components/charts/lectura'
import { formatUsd, formatNumero } from '@/components/ui'
import { desgloseCorto } from '@/features/admin/metricas/cohortes/desglose'
import type { Tramo } from '@/features/admin/metricas/cohortes/estados'
import { pct } from '@/features/admin/metricas/cohortes/frases'
import type { Desglose } from '@/features/admin/metricas/lectura'
import { COLOR_DE_ESTADO } from './colores'

/**
 * Una barra al 100 % partida en estados: lo que hay que cobrar de una semana,
 * o lo que se cobra en una cuota, por estado. Sin leyenda ni cifras: van
 * escritas al lado (la tarjeta de la cuota, la tabla), y el total va aparte
 * con su desglose.
 *
 * Al pasar el ratón por un tramo (o al recorrerla con las flechas) sale el
 * globo del kit al instante: cada estado con su cifra y su parte, el tramo
 * señalado más claro que los demás y, debajo, su desglose (consumo sin fee ·
 * fee). Dentro de un enlace (la lista de semanas) la barra no se enfoca sola:
 * `senaladaDesdeFuera` enseña el globo de la barra entera mientras el enlace
 * tiene el foco.
 *
 * Lo que vale cero no ocupa barra. Si todo es cero, queda la pista vacía: no
 * es lo mismo que una barra que no se pudo leer.
 */
export function BarraDeEstados<TClave extends string>({
  tramos,
  rotulo,
  titulo,
  total,
  alto = 'fina',
  enfocable = true,
  senaladaDesdeFuera = false,
  colores = COLOR_DE_ESTADO,
  className = '',
}: {
  tramos: ReadonlyArray<Tramo<TClave>>
  /** Qué se reparte, para el lector de pantalla: «Cuota 1 por estado». */
  rotulo: string
  /** El título del globo: «Cuota 1 · 14–20 sep». */
  titulo: string
  /** Lo que se reparte, con su desglose: va al pie del globo si no se señala un tramo. */
  total?: Desglose
  /** `fina` (5 px) en una lista; `media` (8 px) en una tabla; `gruesa` (12 px) en una tarjeta. */
  alto?: 'fina' | 'media' | 'gruesa'
  /** `false` dentro de un enlace o un botón: el foco es suyo, no de la barra. */
  enfocable?: boolean
  /** Enseña el globo de la barra entera (el enlace que la contiene tiene el foco). */
  senaladaDesdeFuera?: boolean
  /** El color de cada clave. Por defecto, los de los estados de una cuota. */
  colores?: Record<string, string>
  /** Con su ancho («w-20 shrink-0»); sin clase, la barra ocupa todo el ancho. */
  className?: string
}) {
  const [caja, setCaja] = useState<HTMLDivElement | null>(null)
  const [enfocada, setEnfocada] = useState(false)
  const visibles = tramos.filter((t) => t.valor > 0)
  const suma = visibles.reduce((a, t) => a + t.valor, 0)
  const { punto, lienzo } = useSenalado(visibles.length, (fraccion) => tramoBajo(visibles, suma, fraccion))
  const altura = alto === 'gruesa' ? 'h-3' : alto === 'media' ? 'h-2' : 'h-1.25'
  const lectura = tramos.map((t) => `${t.rotulo} ${formatUsd(t.valor)}`).join(', ')

  const senalado = punto === null ? null : (visibles[punto] ?? null)
  // Al entrar con el teclado sale el globo de la barra entera; las flechas
  // señalan después cada tramo.
  const abierto = tramos.length > 0 && (senalado !== null || enfocada || senaladaDesdeFuera)
  const filas: FilaDelGlobo[] = tramos.map((t) => ({
    key: t.clave,
    rotulo: t.rotulo,
    valor: `${formatUsd(t.valor)}${suma > 0 && t.valor > 0 ? ` · ${pct((t.valor / suma) * 100)}` : ''}`,
    color: t.valor > 0 ? colores[t.clave] : SERIE.tenue,
    forma: 'punto',
  }))
  const nota = senalado
    ? [
        senalado.desglose ? `${senalado.rotulo}: ${desgloseCorto(senalado.desglose)}` : null,
        senalado.personas !== undefined
          ? `${formatNumero(senalado.personas, 0)} ${senalado.personas === 1 ? 'paciente' : 'pacientes'}`
          : null,
      ]
        .filter((x) => x !== null)
        .join(' · ')
    : total
      ? `Total ${formatUsd(total.payableUsd)}: ${desgloseCorto(total)}`
      : undefined

  // El centro del tramo señalado, en % del ancho: ahí apunta el globo.
  let x = 0
  if (senalado && suma > 0) {
    const antes = visibles.slice(0, punto ?? 0).reduce((a, t) => a + t.valor, 0)
    x = ((antes + senalado.valor / 2) / suma) * 100
  }

  const accesible = enfocable
    ? {
        ...lienzo,
        // Solo con el teclado: un clic también enfoca, y el globo se quedaría
        // puesto al apartar el ratón.
        onFocus: (e: FocusEvent<HTMLDivElement>) => setEnfocada(e.currentTarget.matches(':focus-visible')),
        onBlur: () => {
          setEnfocada(false)
          lienzo.onBlur()
        },
        role: 'img',
        'aria-label': `${rotulo}: ${lectura}. Las flechas recorren los estados.`,
      }
    : {
        role: 'img',
        'aria-label': `${rotulo}: ${lectura}`,
        onPointerMove: lienzo.onPointerMove,
        onPointerLeave: lienzo.onPointerLeave,
      }

  return (
    // El aire de arriba y abajo agranda la zona que se señala sin mover nada:
    // una barra de cinco píxeles no se acierta con el ratón.
    <div
      ref={setCaja}
      {...accesible}
      className={`relative -my-1.5 touch-pan-y rounded-full py-1.5 ${className || 'w-full'}`}
    >
      <div
        className={`flex w-full gap-0.5 overflow-hidden rounded-full ${altura}`}
        style={{ backgroundColor: visibles.length === 0 ? SERIE.vacio : undefined }}
      >
        {visibles.map((t, i) => (
          <span
            key={t.clave}
            className="h-full min-w-0.75 transition-opacity duration-[var(--transition-fast)]"
            style={{
              flex: `${t.valor} 1 0`,
              backgroundColor: colores[t.clave],
              opacity: punto === null || punto === i ? 1 : 0.45,
            }}
          />
        ))}
      </div>

      {abierto && <GloboFlotante ancla={caja} x={x} titulo={titulo} filas={filas} nota={nota} />}
      {enfocable && (
        <span aria-live="polite" className="sr-only">
          {senalado ? lecturaDelPunto(titulo, filas.filter((f) => f.key === senalado.clave), nota) : ''}
        </span>
      )}
    </div>
  )
}

/** Qué tramo cae bajo el puntero, con `fraccion` de 0 a 1 a lo ancho: los tramos miden lo que valen. */
function tramoBajo(visibles: ReadonlyArray<{ valor: number }>, suma: number, fraccion: number): number {
  if (visibles.length <= 1 || suma <= 0) return 0
  let acumulado = 0
  for (let i = 0; i < visibles.length; i++) {
    acumulado += visibles[i].valor / suma
    if (fraccion <= acumulado) return i
  }
  return visibles.length - 1
}
