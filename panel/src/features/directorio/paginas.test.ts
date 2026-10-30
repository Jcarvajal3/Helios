/**
 * Pruebas de las páginas del directorio y del origen de las visitas.
 *
 *   npx tsx src/features/directorio/paginas.test.ts
 *
 * Lo que se vigila: que cada especialidad tenga su URL y vuelva de ella, que
 * solo tengan página las que tienen médicos (y nunca «Otras»), que el
 * sitemap traiga una página por especialidad y por médico, que la fuente de
 * una visita se reconozca (Gemini antes que Google; la `utm_source` de
 * ChatGPT antes que el dominio) y que nada raro de la URL pase tal cual.
 */
import { leerDirectorio } from './directorio'
import { dominioDe, fuenteDeLaVisita, leerLlegada } from './origen'
import {
  ciudadDeLaMayoria,
  claveDeSegmento,
  enlaceDeMapa,
  especialidadesConPagina,
  guiaDeEspecialidad,
  otrosDeLaEspecialidad,
  paginasPublicas,
  profesionales,
  rutaDeEspecialidad,
  rutaDeFicha,
  textosDeEspecialidad,
  ultimoCambio,
} from './paginas'
import { CLAVES_DE_ESPECIALIDAD } from './especialidades'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle: unknown = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${JSON.stringify(detalle)}`}`)
}

const medicos = leerDirectorio([
  {
    merchant_id: 'm1',
    name: 'Dra. Ana Lara',
    specialty: 'Odontóloga',
    specialty_key: 'odontologia',
    address: 'Av. Lara, Torre Médica',
    city: 'Caracas',
    whatsapp: '+584141234567',
    slug: 'dra-ana-lara',
    updated_at: '2026-10-28T15:00:00Z',
  },
  {
    merchant_id: 'm2',
    name: 'Dr. Luis Pérez',
    specialty: null,
    specialty_key: 'odontologia',
    address: null,
    city: null,
    whatsapp: '+584141234568',
    slug: 'dr-luis-perez',
    updated_at: '2026-10-30T09:00:00Z',
  },
  {
    merchant_id: 'm3',
    name: 'Lcda. Eva Ríos',
    specialty: 'Acupuntura',
    specialty_key: 'otra',
    whatsapp: '+584141234569',
    slug: 'lcda-eva-rios',
    updated_at: null,
  },
  {
    merchant_id: 'm4',
    name: 'Dr. Sin Enlace',
    specialty_key: 'medicina_general',
    whatsapp: '+584141234570',
  },
])

console.log('── Las URL de cada especialidad ──────────────────────────────')
comprueba(rutaDeEspecialidad('medicina_general') === '/directorio/medicina-general', 'la clave va con guiones')
comprueba(
  CLAVES_DE_ESPECIALIDAD.every((c) => claveDeSegmento(rutaDeEspecialidad(c).split('/').at(-1) ?? '') === c),
  'cada especialidad vuelve de su URL',
)
comprueba(claveDeSegmento('Odontologia') === 'odontologia', 'sin importar mayúsculas')
comprueba(claveDeSegmento('dentista') === undefined, 'lo que no es especialidad no es nada')
comprueba(rutaDeFicha('dra-ana-lara') === '/medico/dra-ana-lara', 'la ficha va en /medico')

console.log('── Qué especialidades tienen página ──────────────────────────')
const conPagina = especialidadesConPagina(medicos)
comprueba(conPagina.includes('odontologia') && conPagina.includes('medicina_general'), 'las que tienen médicos', conPagina)
comprueba(!conPagina.includes('otra'), '«Otras especialidades» no tiene página en Google')
comprueba(!conPagina.includes('cardiologia'), 'sin médicos, sin página')
comprueba(profesionales('ginecologia') === 'Ginecólogos', 'el profesional en plural')
comprueba(profesionales('vacunacion') === 'Especialistas en Vacunación', 'sin nombre propio, «Especialistas en…»')
comprueba(textosDeEspecialidad('odontologia').titulo.length <= 60, 'el título cabe en el resultado de Google')
comprueba(
  textosDeEspecialidad('ginecologia', 'Caracas').titulo === 'Ginecólogos en Caracas con pago en cuotas | Helios',
  'con ciudad, el título dice dónde',
  textosDeEspecialidad('ginecologia', 'Caracas').titulo,
)
comprueba(
  textosDeEspecialidad('otorrinolaringologia', 'Caracas').titulo.length <= 60,
  'el más largo, con ciudad, también cabe',
)
const enCiudad = (...ciudades: (string | null)[]) => ciudadDeLaMayoria(ciudades.map((ciudad) => ({ ciudad })))
comprueba(enCiudad('Caracas', ' caracas ', 'Caracas', 'Caracas', 'Caracas', 'Los Teques') === 'Caracas', 'la ciudad de la mayoría')
comprueba(enCiudad('Caracas', 'Valencia') === null, 'empate: sin ciudad')
comprueba(enCiudad('Caracas', null, null) === null, 'los que no tienen ciudad cuentan como otra')
comprueba(enCiudad() === null, 'sin médicos, sin ciudad')
comprueba(guiaDeEspecialidad('odontologia').ruta === '/odontologia-en-cuotas', 'odontología enlaza a su guía')
comprueba(guiaDeEspecialidad('pediatria').ruta === '/consulta-medica-en-cuotas', 'las demás, a la consulta médica')

