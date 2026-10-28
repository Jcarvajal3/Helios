/**
 * Pruebas del directorio de médicos (la página pública y la pestaña).
 *
 *   npx tsx src/features/directorio/directorio.test.ts
 *
 * Lo que se vigila: que se lea lo que manda la base, que la búsqueda no
 * dependa de tildes ni del orden de las palabras, que el filtro solo ofrezca
 * especialidades con médicos, que el enlace de WhatsApp lleve el número y el
 * mensaje, y que el borrador de la pestaña mande solo lo que cambió (vacío =
 * el de la ficha).
 */
import {
  enlaceDeRed,
  enlaceDeWhatsApp,
  especialidadDeTarjeta,
  leerRed,
  especialidadesPresentes,
  fichasQueCaben,
  filtrarDirectorio,
  leerDirectorio,
  lugarDeTarjeta,
  mensajeAHelios,
} from './directorio'
import { CLAVES_DE_ESPECIALIDAD, leerEspecialidad } from './especialidades'
import {
  borradorDe,
  cambiosDelBorrador,
  comoTarjetaPublica,
  datosDelBorrador,
  filtrarInteresados,
  filtrarMedicos,
  leerInteresados,
  leerTablero,
  motivoParaNoGuardar,
  parteDe,
  rotuloDelInteresado,
  whatsappE164,
} from '@/features/admin/directorioDeMedicos/directorioDeMedicos'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle: unknown = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${JSON.stringify(detalle)}`}`)
}

console.log('── Leer helios_directorio() ──────────────────────────────────')
const medicos = leerDirectorio([
  {
    merchant_id: 'm1',
    name: 'Dra. Nadia Khabbaze',
    specialty: 'Odontóloga',
    specialty_key: 'odontologia',
    address: 'Av. Lara, Torre Médica, Barquisimeto',
    city: 'Barquisimeto',
    whatsapp: '+584141234567',
    lead_code: 'DIR-7K2P',
  },
  {
    merchant_id: 'm2',
    name: 'Dr. Jesús Contreras',
    specialty: null,
    specialty_key: 'medicina_interna',
    address: 'Centro Médico La Trinidad',
    city: 'Caracas',
    whatsapp: '+584241112233',
    lead_code: null,
  },
  {
    merchant_id: 'm3',
    name: 'Dr. Carlos Hafouri',
    specialty: 'Proctólogo',
    specialty_key: 'una_que_no_existe',
    address: null,
    city: null,
    whatsapp: '+584125556677',
  },
  { merchant_id: 'm4', name: 'Sin WhatsApp', specialty_key: 'pediatria', whatsapp: null },
])
comprueba(medicos.length === 3, 'una fila sin WhatsApp no entra', medicos)
comprueba(medicos[2]?.clave === 'otra', 'una clave desconocida es «otra»', medicos[2])
comprueba(medicos[0]?.codigo === 'DIR-7K2P', 'lee el código de la tarjeta (lead_code)', medicos[0])
comprueba(medicos[1]?.codigo === null, 'lead_code null → sin código', medicos[1])
comprueba(medicos[2]?.codigo === null, 'sin lead_code (datos viejos) → sin código', medicos[2])
comprueba(leerEspecialidad('pediatria') === 'pediatria', 'una clave conocida se queda')
comprueba(CLAVES_DE_ESPECIALIDAD.length === 24, 'son las 24 claves de la base', CLAVES_DE_ESPECIALIDAD.length)
comprueba(leerEspecialidad('vacunacion') === 'vacunacion', 'Vacunación es una categoría propia')
comprueba(CLAVES_DE_ESPECIALIDAD.at(-1) === 'otra', '«Otras» sigue al final')

console.log('── La tarjeta ────────────────────────────────────────────────')
const [nadia, jesus, carlos] = medicos
comprueba(especialidadDeTarjeta(nadia) === 'Odontóloga', 'con texto propio, el texto')
comprueba(especialidadDeTarjeta(jesus) === 'Medicina interna', 'sin texto, el nombre de la especialidad')
comprueba(especialidadDeTarjeta({ especialidad: null, clave: 'otra' }) === null, '«otra» sin texto no dice nada')
comprueba(lugarDeTarjeta(nadia) === 'Av. Lara, Torre Médica, Barquisimeto', 'la ciudad no se repite si ya va en la dirección')
comprueba(lugarDeTarjeta(jesus) === 'Centro Médico La Trinidad · Caracas', 'dirección y ciudad')
comprueba(lugarDeTarjeta(carlos) === null, 'sin dirección ni ciudad, nada')

