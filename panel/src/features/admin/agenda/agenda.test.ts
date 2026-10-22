/**
 * Pruebas de la agenda de médicos por afiliar.
 *
 *   npx tsx src/features/admin/agenda/agenda.test.ts
 *
 * Lo que se vigila: que el tablero se lea, que las horas de las reuniones
 * sean las de Caracas (una reunión a las 9 de la noche no salta al día
 * siguiente), que el orden de trabajo ponga arriba lo atrasado y lo de hoy,
 * que la búsqueda encuentre un teléfono escrito a la venezolana, que el
 * calendario cuadre las semanas y que una gestión no se pueda anotar sin
 * fecha de reunión, con una fecha pasada o sin nada que contar.
 */
import {
  aParametros,
  anulaLaReunion,
  borradorDeGestion,
  casillasDelMes,
  citasDe,
  diaDeCaracas,
  filtrarAgenda,
  horaDeCaracas,
  instanteDeCaracas,
  leerAgenda,
  mesDeAlLado,
  motivoParaNoAnotar,
  motivoParaNoGuardar,
  ordenarAgenda,
  pendienteDe,
  borradorDeLead,
} from './agenda'
import type { Lead } from './agenda'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function igual<T>(titulo: string, sale: T, espera: T) {
  comprueba(JSON.stringify(sale) === JSON.stringify(espera), titulo, `${JSON.stringify(sale)} ≠ ${JSON.stringify(espera)}`)
}

const HOY = '2026-10-22'
// Las 11 de la mañana en Caracas.
const AHORA = new Date('2026-10-22T15:00:00Z')

function lead(id: string, extra: Record<string, unknown> = {}): Lead {
  const [l] = leerAgenda([
    {
      id,
      name: `Dr. ${id}`,
      phone: '+584147000001',
      status: 'contactado',
      created_at: '2026-10-01T12:00:00Z',
      activities_count: 1,
      ...extra,
    },
  ])
  return l
}

console.log('── El tablero ───────────────────────────────────────────────')
{
  const [l] = leerAgenda([
    {
      id: 'a',
      name: 'Dra. Ana',
      status: 'convertido',
      source: 'referido',
      converted_via: 'formulario',
      match_reason: 'telefono',
      application_status: 'pending',
      last_activity: { created_at: '2026-10-20T10:00:00Z', kind: 'conversion', status_to: 'convertido', actor_name: null },
    },
  ])
  igual('lee el estado, la vía y la razón', [l.estado, l.via, l.razon, l.solicitudEstado], [
    'convertido',
    'formulario',
    'telefono',
    'pending',
  ])
  igual('la última gestión del sistema no tiene autor', l.ultima?.quien, null)
  igual('un estado desconocido se lee como «nuevo»', leerAgenda([{ id: 'x', status: 'raro' }])[0]?.estado, 'nuevo')
}

console.log('\n── Las horas de Caracas ─────────────────────────────────────')
{
  const nueveDeLaNoche = instanteDeCaracas('2026-10-23', '21:00')
  igual('el instante lleva el desfase de Caracas', nueveDeLaNoche, '2026-10-23T21:00:00-04:00')
  igual('una reunión a las 9 de la noche es de ese día', diaDeCaracas(nueveDeLaNoche), '2026-10-23')
  igual('y a esa hora', horaDeCaracas(nueveDeLaNoche), '21:00')
  igual('lo que llega de la base en UTC se lee en Caracas', horaDeCaracas('2026-10-23T14:30:00+00:00'), '10:30')
}

console.log('\n── Qué toca hoy y el orden ──────────────────────────────────')
{
  const pasada = lead('pasada', { status: 'reunion', meeting_at: '2026-10-21T14:00:00Z' })
  const atrasada = lead('atrasada', { next_contact_on: '2026-10-20' })
  const hoyReunion = lead('hoyReunion', { status: 'reunion', meeting_at: '2026-10-22T20:00:00Z' })
  const hoyLlamar = lead('hoyLlamar', { next_contact_on: HOY })
  const nuevo = lead('nuevo', { status: 'nuevo' })
  const manana = lead('manana', { status: 'reunion', meeting_at: '2026-10-23T14:00:00Z' })
  const semana = lead('semana', { next_contact_on: '2026-10-29' })
  const afiliado = lead('afiliado', { status: 'convertido', next_contact_on: '2026-10-20' })

  igual('una reunión que ya pasó pide anotar cómo fue', pendienteDe(pasada, HOY, AHORA), 'reunion_pasada')
  igual('una reunión a las 4 de la tarde de hoy es de hoy', pendienteDe(hoyReunion, HOY, AHORA), 'reunion_hoy')
  igual('un afiliado no tiene pendientes', pendienteDe(afiliado, HOY, AHORA), null)

  const orden = ordenarAgenda([afiliado, semana, manana, nuevo, hoyLlamar, hoyReunion, atrasada, pasada], HOY, AHORA)
  igual(
    'el orden de trabajo',
    orden.map((l) => l.id),
    ['pasada', 'atrasada', 'hoyReunion', 'hoyLlamar', 'nuevo', 'manana', 'semana', 'afiliado'],
  )

  const todos = [afiliado, semana, manana, nuevo, hoyLlamar, hoyReunion, atrasada, pasada]
  igual(
    '«Para hoy» trae solo lo pendiente',
    filtrarAgenda(todos, { ver: 'para_hoy' }, HOY, AHORA).map((l) => l.id).sort(),
    ['atrasada', 'hoyLlamar', 'hoyReunion', 'nuevo', 'pasada'],
  )
  igual('«Abiertos» deja fuera a los afiliados', filtrarAgenda(todos, { ver: 'abiertos' }, HOY, AHORA).length, 7)
}

