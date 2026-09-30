import type { CSSProperties } from 'react'

/** Un resplandor radial de un color del sistema, que se apaga hacia fuera. */
function resplandor(forma: string, color: string, fuerza: number, hasta: number): string {
  return `radial-gradient(${forma}, color-mix(in oklab, var(${color}) ${fuerza}%, transparent), transparent ${hasta}%)`
}

/**
 * Detrás de la barra, un violeta muy suave con un punto de lima en el centro;
 * en la charla, solo el violeta, más bajo, detrás del campo.
 */
const FONDO: Record<'heroe' | 'charla', CSSProperties> = {
  heroe: {
    backgroundImage: [
      resplandor('ellipse 50% 60% at 50% 62%', '--color-secondary', 20, 72),
      resplandor('ellipse 26% 32% at 50% 66%', '--color-primary', 5, 70),
    ].join(', '),
  },
  charla: {
    backgroundImage: resplandor('ellipse 45% 40% at 50% 100%', '--color-secondary', 14, 72),
  },
}

/**
 * El halo de Inicio: decorativo, quieto y por detrás de todo. Sale de los
 * tokens del sistema (`--color-secondary`, `--color-primary`) y no de un hex,
 * así que sigue a la paleta si cambia. El padre tiene que ser `relative
 * isolate` para que el halo quede detrás de su contenido y no del lienzo.
 */
export function Halo({ donde }: { donde: 'heroe' | 'charla' }) {
  return <div aria-hidden className="pointer-events-none absolute inset-0 -z-10" style={FONDO[donde]} />
}