console.log('── El enlace de WhatsApp ─────────────────────────────────────')
const enlace = enlaceDeWhatsApp(nadia)
comprueba(enlace.startsWith('https://wa.me/584141234567?text='), 'wa.me con el 58 y sin el +', enlace)
comprueba(
  decodeURIComponent(enlace.split('text=')[1] ?? '') ===
    'Hola, Dra. Nadia Khabbaze. Vi su perfil en el directorio de Helios y quisiera agendar una consulta.',
  'el mensaje dice de dónde viene el paciente',
  enlace,
)
comprueba(enlace === enlaceDeWhatsApp(nadia, null), 'sin número de Helios, directo al médico', enlace)

const HELIOS = '+584221234567'
const aHelios = enlaceDeWhatsApp(nadia, HELIOS)
comprueba(aHelios.startsWith('https://wa.me/584221234567?text='), 'con número y código, el chat de Helios', aHelios)
comprueba(
  decodeURIComponent(aHelios.split('text=')[1] ?? '') ===
    'Hola, quiero agendar una consulta con Dra. Nadia Khabbaze. (Código DIR-7K2P)',
  'el mensaje a Helios lleva el nombre y el código',
  aHelios,
)
comprueba(
  mensajeAHelios(' Dra. Ana Pérez ', 'DIR-AB12') === 'Hola, quiero agendar una consulta con Dra. Ana Pérez. (Código DIR-AB12)',
  'mensajeAHelios lleva el código',
)
const sinCodigo = enlaceDeWhatsApp(jesus, HELIOS)
comprueba(sinCodigo.startsWith('https://wa.me/584241112233?text='), 'sin código, directo al médico aunque haya número', sinCodigo)
comprueba(
  enlaceDeWhatsApp({ ...nadia, codigo: '  ' }, HELIOS).startsWith('https://wa.me/584141234567?text='),
  'un código en blanco cuenta como sin código',
)
comprueba(
  enlaceDeWhatsApp(nadia, '').startsWith('https://wa.me/584141234567?text='),
  'un número de Helios vacío cuenta como sin número',
)

console.log('── La red social ─────────────────────────────────────────────')
const red = (r: string | null, u: string | null) =>
  enlaceDeRed({ red: leerRed(r), usuarioDeRed: u })
comprueba(red(null, null) === null, 'sin red, nada')
comprueba(red('instagram', '  ') === null, 'sin usuario, nada')
comprueba(
  JSON.stringify(red('instagram', '@draperez')) ===
    JSON.stringify({ url: 'https://www.instagram.com/draperez', texto: '@draperez', red: 'Instagram' }),
  'Instagram con @',
  red('instagram', '@draperez'),
)
comprueba(red('tiktok', 'dra.perez')?.url === 'https://www.tiktok.com/@dra.perez', 'TikTok lleva la @ en la ruta')
comprueba(red('x', 'draperez')?.red === 'X', 'X sin «(Twitter)»', red('x', 'draperez'))
comprueba(red('linkedin', 'ana-perez')?.url === 'https://www.linkedin.com/in/ana-perez', 'LinkedIn va a /in/')
comprueba(
  red('instagram', 'instagram.com/draperez/')?.url === 'https://instagram.com/draperez/' &&
    red('instagram', 'instagram.com/draperez/')?.texto === '@draperez',
  'un enlace sin https se completa y se lee como usuario',
  red('instagram', 'instagram.com/draperez/'),
)
comprueba(red('otra', 'https://linktr.ee/draperez')?.url === 'https://linktr.ee/draperez', '«Otra» con enlace, sí')
comprueba(red('otra', 'draperez') === null, '«Otra» sin enlace no se sabe adónde va')
comprueba(red('instagram', 'javascript:alert(1)') === null, 'nada que no sea https llega al enlace')
comprueba(red('instagram', 'Dra Ana Pérez') === null, 'un nombre con espacios no es un usuario')
comprueba(red('mastodon', 'draperez') === null, 'una red que el panel no conoce, nada')