console.log('\n── La búsqueda ──────────────────────────────────────────────')
{
  const ana = lead('ana', { name: 'Dra. Ana Pérez', city: 'Mérida', phone: '+584141234567' })
  const luis = lead('luis', { name: 'Dr. Luis Gómez', phone: '+582125550002' })
  igual('sin tildes', filtrarAgenda([ana, luis], { texto: 'perez', ver: 'todos' }, HOY, AHORA).map((l) => l.id), ['ana'])
  igual('por la ciudad', filtrarAgenda([ana, luis], { texto: 'merida', ver: 'todos' }, HOY, AHORA).map((l) => l.id), ['ana'])
  igual(
    'un teléfono a la venezolana',
    filtrarAgenda([ana, luis], { texto: '0414 123', ver: 'todos' }, HOY, AHORA).map((l) => l.id),
    ['ana'],
  )
  igual(
    'filtra por estado',
    filtrarAgenda([ana, lead('r', { status: 'reunion' })], { ver: 'todos', estado: 'reunion' }, HOY, AHORA).map((l) => l.id),
    ['r'],
  )
}

console.log('\n── El calendario ────────────────────────────────────────────')
{
  const octubre = casillasDelMes('2026-10-01')
  igual('octubre de 2026 empieza el lunes 28 de septiembre', octubre[0], '2026-09-28')
  igual('y termina el domingo 1 de noviembre', octubre.at(-1), '2026-11-01')
  comprueba(octubre.length % 7 === 0, 'semanas completas', String(octubre.length))
  igual('febrero de 2027 cabe en cuatro semanas', casillasDelMes('2027-02-01').length, 28)
  igual('el mes de al lado cruza el año', mesDeAlLado('2026-12-01', 1), '2027-01-01')

  const r = lead('r', { status: 'reunion', meeting_at: '2026-10-24T01:00:00Z', next_contact_on: '2026-10-23' })
  const cerrado = lead('c', { status: 'descartado', next_contact_on: '2026-10-25' })
  igual(
    'la reunión a las 9 de la noche cae en su día de Caracas, y la llamada detrás',
    citasDe([r, cerrado]).map((c) => `${c.tipo}:${c.dia}:${c.hora ?? ''}`),
    ['reunion:2026-10-23:21:00', 'llamada:2026-10-23:'],
  )
}

console.log('\n── Anotar una gestión ───────────────────────────────────────')
{
  const contactado = lead('c')
  const b = borradorDeGestion(contactado)
  igual('desde «contactado» se propone «respondió»', b.estado, 'respondio')

  igual(
    'una reunión sin día no se anota',
    motivoParaNoAnotar({ ...b, estado: 'reunion', reunionDia: '' }, contactado, HOY, AHORA),
    'Pon el día y la hora de la reunión.',
  )
  igual(
    'ni en una fecha pasada',
    motivoParaNoAnotar({ ...b, estado: 'reunion', reunionDia: '2026-10-21' }, contactado, HOY, AHORA),
    'La fecha de la reunión ya pasó.',
  )
  igual(
    'sin cambio y sin nada que contar, no',
    motivoParaNoAnotar({ ...b, estado: 'contactado', canal: '', nota: '' }, contactado, HOY, AHORA),
    'Cuenta qué pasó o cambia el estado.',
  )
  igual('cambiar el estado basta', motivoParaNoAnotar({ ...b, canal: '' }, contactado, HOY, AHORA), undefined)

  const p = aParametros('c', { ...b, estado: 'reunion', reunionDia: '2026-10-23', reunionHora: '10:30' }, contactado)
  igual('la reunión se manda en hora de Caracas', p.p_meeting_at, '2026-10-23T10:30:00-04:00')

  const conReunion = lead('r', { status: 'reunion', meeting_at: '2026-10-23T14:30:00Z', meeting_mode: 'videollamada' })
  const misma = borradorDeGestion(conReunion)
  igual('el borrador trae la reunión que tenía', [misma.reunionDia, misma.reunionHora, misma.modo], [
    '2026-10-23',
    '10:30',
    'videollamada',
  ])
  igual('la misma reunión no se vuelve a mandar', aParametros('r', { ...misma, nota: 'Confirmó' }, conReunion).p_meeting_at, undefined)
  comprueba(anulaLaReunion({ ...misma, estado: 'descartado' }, conReunion, AHORA), 'descartar antes de la reunión la anula')
  comprueba(
    !anulaLaReunion({ ...misma, estado: 'descartado' }, conReunion, new Date('2026-10-24T00:00:00Z')),
    'después de la reunión, no',
  )
}

console.log('\n── Apuntar ──────────────────────────────────────────────────')
{
  const b = borradorDeLead()
  igual('sin nombre no se guarda', motivoParaNoGuardar(b), 'Escribe el nombre del médico.')
  igual('con nombre basta', motivoParaNoGuardar({ ...b, nombre: 'Dra. Ana' }), undefined)
  igual(
    'un teléfono corto no vale',
    motivoParaNoGuardar({ ...b, nombre: 'Dra. Ana', telefono: '0414 12' }),
    'El teléfono no parece venezolano.',
  )
  igual('uno con +58 sí', motivoParaNoGuardar({ ...b, nombre: 'Dra. Ana', telefono: '+58 414 123 4567' }), undefined)
}

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
