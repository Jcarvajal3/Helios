import { especialidadDeTarjeta } from './directorio'
import type { MedicoDelDirectorio } from './directorio'
import { CLAVES_DE_ESPECIALIDAD, nombreDeEspecialidad } from './especialidades'
import type { ClaveDeEspecialidad } from './especialidades'

// ═══════════════════════════════════════════════════════════════════════════
// Las páginas del directorio que salen en Google (2026-10-30):
//
//   /directorio                     todos los médicos
//   /directorio/<especialidad>      los de una especialidad («odontologia»)
//   /medico/<slug>                  la ficha de un médico («dra-ana-lara»)
//
// Todas se arman solas desde la base: un médico nuevo, o una especialidad
// con su primer médico, ya tiene su página, su sitemap y su JSON-LD. Una
// especialidad sin médicos no tiene página (404) ni sale en el sitemap: una
// página vacía no le sirve a nadie y Google la castiga.
//
// La investigación (docs/03-INVESTIGACION-BUSQUEDAS.md) dice que se busca
// por profesional («ginecólogo caracas») y que nadie cubre «… en cuotas»:
// por eso el título lleva el profesional y «con pago en cuotas». OpenSEO
// (docs/05-OPENSEO.md) midió que lo que tiene volumen es «profesional +
// ciudad» («ginecologo caracas», 590 al mes): el título suma la ciudad de la
// mayoría de sus médicos.
// ═══════════════════════════════════════════════════════════════════════════

/** «medicina_general» → «medicina-general»: la clave, como va en la URL. */
export function segmentoDeEspecialidad(clave: ClaveDeEspecialidad): string {
  return clave.replace(/_/g, '-')
}

/** La clave de un segmento de la URL; `undefined` si no es una especialidad. */
export function claveDeSegmento(segmento: string): ClaveDeEspecialidad | undefined {
  const s = segmento.trim().toLowerCase()
  return CLAVES_DE_ESPECIALIDAD.find((c) => segmentoDeEspecialidad(c) === s)
}

export function rutaDeEspecialidad(clave: ClaveDeEspecialidad): string {
  return `/directorio/${segmentoDeEspecialidad(clave)}`
}

export function rutaDeFicha(slug: string): string {
  return `/medico/${slug}`
}

/**
 * Cómo se llama a quien la ejerce, en plural: lo que se escribe en Google
 * («ginecólogos», «odontólogos»). La que no esté aquí dice «Especialistas en
 * …»: una especialidad nueva funciona sin tocar este archivo.
 */
const PROFESIONALES: Partial<Record<ClaveDeEspecialidad, string>> = {
  medicina_general: 'Médicos generales',
  medicina_interna: 'Médicos internistas',
  pediatria: 'Pediatras',
  ginecologia: 'Ginecólogos',
  traumatologia: 'Traumatólogos',
  cardiologia: 'Cardiólogos',
  dermatologia: 'Dermatólogos',
  oftalmologia: 'Oftalmólogos',
  otorrinolaringologia: 'Otorrinolaringólogos',
  urologia: 'Urólogos',
  gastroenterologia: 'Gastroenterólogos',
  coloproctologia: 'Coloproctólogos',
  neurologia: 'Neurólogos',
  psicologia: 'Psicólogos',
  nutricion: 'Nutricionistas',
  endocrinologia: 'Endocrinólogos',
  neumologia: 'Neumólogos',
  oncologia: 'Oncólogos',
  fisioterapia: 'Fisioterapeutas',
  odontologia: 'Odontólogos',
  cosmetologia: 'Cosmetólogos',
  anatomia_patologica: 'Patólogos',
  angiologia: 'Angiólogos y cirujanos vasculares',
  cirugia_cardiaca: 'Cirujanos cardíacos',
  cirugia_craneofacial: 'Cirujanos craneofaciales',
  cirugia_general: 'Cirujanos generales',
  cirugia_oncologica: 'Cirujanos oncólogos',
  cirugia_maxilofacial: 'Cirujanos maxilofaciales',
  cirugia_pediatrica: 'Cirujanos pediatras',
  cirugia_plastica: 'Cirujanos plásticos',
  cirugia_toracica: 'Cirujanos de tórax',
  hematologia: 'Hematólogos',
  hepatologia: 'Hepatólogos',
  inmunologia: 'Inmunólogos',
  nefrologia: 'Nefrólogos',
  neurocirugia: 'Neurocirujanos',
  ortodoncia: 'Ortodoncistas',
  psiquiatria: 'Psiquiatras',
  radiologia: 'Radiólogos',
  reumatologia: 'Reumatólogos',
}

/** «Ginecólogos», o «Especialistas en Vacunación». */
export function profesionales(clave: ClaveDeEspecialidad): string {
  return PROFESIONALES[clave] ?? `Especialistas en ${nombreDeEspecialidad(clave)}`
}

/**
 * Las especialidades que tienen página: las que tienen al menos un médico
 * publicado, sin «Otras especialidades» (no es algo que se busque), en el
 * orden de la lista.
 */
export function especialidadesConPagina(medicos: readonly MedicoDelDirectorio[]): ClaveDeEspecialidad[] {
  const presentes = new Set(medicos.map((m) => m.clave))
  return CLAVES_DE_ESPECIALIDAD.filter((c) => c !== 'otra' && presentes.has(c))
}

/**
 * La ciudad de más de la mitad de los médicos, tal como la escribe el
 * primero de ellos; `null` si ninguna llega a la mitad. Se compara sin
 * mayúsculas ni espacios de más.
 */
