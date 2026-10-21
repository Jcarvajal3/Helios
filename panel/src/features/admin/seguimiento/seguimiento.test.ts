/**
 * Pruebas del seguimiento de las clínicas.
 *
 *   npx tsx src/features/admin/seguimiento/seguimiento.test.ts
 *
 * Lo que se vigila: que el tablero se lea sin inventar un médico donde no hay
 * titular, que el orden de trabajo ponga arriba lo que toca llamar, que la
 * vista por persona empiece por quien más órdenes registra, que la búsqueda
 * encuentre un teléfono escrito a la venezolana y que el borrador no se pueda
 * anotar sin nota o con una fecha pasada.
 */
import {
  aParametros,
  borradorDeSeguimiento,
  contactablesDe,
  enlaceDeLlamada,
  estadoDelSeguimiento,
  filtrarClinicas,
  filtrarPersonas,
  leerTablero,
  motivoParaNoAnotarSeguimiento,
  ordenarParaLlamar,
  personasDelTablero,
} from './seguimiento'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function igual<T>(titulo: string, sale: T, espera: T) {
  comprueba(JSON.stringify(sale) === JSON.stringify(espera), titulo, `${JSON.stringify(sale)} ≠ ${JSON.stringify(espera)}`)
}

const HOY = '2026-10-21'

function persona(id: string, nombre: string, confirmadas: number, extra: Record<string, unknown> = {}) {
  return {
    user_id: id,
    name: nombre,
    email: `${id}@correo.com`,
    phone: null,
    role: 'cajero',
    branch: 'Principal',
    joined_at: '2026-10-01T12:00:00Z',
    last_sign_in_at: null,
    orders_registered: confirmadas,
    orders_confirmed: confirmadas,
    orders_30d: confirmadas,
    orders_whatsapp: 0,
    last_order_at: confirmadas > 0 ? '2026-10-20T12:00:00Z' : null,
    ...extra,
  }
}

function clinica(id: string, nombre: string, extra: Record<string, unknown> = {}) {
  return {
    merchant_id: id,
    name: nombre,
    status: 'active',
    is_test: false,
    city: 'Caracas',
    specialty: 'Odontología',
    phone: null,
    email: null,
    owner_name: null,
    doctor_name: nombre,
    created_at: '2026-10-01T12:00:00Z',
    orders_confirmed: 0,
    orders_30d: 0,
    last_order_at: null,
    staff: [],
    followups_count: 0,
    last_followup: null,
    next_contact_on: null,
    ...extra,
  }
}

const crudo = [
  clinica('a', 'Al día', {
    followups_count: 2,
    last_followup: {
      created_at: '2026-10-15T15:00:00Z',
      channel: 'llamada',
      topic: 'opinion',
      note: 'Contenta',
      actor_name: 'Javier',
      contact_name: null,
    },
  }),
  clinica('b', 'Atrasada', { followups_count: 1, next_contact_on: '2026-10-19' }),
  clinica('c', 'Programada', { followups_count: 1, next_contact_on: '2026-10-25' }),
  clinica('d', 'Nunca, poca', { orders_confirmed: 1 }),
  clinica('e', 'Nunca, mucha', {
    orders_confirmed: 9,
    owner_name: 'Nadia Khabbaze',
    doctor_name: 'Dra. Nadia Khabbaze',
    phone: '+584121112233',
    staff: [persona('ana', 'Ana', 7, { phone: '+584149990001' }), persona('luis', 'Luis', 2)],
  }),
  clinica('f', 'Hoy', { followups_count: 3, next_contact_on: HOY }),
  clinica('g', 'De prueba', { is_test: true, staff: [persona('test', 'Tester', 50)] }),
]

const tablero = leerTablero(crudo)

console.log('── Lectura ───────────────────────────────────────────────────')
igual('sin titular no hay médico (no el nombre de la clínica)', tablero[0]?.medico, null)
igual('con titular, el médico con su título', tablero[4]?.medico, 'Dra. Nadia Khabbaze')
igual('el último contacto se lee', tablero[0]?.ultimoContacto?.motivo, 'opinion')
igual('un rol desconocido cae en secretaria', leerTablero([clinica('x', 'X', { staff: [persona('p', 'P', 0, { role: 'raro' })] })])[0]?.personal[0]?.rol, 'cajero')