console.log('── Buscar y filtrar ──────────────────────────────────────────')
const ids = (l: Array<{ id: string }>) => l.map((m) => m.id).join(',')
comprueba(ids(filtrarDirectorio(medicos, {})) === 'm1,m2,m3', 'sin filtros, todos')
comprueba(ids(filtrarDirectorio(medicos, { q: 'JESUS' })) === 'm2', 'sin tildes ni mayúsculas')
comprueba(ids(filtrarDirectorio(medicos, { q: 'barquisimeto odonto' })) === 'm1', 'palabras en cualquier orden')
comprueba(ids(filtrarDirectorio(medicos, { q: 'interna' })) === 'm2', 'busca en el nombre de la especialidad')
comprueba(ids(filtrarDirectorio(medicos, { q: 'trinidad caracas' })) === 'm2', 'busca en dirección y ciudad')
comprueba(ids(filtrarDirectorio(medicos, { especialidad: 'odontologia' })) === 'm1', 'por especialidad')
comprueba(ids(filtrarDirectorio(medicos, { q: 'jesus', especialidad: 'odontologia' })) === '', 'las dos a la vez')
comprueba(ids(filtrarDirectorio(medicos, { q: '   ' })) === 'm1,m2,m3', 'espacios no filtran')

const presentes = especialidadesPresentes([...medicos, { ...nadia, id: 'm5' }])
comprueba(
  presentes.map((e) => `${e.clave}:${e.cuantos}`).join(',') === 'odontologia:2,medicina_interna:1,otra:1',
  'la de más médicos primero y «otra» al final',
  presentes,
)

console.log('── Las fichas de especialidad: cuántas caben ─────────────────')
// 300 px de ancho, 8 de hueco: caben dos de 140 por fila.
const caben = (anchos: number[], filas: number) => fichasQueCaben(anchos, { ancho: 300, hueco: 8, filas, verMas: 100 })
comprueba(caben([140, 140, 140], 2) === 3, 'si caben todas, todas (sin «Ver más»)')
comprueba(caben([140, 140, 140, 140, 140], 2) === 3, 'deja sitio a «Ver más» en la última fila')
comprueba(caben([140, 140, 140, 140, 140], 3) === 5, 'con una fila más, caben todas')
comprueba(caben([300, 300, 300], 1) === 1, '«Todas» se enseña siempre')
comprueba(caben([146.2, 146.2], 1) === 2, 'el redondeo de medio píxel no tumba una ficha')

console.log('── La pestaña: leer admin_directorio() ───────────────────────')
const tablero = leerTablero({
  hoy: '2026-10-26',
  desde: '2026-09-27',
  totales: { clics_total: 9, clics_7d: 4, clics_30d: 7, clics_30d_anteriores: 2, visitantes_30d: 5, medicos_contactados_30d: 2 },
  por_dia: [{ dia: '2026-10-26', clics: 3, visitantes: 2 }],
  medicos: [
    {
      merchant_id: 'm1',
      clinic_name: 'Consultorio Khabbaze',
      status: 'active',
      is_test: false,
      is_visible: true,
      blocked_reason: null,
      listing: { name: 'Dra. Nadia Khabbaze', specialty: 'Odontóloga', specialty_key: 'odontologia', address: 'Av. Lara', city: null, whatsapp: '+584141234567' },
      base: { name: 'Dra. Nadia Andi Khabbaze Alfaro', specialty: 'Odontóloga', specialty_key: 'odontologia', address: 'Av. Lara', city: null, whatsapp: '+584141234567' },
      clics: { total: 9, d7: 4, d30: 7, visitantes_30d: 5, ultimo: '2026-10-26T15:00:00Z', por_dia: [0, 1, 3] },
    },
    {
      merchant_id: 'demo',
      clinic_name: 'Consultorio DEMO',
      status: 'active',
      is_test: true,
      is_visible: false,
      blocked_reason: 'prueba',
      listing: { name: 'Consultorio DEMO', specialty_key: 'medicina_general' },
      base: { name: 'Consultorio DEMO', specialty_key: 'medicina_general' },
      clics: {},
    },
  ],
})
const m1 = tablero.medicos[0]
comprueba(tablero.totales.clics30d === 7 && tablero.porDia.length === 1, 'los totales y los días')
comprueba(m1.clics.porDia.join(',') === '0,1,3' && m1.clics.visitantes30d === 5, 'los clics del médico')
comprueba(tablero.medicos[1]?.bloqueo === 'prueba' && tablero.medicos[1].clics.total === 0, 'el bloqueo y los clics vacíos')
comprueba(ids(filtrarMedicos(tablero.medicos, { ver: 'visibles' })) === 'm1', 'visibles')
comprueba(ids(filtrarMedicos(tablero.medicos, { ver: 'ocultos' })) === '', 'las de prueba no salen en el día a día')
comprueba(ids(filtrarMedicos(tablero.medicos, { ver: 'todos' })) === 'm1,demo', 'en «Todos», sí')
comprueba(ids(filtrarMedicos(tablero.medicos, { ver: 'ocultos', q: 'demo' })) === 'demo', 'y buscándolas')
comprueba(ids(filtrarMedicos(tablero.medicos, { ver: 'todos', q: '0414-1234567' })) === 'm1', 'por teléfono')
comprueba(
  tablero.totales.interesados30d === 0 && tablero.totales.convertidosTotal === 0 && m1.interesados.total === 0 && m1.interesados.ultimo === null,
  'sin interesados en la respuesta (la base de antes), ceros',
)
comprueba(comoTarjetaPublica('m1', m1.tarjeta).codigo === null, 'la vista previa no lleva código: enlaza directo al médico')

