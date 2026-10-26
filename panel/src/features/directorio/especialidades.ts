// ═══════════════════════════════════════════════════════════════════════════
// Las especialidades del directorio de médicos: el filtro de `/directorio` y
// el icono de cada tarjeta.
//
// Es la lista cerrada de `helios_directorio_especialidades()` (migración
// 20261026190000), en el mismo orden. Una clave que solo exista aquí es una
// tarjeta que la base rechaza; una que solo exista allí cae en «Otras
// especialidades». El icono de cada una vive en
// `components/directorio/IconoDeEspecialidad.tsx`.
// ═══════════════════════════════════════════════════════════════════════════

export const ESPECIALIDADES = [
  { clave: 'medicina_general', nombre: 'Medicina general' },
  { clave: 'medicina_interna', nombre: 'Medicina interna' },
  { clave: 'pediatria', nombre: 'Pediatría' },
  { clave: 'ginecologia', nombre: 'Ginecología y obstetricia' },
  { clave: 'traumatologia', nombre: 'Traumatología' },
  { clave: 'cardiologia', nombre: 'Cardiología' },
  { clave: 'dermatologia', nombre: 'Dermatología' },
  { clave: 'oftalmologia', nombre: 'Oftalmología' },
  { clave: 'otorrinolaringologia', nombre: 'Otorrinolaringología' },
  { clave: 'urologia', nombre: 'Urología' },
  { clave: 'gastroenterologia', nombre: 'Gastroenterología' },
  { clave: 'coloproctologia', nombre: 'Coloproctología' },
  { clave: 'neurologia', nombre: 'Neurología' },
  { clave: 'psicologia', nombre: 'Psicología y psiquiatría' },
  { clave: 'nutricion', nombre: 'Nutrición' },
  { clave: 'endocrinologia', nombre: 'Endocrinología' },
  { clave: 'neumologia', nombre: 'Neumología' },
  { clave: 'oncologia', nombre: 'Oncología' },
  { clave: 'fisioterapia', nombre: 'Fisioterapia' },
  { clave: 'enfermeria', nombre: 'Enfermería' },
  { clave: 'odontologia', nombre: 'Odontología' },
  { clave: 'cosmetologia', nombre: 'Cosmetología y estética' },
  { clave: 'otra', nombre: 'Otras especialidades' },
] as const

export type ClaveDeEspecialidad = (typeof ESPECIALIDADES)[number]['clave']

export const CLAVES_DE_ESPECIALIDAD: readonly ClaveDeEspecialidad[] = ESPECIALIDADES.map((e) => e.clave)

const NOMBRES = Object.fromEntries(ESPECIALIDADES.map((e) => [e.clave, e.nombre])) as Record<
  ClaveDeEspecialidad,
  string
>

export function nombreDeEspecialidad(clave: ClaveDeEspecialidad): string {
  return NOMBRES[clave]
}

/** La clave tal cual llega de la base; una que el panel no conoce es «otra». */
export function leerEspecialidad(v: unknown): ClaveDeEspecialidad {
  return CLAVES_DE_ESPECIALIDAD.find((c) => c === v) ?? 'otra'
}
