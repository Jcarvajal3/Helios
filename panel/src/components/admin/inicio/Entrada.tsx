import type { CSSProperties, ReactNode } from 'react'

/** Lo que tarda en entrar cada tarjeta después de la anterior. */
const PASO_MS = 40

/**
 * La entrada escalonada de las tarjetas de Inicio: cada una sube un poco
 * después de la anterior, con la animación `anim-aviso` del panel. Quien pide
 * menos movimiento no ve ninguna (styles.css la apaga).
 *
 * `both` deja la tarjeta invisible durante su espera: sin eso se vería, se
 * escondería al empezar su turno y volvería a aparecer.
 */
export function Entrada({ orden, children }: { orden: number; children: ReactNode }) {
  const estilo: CSSProperties = { animationDelay: `${orden * PASO_MS}ms`, animationFillMode: 'both' }
  return (
    <div className="anim-aviso h-full" style={estilo}>
      {children}
    </div>
  )
}