console.log('── La pestaña: interesados y pacientes ───────────────────────')
const conEmbudo = leerTablero({
  totales: { clics_30d: 40, interesados_30d: 10, interesados_total: 25, convertidos_30d: 3, convertidos_total: 6 },
  medicos: [{ merchant_id: 'm1', interesados: { total: 25, d30: 10, convertidos: 6, ultimo: '2026-10-27T13:00:00Z' } }],
})
comprueba(
  conEmbudo.totales.interesados30d === 10 &&
    conEmbudo.totales.interesadosTotal === 25 &&
    conEmbudo.totales.convertidos30d === 3 &&
    conEmbudo.totales.convertidosTotal === 6,
  'los totales del embudo',
  conEmbudo.totales,
)
comprueba(
  JSON.stringify(conEmbudo.medicos[0]?.interesados) ===
    JSON.stringify({ total: 25, d30: 10, convertidos: 6, ultimo: '2026-10-27T13:00:00Z' }),
  'los interesados del médico',
)
comprueba(parteDe(10, 40) === '25 %' && parteDe(3, 10) === '30 %', 'qué parte pasa al paso siguiente')
comprueba(parteDe(5, 0) === null, 'sin clics no hay parte')

const interesados = leerInteresados([
  {
    lead_id: 'l2',
    merchant_id: 'm1',
    medico: 'Dra. Nadia Khabbaze',
    phone: '+584241112233',
    first_at: '2026-10-20T14:00:00Z',
    last_at: '2026-10-22T09:00:00Z',
    messages: 3,
    paciente: { profile_id: 'p1', nombre: 'María Pérez' },
    conversion: { charge_id: 'c1', order_number: 1042, created_at: '2026-10-23T16:00:00Z' },
  },
  {
    lead_id: 'l1',
    merchant_id: 'm2',
    medico: 'Dr. Luis Gómez',
    phone: '+584141234567',
    first_at: '2026-10-19T10:00:00Z',
    paciente: null,
    conversion: null,
  },
])
const [convertido, pendiente] = interesados
comprueba(ids(interesados) === 'l2,l1', 'en el orden de la base (el más reciente primero)')
comprueba(
  convertido.conversion?.numero === 1042 && convertido.paciente?.nombre === 'María Pérez' && convertido.mensajes === 3,
  'un interesado que ya es paciente',
  convertido,
)
comprueba(
  pendiente.conversion === null && pendiente.paciente === null && pendiente.mensajes === 1 && pendiente.ultimaVez === pendiente.primeraVez,
  'sin mensajes ni última vez: uno, y la primera',
  pendiente,
)
comprueba(leerInteresados(null).length === 0, 'sin respuesta, ninguno')
comprueba(rotuloDelInteresado(convertido) === 'Paciente · orden #1042', 'el estado con el número de orden')
comprueba(rotuloDelInteresado(pendiente) === 'Todavía no', 'el estado de quien no ha vuelto')
comprueba(
  rotuloDelInteresado({ conversion: { ordenId: 'c', numero: null, creadaEl: '' } }) === 'Paciente',
  'paciente sin número de orden',
)
comprueba(ids(filtrarInteresados(interesados, '')) === 'l2,l1', 'sin búsqueda, todos')
comprueba(ids(filtrarInteresados(interesados, 'gomez')) === 'l1', 'por médico, sin tildes')
comprueba(ids(filtrarInteresados(interesados, '0424-1112233')) === 'l2', 'por teléfono como se marca')
comprueba(ids(filtrarInteresados(interesados, '584141234567')) === 'l1', 'por teléfono como se guarda')
comprueba(ids(filtrarInteresados(interesados, 'perez maria')) === 'l2', 'por el nombre del paciente, en cualquier orden')
comprueba(ids(filtrarInteresados(interesados, 'nadia luis')) === '', 'todas las palabras tienen que estar')