export function ciudadDeLaMayoria(medicos: ReadonlyArray<Pick<MedicoDelDirectorio, 'ciudad'>>): string | null {
  const cuantos = new Map<string, { ciudad: string; n: number }>()
  for (const { ciudad } of medicos) {
    const limpia = ciudad?.trim()
    if (!limpia) continue
    const clave = limpia.toLowerCase()
    const actual = cuantos.get(clave)
    cuantos.set(clave, { ciudad: actual?.ciudad ?? limpia, n: (actual?.n ?? 0) + 1 })
  }
  for (const { ciudad, n } of cuantos.values()) if (n * 2 > medicos.length) return ciudad
  return null
}

/**
 * Los textos de `/directorio/<especialidad>`. Con `ciudad`, el título dice
 * «Ginecólogos en Caracas con pago en cuotas»: lo que se busca.
 */
export function textosDeEspecialidad(clave: ClaveDeEspecialidad, ciudad: string | null = null) {
  const quienes = profesionales(clave)
  return {
    /** Hasta ~60 caracteres: lo que se busca delante, la marca detrás. */
    titulo: ciudad
      ? `${quienes} en ${ciudad} con pago en cuotas | Helios`
      : `${quienes} con pago en cuotas, sin inicial | Helios`,
    descripcion: `${quienes} que aceptan Helios en Venezuela. Escríbeles por WhatsApp y paga tu consulta en 2 cuotas, a los 7 y 14 días, sin inicial.`,
    h1: { antes: quienes, enfasis: 'con 0% de inicial.' },
    entrada: `${nombreDeEspecialidad(clave)}: escríbele por WhatsApp a tu especialista y paga tu consulta en 2 cuotas, a los 7 y 14 días.`,
    miga: nombreDeEspecialidad(clave),
  }
}

/**
 * La guía del pago en cuotas que más se parece a una especialidad: las dos
 * con guía propia y, las demás, la de la consulta médica. Enlazan en los dos
 * sentidos (la guía al directorio y el directorio a la guía).
 */
export function guiaDeEspecialidad(clave: ClaveDeEspecialidad): { ruta: string; texto: string } {
  if (clave === 'odontologia') return { ruta: '/odontologia-en-cuotas', texto: 'Odontología en cuotas' }
  if (clave === 'cosmetologia') return { ruta: '/cosmetologia-en-cuotas', texto: 'Cosmetología en cuotas' }
  return { ruta: '/consulta-medica-en-cuotas', texto: 'Consulta médica en cuotas' }
}

/** «Dra. Ana Lara · Odontología · Caracas»: lo que se lee del médico en una línea. */
export function resumenDelMedico(m: MedicoDelDirectorio): string {
  return [m.nombre, especialidadDeTarjeta(m), m.ciudad].filter(Boolean).join(' · ')
}

/** Los textos de `/medico/<slug>`. */
export function textosDeFicha(m: MedicoDelDirectorio) {
  const especialidad = especialidadDeTarjeta(m) ?? nombreDeEspecialidad(m.clave)
  const donde = m.ciudad ? ` en ${m.ciudad}` : ''
  return {
    titulo: `${m.nombre}, ${especialidad} | Pago en cuotas con Helios`,
    descripcion: `${m.nombre}, ${especialidad.toLowerCase()}${donde}. Agenda tu cita por WhatsApp y paga tu consulta en 2 cuotas, a los 7 y 14 días, sin inicial.`,
    especialidad,
  }
}

/**
 * Hasta `n` médicos de la misma especialidad, sin él: los enlaces de «Otros
 * especialistas» de la ficha (enlazado interno, y otra opción para el
 * paciente).
 */
export function otrosDeLaEspecialidad(
  m: MedicoDelDirectorio,
  medicos: readonly MedicoDelDirectorio[],
  n = 6,
): MedicoDelDirectorio[] {
  return medicos.filter((o) => o.clave === m.clave && o.id !== m.id && o.slug).slice(0, n)
}

/** Un enlace de Google Maps que busca la dirección tal cual la escribió el médico. */
export function enlaceDeMapa(m: Pick<MedicoDelDirectorio, 'direccion' | 'ciudad'>): string | null {
  const consulta = [m.direccion, m.ciudad, 'Venezuela'].filter(Boolean).join(', ')
  if (!m.direccion) return null
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(consulta)}`
}

/** La fecha (`YYYY-MM-DD`) del cambio más reciente: el `lastmod` de una página con varios médicos. */
export function ultimoCambio(fechas: ReadonlyArray<string | null>): string | undefined {
  const validas = fechas.filter((f): f is string => !!f).sort()
  return validas.at(-1)?.slice(0, 10)
}

/**
 * Todas las páginas públicas que se ofrecen a los buscadores, con la fecha
 * de su último cambio: las fijas (`PAGINAS_PUBLICAS` de `config/sitio.ts`,
 * que se pasan), una por especialidad con médicos y una por médico
 * publicado. La usan el sitemap y el aviso a IndexNow.
 */
export function paginasPublicas(
  fijasPorRuta: Readonly<Record<string, { actualizada: string }>>,
  medicos: readonly MedicoDelDirectorio[],
): Array<{ ruta: string; actualizada?: string }> {
  const fijas = Object.entries(fijasPorRuta).map(([ruta, { actualizada }]) => ({ ruta, actualizada }))
  const especialidades = especialidadesConPagina(medicos).map((clave) => ({
    ruta: rutaDeEspecialidad(clave),
    actualizada: ultimoCambio(medicos.filter((m) => m.clave === clave).map((m) => m.actualizado)),
  }))
  const fichas = medicos
    .filter((m): m is MedicoDelDirectorio & { slug: string } => !!m.slug)
    .map((m) => ({ ruta: rutaDeFicha(m.slug), actualizada: m.actualizado?.slice(0, 10) }))
    .sort((a, b) => a.ruta.localeCompare(b.ruta))
  return [...fijas, ...especialidades, ...fichas]
}
