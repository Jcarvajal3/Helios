import { SkeletonBlock } from '@/components/ui'

/** Un trozo de la frase: texto corrido, o una cifra que se destaca en blanco. */
export type ParteDeFrase = string | { cifra: string }

/**
 * La frase de arriba de una pestaña, con los números dentro: «La semana va
 * por **€912,40 de consumo**, un 12 % más que la anterior…». Una frase con
 * las cifras vale más que un párrafo, y se lee antes que las tarjetas.
 *
 * Las cifras van en blanco y el resto en gris; ninguna en color: el estado lo
 * dicen las pastillas de las tarjetas. La frase la arma la pestaña con sus
 * datos (en un `.ts` con su prueba); esto solo la pinta.
 *
 *   <FraseConCifras partes={['La semana va por ', { cifra: '€912,40 de consumo' }, '.']} />
 */
export function FraseConCifras({
  partes,
  cargando = false,
  className = '',
}: {
  partes: ReadonlyArray<ParteDeFrase>
  /** Mientras llegan los datos, el hueco de una línea: la frase no se inventa. */
  cargando?: boolean
  className?: string
}) {
  if (cargando) return <SkeletonBlock className={`h-5 w-3/5 ${className}`} />

  return (
    <p className={`max-w-(--panel-measure-normal) text-pretty type-panel-body text-on-surface-variant ${className}`}>
      {partes.map((parte, i) =>
        typeof parte === 'string' ? (
          parte
        ) : (
          <strong key={i} className="font-semibold text-on-surface">
            {parte.cifra}
          </strong>
        ),
      )}
    </p>
  )
}