console.log('── La pestaña: el borrador ───────────────────────────────────')
comprueba(whatsappE164('0414-123.45.67') === '+584141234567', 'el WhatsApp como lo marca la gente')
comprueba(whatsappE164('+58 414 1234567') === '+584141234567', 'con el +58')
comprueba(whatsappE164('4141234567') === '+584141234567', 'sin el 0')
comprueba(whatsappE164('12345') === null, 'uno corto no vale')

const b = borradorDe(m1.tarjeta)
comprueba(b.whatsapp === '0414-1234567' && b.ciudad === '', 'arranca con lo que se enseña', b)
comprueba(cambiosDelBorrador(b, m1.tarjeta) === null, 'sin tocar nada, nada que guardar')
comprueba(
  JSON.stringify(cambiosDelBorrador({ ...b, ciudad: ' Barquisimeto ', especialidad: 'Odontología  general' }, m1.tarjeta)) ===
    JSON.stringify({ specialty: 'Odontología general', city: 'Barquisimeto' }),
  'solo lo que cambió, limpio',
)
comprueba(
  JSON.stringify(cambiosDelBorrador({ ...b, nombre: '' }, m1.tarjeta)) === JSON.stringify({ name: '' }),
  'vaciar un dato lo manda vacío (vuelve el de la ficha)',
)
comprueba(
  datosDelBorrador({ ...b, nombre: '' }, m1.ficha).nombre === 'Dra. Nadia Andi Khabbaze Alfaro',
  'la vista previa enseña el de la ficha al vaciarlo',
)
comprueba(
  JSON.stringify(cambiosDelBorrador({ ...b, whatsapp: '0424 111 2233' }, m1.tarjeta)) ===
    JSON.stringify({ whatsapp: '+584241112233' }),
  'el WhatsApp va en E.164',
)
comprueba(cambiosDelBorrador({ ...b, whatsapp: '0414 123 4567' }, m1.tarjeta) === null, 'el mismo número escrito distinto no es un cambio')
comprueba(motivoParaNoGuardar({ ...b, whatsapp: '0414' }) !== null, 'un WhatsApp malo no se guarda')
comprueba(motivoParaNoGuardar({ ...b, nombre: 'Dr' }) !== null, 'un nombre de dos letras no se guarda')
comprueba(motivoParaNoGuardar(b) === null, 'el borrador de partida se puede guardar')
comprueba(
  JSON.stringify(cambiosDelBorrador({ ...b, red: 'instagram', usuarioDeRed: ' @draperez ' }, m1.tarjeta)) ===
    JSON.stringify({ social_network: 'instagram', social_user: '@draperez' }),
  'la red social va como red y usuario',
)
comprueba(motivoParaNoGuardar({ ...b, usuarioDeRed: '@draperez' }) !== null, 'un usuario sin red no se guarda')
comprueba(
  datosDelBorrador({ ...b, red: 'tiktok', usuarioDeRed: 'draperez' }, m1.ficha).red === 'tiktok',
  'la vista previa enseña la red del borrador',
)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