console.log('── Estado ────────────────────────────────────────────────────')
igual('fecha pasada → atrasado', estadoDelSeguimiento({ contactos: 1, volverEl: '2026-10-20' }, HOY), 'atrasado')
igual('fecha de hoy → hoy', estadoDelSeguimiento({ contactos: 1, volverEl: HOY }, HOY), 'hoy')
igual('fecha futura → programado', estadoDelSeguimiento({ contactos: 1, volverEl: '2026-11-01' }, HOY), 'programado')
igual('sin contactos → nunca', estadoDelSeguimiento({ contactos: 0, volverEl: null }, HOY), 'nunca')
igual('con contactos y sin fecha → al día', estadoDelSeguimiento({ contactos: 4, volverEl: null }, HOY), 'al_dia')

console.log('── Orden de trabajo ──────────────────────────────────────────')
igual(
  'atrasado, hoy, nunca (más órdenes primero), programado, al día; prueba al final',
  ordenarParaLlamar(tablero, HOY).map((c) => c.id),
  ['b', 'f', 'e', 'd', 'c', 'a', 'g'],
)

console.log('── Por persona ───────────────────────────────────────────────')
const personas = personasDelTablero(tablero)
igual('quien más órdenes confirmadas, primero', personas.map((p) => p.userId), ['test', 'ana', 'luis'])
igual('cada persona lleva su clínica', personas[1]?.clinica, 'Nunca, mucha')

console.log('── Qué se ve y búsqueda ──────────────────────────────────────')
igual(
  'para llamar: atrasado, hoy y nunca, sin las de prueba',
  filtrarClinicas(tablero, { ver: 'para_llamar' }, HOY).map((c) => c.id).sort(),
  ['b', 'd', 'e', 'f'],
)
igual('activas: sin las de prueba', filtrarClinicas(tablero, { ver: 'activas' }, HOY).length, 6)
igual('todas', filtrarClinicas(tablero, { ver: 'todas' }, HOY).length, 7)
igual('por el médico, sin tildes', filtrarClinicas(tablero, { ver: 'todas', texto: 'khabbazé' }, HOY).map((c) => c.id), ['e'])
igual('por una persona del personal', filtrarClinicas(tablero, { ver: 'todas', texto: 'luis' }, HOY).map((c) => c.id), ['e'])
igual('por un teléfono escrito a la venezolana', filtrarClinicas(tablero, { ver: 'todas', texto: '0414-999' }, HOY).map((c) => c.id), ['e'])
igual('dos dígitos no buscan teléfonos', filtrarClinicas(tablero, { ver: 'todas', texto: '41' }, HOY).length, 0)
igual('personas: por nombre', filtrarPersonas(personas, 'ana').map((p) => p.userId), ['ana'])

console.log('── Contactables ──────────────────────────────────────────────')
const e = tablero.at(4)
igual(
  'el consultorio y quien tiene número; sin número no sale',
  e ? contactablesDe(e).map((c) => [c.userId, c.rol]) : [],
  [
    [null, 'Consultorio'],
    ['ana', 'Secretaria'],
  ],
)
const mismoNumero = leerTablero([
  clinica('t', 'Titular', {
    phone: '+584123391230',
    staff: [persona('dr', 'Dr', 1, { role: 'gerente', phone: '+584123391230' })],
  }),
]).at(0)
igual(
  'el titular con el número del consultorio no sale dos veces',
  mismoNumero ? contactablesDe(mismoNumero).map((c) => c.userId) : [],
  ['dr'],
)
igual('tel: con el número completo', enlaceDeLlamada('0414-123.45.67'), 'tel:+584141234567')
igual('sin dígitos, sin enlace', enlaceDeLlamada('—'), null)

console.log('── Borrador ──────────────────────────────────────────────────')
const vacio = borradorDeSeguimiento()
comprueba(motivoParaNoAnotarSeguimiento(vacio, HOY) === 'Escribe qué se habló.', 'sin nota no se anota')
comprueba(
  motivoParaNoAnotarSeguimiento({ ...vacio, nota: 'Bien', volverEl: '2026-10-20' }, HOY) !== undefined,
  'volver ayer no se anota',
)
comprueba(motivoParaNoAnotarSeguimiento({ ...vacio, nota: 'Bien', volverEl: HOY }, HOY) === undefined, 'volver hoy sí')
igual(
  'los parámetros: consultorio y sin fecha son null; la nota sin espacios',
  aParametros('m', { ...vacio, nota: '  Bien  ' }),
  {
    p_merchant_id: 'm',
    p_channel: 'llamada',
    p_topic: 'seguimiento',
    p_note: 'Bien',
    p_contact_user_id: null,
    p_next_contact_on: null,
  },
)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