console.log('── La ficha ──────────────────────────────────────────────────')
const [ana, luis] = medicos
comprueba(
  otrosDeLaEspecialidad(ana, medicos).map((m) => m.id).join() === luis.id,
  'otros de la especialidad: sin él y con enlace',
)
comprueba(
  enlaceDeMapa(ana) === 'https://www.google.com/maps/search/?api=1&query=Av.%20Lara%2C%20Torre%20M%C3%A9dica%2C%20Caracas%2C%20Venezuela',
  'el mapa busca la dirección tal cual',
  enlaceDeMapa(ana),
)
comprueba(enlaceDeMapa(luis) === null, 'sin dirección, sin mapa')

console.log('── El sitemap ────────────────────────────────────────────────')
const FIJAS = { '/': { actualizada: '2026-10-30' }, '/directorio': { actualizada: '2026-10-30' } }
const paginas = paginasPublicas(FIJAS, medicos)
const rutas = paginas.map((p) => p.ruta)
comprueba(rutas.includes('/') && rutas.includes('/directorio'), 'las fijas siguen')
comprueba(rutas.includes('/directorio/odontologia'), 'una por especialidad con médicos')
comprueba(!rutas.includes('/directorio/otra'), '«Otras» no va')
comprueba(rutas.includes('/medico/dra-ana-lara') && rutas.includes('/medico/lcda-eva-rios'), 'una por médico con enlace')
comprueba(!rutas.some((r) => r.includes('sin-enlace')), 'sin enlace, sin ficha')
comprueba(
  paginas.find((p) => p.ruta === '/directorio/odontologia')?.actualizada === '2026-10-30',
  'la especialidad lleva el cambio más reciente de sus médicos',
)
comprueba(new Set(rutas).size === rutas.length, 'ninguna ruta repetida')
comprueba(ultimoCambio([null, null]) === undefined, 'sin fechas, sin lastmod')

console.log('── De dónde llegó la visita ──────────────────────────────────')
comprueba(fuenteDeLaVisita('google.com', null) === 'google', 'Google')
comprueba(fuenteDeLaVisita('google.co.ve', null) === 'google', 'Google Venezuela')
comprueba(fuenteDeLaVisita('gemini.google.com', null) === 'gemini', 'Gemini antes que Google')
comprueba(fuenteDeLaVisita('copilot.microsoft.com', null) === 'copilot', 'Copilot')
comprueba(fuenteDeLaVisita('bing.com', null) === 'bing', 'Bing')
comprueba(fuenteDeLaVisita('perplexity.ai', null) === 'perplexity', 'Perplexity')
comprueba(fuenteDeLaVisita('l.instagram.com', null) === 'instagram', 'Instagram')
comprueba(fuenteDeLaVisita(null, 'chatgpt.com') === 'chatgpt', 'la utm_source de ChatGPT')
comprueba(fuenteDeLaVisita('google.com', 'Boletín Octubre') === 'bolet-n-octubre', 'una utm propia manda, limpia')
comprueba(fuenteDeLaVisita(null, null) === 'directo', 'sin nada, directo')
comprueba(fuenteDeLaVisita('ejemplo.com', null) === 'otro', 'una web cualquiera, otro')
comprueba(dominioDe('https://www.Google.com/search?q=odontologo') === 'google.com', 'solo el dominio, sin www')
comprueba(dominioDe('no es una url') === null, 'un referrer roto no se guarda')

const llegada = leerLlegada(
  new URL('https://conhelios.com/directorio/odontologia?utm_source=chatgpt.com&utm_medium=x'),
  '',
)
comprueba(
  llegada.fuente === 'chatgpt' && llegada.entrada === '/directorio/odontologia' && llegada.utm_medium === 'x',
  'la llegada desde ChatGPT, con su página de entrada',
  llegada,
)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
