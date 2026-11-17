import { IconoDeEspecialidad } from './IconoDeEspecialidad'
import type { ClaveDeEspecialidad } from '@/features/directorio/especialidades'

/**
 * El icono de una especialidad en la tarjeta del directorio, la ficha del
 * médico y el home: una baldosa de vidrio azul con el glifo en blanco, como
 * los iconos de app de Apple (Javier, 2026-11-12).
 *
 * Es todo vectorial (`IconoDeEspecialidad` y CSS, `.directorio-ilustracion`):
 * nítido a cualquier tamaño. Sustituye a los modelos 3D en `.webp`, que se
 * veían pixelados al ampliarse y con aire de juguete.
 *
 * Decorativo: la especialidad ya se lee al lado, en texto. `grande` es el de
 * la ficha del médico y el de las baldosas del home.
 */
export function IlustracionDeEspecialidad({
  clave,
  grande = false,
}: {
  clave: ClaveDeEspecialidad
  grande?: boolean
}) {
  return (
    <span
      aria-hidden
      className={`directorio-ilustracion grid shrink-0 place-items-center text-white ${
        grande ? 'size-20 rounded-[25px] sm:size-24 sm:rounded-[30px]' : 'size-[60px] rounded-[19px]'
      }`}
    >
      <IconoDeEspecialidad
        clave={clave}
        strokeWidth={grande ? 1.5 : 1.7}
        className={`directorio-ilustracion-glifo ${grande ? 'size-10 sm:size-12' : 'size-[30px]'}`}
      />
    </span>
  )
}
