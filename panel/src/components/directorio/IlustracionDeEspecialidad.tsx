import type { ClaveDeEspecialidad } from '@/features/directorio/especialidades'

/**
 * El icono 3D de cada especialidad, el de la tarjeta del directorio. Los
 * modela `scripts/iconos-3d/` y viven en `public/images/especialidades/`.
 *
 * Las que aún no tienen el suyo usan el de la más cercana y, si no hay
 * ninguna, `general` (la cruz médica): así ninguna tarjeta cambia de estilo.
 */
const IMAGEN: Partial<Record<ClaveDeEspecialidad, string>> = {
  angiologia: 'cardiologia',
  cardiologia: 'cardiologia',
  cirugia_cardiaca: 'cardiologia',
  cirugia_maxilofacial: 'odontologia',
  cirugia_pediatrica: 'pediatria',
  coloproctologia: 'gastroenterologia',
  cosmetologia: 'cosmetologia',
  dermatologia: 'dermatologia',
  fisioterapia: 'traumatologia',
  gastroenterologia: 'gastroenterologia',
  ginecologia: 'ginecologia',
  hepatologia: 'gastroenterologia',
  medicina_general: 'medicina_general',
  medicina_interna: 'medicina_interna',
  nefrologia: 'urologia',
  nutricion: 'nutricion',
  odontologia: 'odontologia',
  oftalmologia: 'oftalmologia',
  ortodoncia: 'odontologia',
  otorrinolaringologia: 'otorrinolaringologia',
  pediatria: 'pediatria',
  psicologia: 'psicologia',
  psiquiatria: 'psicologia',
  reumatologia: 'traumatologia',
  traumatologia: 'traumatologia',
  urologia: 'urologia',
  vacunacion: 'vacunacion',
}

/** La dirección del icono de una especialidad. */
export function imagenDeEspecialidad(clave: ClaveDeEspecialidad): string {
  return `/images/especialidades/${IMAGEN[clave] ?? 'general'}.webp`
}

/** Decorativo: la especialidad ya se lee al lado, en texto. */
export function IlustracionDeEspecialidad({ clave }: { clave: ClaveDeEspecialidad }) {
  return (
    <span className="directorio-ilustracion grid size-14 shrink-0 place-items-center rounded-[18px] sm:size-16">
      <img
        src={imagenDeEspecialidad(clave)}
        alt=""
        width={192}
        height={192}
        loading="lazy"
        decoding="async"
        className="size-[52px] sm:size-[60px]"
      />
    </span>
  )
}
