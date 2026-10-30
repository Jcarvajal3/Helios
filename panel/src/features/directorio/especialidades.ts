// ═══════════════════════════════════════════════════════════════════════════
// Las especialidades del directorio de médicos: el filtro de `/directorio`,
// el icono de cada tarjeta y el desplegable de la especialidad en
// `/afiliacion`.
//
// Es la lista cerrada de `helios_directorio_especialidades()` (migración
// 20261030100000), en el mismo orden: por nombre y «Otras especialidades» al
// final. Una clave que solo exista aquí es una tarjeta que la base rechaza;
// una que solo exista allí cae en «Otras especialidades». El icono de cada
// una vive en `components/directorio/IconoDeEspecialidad.tsx`.
//
// `busca` son otras formas de decirla («dentista», «ojos», «ginecólogo»): el
// buscador del desplegable las entiende, pero no se enseñan.
// ═══════════════════════════════════════════════════════════════════════════

export const ESPECIALIDADES = [
  { clave: 'anatomia_patologica', nombre: 'Anatomía patológica', busca: ['patólogo', 'biopsia'] },
  { clave: 'angiologia', nombre: 'Angiología y cirugía vascular', busca: ['angiólogo', 'cirujano vascular', 'várices'] },
  { clave: 'cardiologia', nombre: 'Cardiología', busca: ['cardiólogo', 'corazón'] },
  { clave: 'cirugia_cardiaca', nombre: 'Cirugía cardíaca', busca: ['cirugía cardiovascular', 'cirujano cardiovascular'] },
  { clave: 'cirugia_craneofacial', nombre: 'Cirugía craneofacial', busca: ['cirujano craneofacial'] },
  { clave: 'cirugia_general', nombre: 'Cirugía general', busca: ['cirujano general'] },
  { clave: 'cirugia_oncologica', nombre: 'Cirugía oncológica', busca: ['cirujano oncólogo'] },
  { clave: 'cirugia_maxilofacial', nombre: 'Cirugía oral y maxilofacial', busca: ['cirujano maxilofacial', 'cirugía bucal'] },
  { clave: 'cirugia_pediatrica', nombre: 'Cirugía pediátrica', busca: ['cirujano pediatra'] },
  { clave: 'cirugia_plastica', nombre: 'Cirugía plástica y reconstructiva', busca: ['cirujano plástico', 'cirugía estética'] },
  { clave: 'cirugia_toracica', nombre: 'Cirugía torácica', busca: ['cirujano de tórax'] },
  { clave: 'coloproctologia', nombre: 'Coloproctología', busca: ['proctólogo', 'proctología', 'colon'] },
  { clave: 'cosmetologia', nombre: 'Cosmetología y estética', busca: ['cosmetóloga', 'belleza'] },
  { clave: 'dermatologia', nombre: 'Dermatología', busca: ['dermatólogo', 'piel'] },
  { clave: 'endocrinologia', nombre: 'Endocrinología', busca: ['endocrinólogo', 'diabetes', 'tiroides'] },
  { clave: 'enfermeria', nombre: 'Enfermería', busca: ['enfermera'] },
  { clave: 'fisioterapia', nombre: 'Fisioterapia', busca: ['fisioterapeuta', 'fisiatría', 'rehabilitación'] },
  { clave: 'gastroenterologia', nombre: 'Gastroenterología', busca: ['gastroenterólogo', 'digestivo', 'estómago'] },
  { clave: 'ginecologia', nombre: 'Ginecología y obstetricia', busca: ['ginecólogo', 'obstetra', 'embarazo'] },
  { clave: 'hematologia', nombre: 'Hematología', busca: ['hematólogo', 'sangre'] },
  { clave: 'hepatologia', nombre: 'Hepatología', busca: ['hepatólogo', 'hígado'] },
  { clave: 'inmunologia', nombre: 'Inmunología', busca: ['inmunólogo', 'alergias', 'alergología'] },
  { clave: 'medicina_general', nombre: 'Medicina general', busca: ['médico general', 'medicina familiar'] },
  { clave: 'medicina_interna', nombre: 'Medicina interna', busca: ['internista'] },
  { clave: 'nefrologia', nombre: 'Nefrología', busca: ['nefrólogo', 'riñones'] },
  { clave: 'neumologia', nombre: 'Neumología', busca: ['neumólogo', 'neumonología', 'pulmones'] },
  { clave: 'neurocirugia', nombre: 'Neurocirugía', busca: ['neurocirujano'] },
  { clave: 'neurologia', nombre: 'Neurología', busca: ['neurólogo'] },
  { clave: 'nutricion', nombre: 'Nutrición', busca: ['nutriología', 'nutricionista', 'nutrólogo'] },
  { clave: 'odontologia', nombre: 'Odontología', busca: ['odontólogo', 'dentista', 'dientes'] },
  { clave: 'oftalmologia', nombre: 'Oftalmología', busca: ['oftalmólogo', 'ojos', 'optometría'] },
  { clave: 'oncologia', nombre: 'Oncología', busca: ['oncólogo', 'cáncer'] },
  { clave: 'ortodoncia', nombre: 'Ortodoncia', busca: ['ortodoncista', 'brackets'] },
  { clave: 'otorrinolaringologia', nombre: 'Otorrinolaringología', busca: ['otorrino', 'oído', 'garganta'] },
  { clave: 'pediatria', nombre: 'Pediatría', busca: ['pediatra', 'niños'] },
  { clave: 'psicologia', nombre: 'Psicología', busca: ['psicólogo', 'terapia'] },
  { clave: 'psiquiatria', nombre: 'Psiquiatría', busca: ['psiquiatra'] },
  { clave: 'radiologia', nombre: 'Radiodiagnóstico (imágenes)', busca: ['radiología', 'radiólogo', 'ecografía', 'rayos x', 'tomografía'] },
  { clave: 'reumatologia', nombre: 'Reumatología', busca: ['reumatólogo'] },
  { clave: 'traumatologia', nombre: 'Traumatología y ortopedia', busca: ['traumatólogo', 'cirugía ortopédica', 'cadera', 'rodilla', 'huesos'] },
  { clave: 'urologia', nombre: 'Urología', busca: ['urólogo', 'próstata'] },
  { clave: 'vacunacion', nombre: 'Vacunación', busca: ['vacunas'] },
  { clave: 'otra', nombre: 'Otras especialidades', busca: [] },
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
