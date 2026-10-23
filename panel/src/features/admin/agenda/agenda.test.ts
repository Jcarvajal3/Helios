/**
 * Pruebas de la agenda de médicos por afiliar.
 *
 *   npx tsx src/features/admin/agenda/agenda.test.ts
 *
 * Lo que se vigila: que el tablero se lea, que las horas de las visitas
 * sean las de Caracas (una visita a las 9 de la noche no salta al día
 * siguiente), que el orden de trabajo ponga arriba lo atrasado y lo de hoy,
 * que la búsqueda encuentre un teléfono escrito a la venezolana, que el
 * calendario cuadre las semanas, que el árbol de la gestión (mensaje,
 * llamada, visita) dé el resultado y el estado que da la base, y que una
 * gestión no se pueda anotar sin fecha de visita, con una fecha pasada o sin
 * nada que contar.
 */
import {
  SIN_ELEGIR,
  aParametros,
  afiliacionEnCurso,
  anulaLaVisita,
  borradorDeGestion,
  canalDe,
  casillasDelMes,
  cifrasDeLaAgenda,
  citasDe,
  diaDeCaracas,
  esCapacitacion,
  estadoDelResultado,
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
  resultadoDe,
} from './agenda'
import type { Eleccion, Lead } from './agenda'

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
  igual('una visita a las 9 de la noche es de ese día', diaDeCaracas(nueveDeLaNoche), '2026-10-23')
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

  igual('una visita que ya pasó pide anotar cómo fue', pendienteDe(pasada, HOY, AHORA), 'visita_pasada')
  igual('una visita a las 4 de la tarde de hoy es de hoy', pendienteDe(hoyReunion, HOY, AHORA), 'visita_hoy')
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
  const ana = lead('ana', { name: 'Dra. Ana Pérez', address: 'Torre Sur, Mérida', phone: '+584141234567' })
  const luis = lead('luis', { name: 'Dr. Luis Gómez', phone: '+582125550002' })
  igual('sin tildes', filtrarAgenda([ana, luis], { texto: 'perez', ver: 'todos' }, HOY, AHORA).map((l) => l.id), ['ana'])
  igual('por la dirección', filtrarAgenda([ana, luis], { texto: 'merida', ver: 'todos' }, HOY, AHORA).map((l) => l.id), ['ana'])
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
    'la visita a las 9 de la noche cae en su día de Caracas, y la llamada detrás',
    citasDe([r, cerrado]).map((c) => `${c.tipo}:${c.dia}:${c.hora ?? ''}`),
    ['visita:2026-10-23:21:00', 'llamada:2026-10-23:'],
  )

  // La capacitación que pidió en el formulario es su visita mientras no se mueva.
  const capa = lead('k', {
    status: 'reunion',
    meeting_at: '2026-10-30T14:00:00+00:00',
    application_training_at: '2026-10-30T10:00:00-04:00',
    application_status: 'pending',
  })
  igual('la capacitación sale marcada en el calendario', citasDe([capa]).map((c) => c.capacitacion), [true])
  igual('si el equipo mueve la visita, deja de serlo', esCapacitacion({ ...capa, reunion: '2026-10-31T14:00:00Z' }), false)
}

console.log('\n── La afiliación en curso ──────────────────────────────────')
{
  igual('solicitud pendiente', afiliacionEnCurso(lead('p', { application_status: 'pending' })), 'solicitud_por_revisar')
  igual(
    'aprobada, sin accesos',
    afiliacionEnCurso(lead('s', { application_status: 'approved', merchant_id: 'm1', merchant_has_access: false })),
    'falta_dar_accesos',
  )
  igual(
    'con accesos ya no falta nada',
    afiliacionEnCurso(lead('c', { status: 'convertido', merchant_id: 'm1', merchant_has_access: true })),
    null,
  )
  igual('sin formulario, nada', afiliacionEnCurso(lead('n')), null)
}

console.log('\n── El árbol de la gestión ───────────────────────────────────')
{
  const r = (e: Partial<Eleccion>, conVisita = false) => resultadoDe({ ...SIN_ELEGIR, ...e }, conVisita)
  igual('mensaje › enviado', r({ tipo: 'mensaje', respuesta: 'enviado' }), 'mensaje_enviado')
  igual('mensaje › contestó, sin decir si le interesa, aún no', r({ tipo: 'mensaje', respuesta: 'contesto' }), null)
  igual('mensaje › contestó › interesado', r({ tipo: 'mensaje', respuesta: 'contesto', interesado: true }), 'interesado')
  igual('llamada › contestó › no interesado', r({ tipo: 'llamada', respuesta: 'contesto', interesado: false }), 'no_interesado')
  igual('llamada › ocupado', r({ tipo: 'llamada', respuesta: 'ocupado' }), 'ocupado')
  igual('visita sin una agendada: agendarla', r({ tipo: 'visita' }), 'visita_agendada')
  igual('visita con una agendada: falta decir qué pasó', r({ tipo: 'visita' }, true), null)
  igual('visita › pospuesta', r({ tipo: 'visita', respuesta: 'pospuesta' }, true), 'visita_pospuesta')
  igual('solo una nota', r({ tipo: 'nota' }), 'nota')
  igual('el canal de una llamada', canalDe({ ...SIN_ELEGIR, tipo: 'llamada' }), 'llamada')
  igual('una nota no tiene canal', canalDe({ ...SIN_ELEGIR, tipo: 'nota' }), null)

  const c = lead('c')
  igual(
    'el estado que deja cada resultado (el de la base)',
    (['mensaje_enviado', 'interesado', 'no_interesado', 'ocupado', 'visita_realizada', 'visita_cancelada', 'nota'] as const).map(
      (x) => estadoDelResultado(x, c),
    ),
    ['contactado', 'respondio', 'descartado', 'no_respondio', 'visitado', 'respondio', 'contactado'],
  )
}

console.log('\n── Anotar una gestión ───────────────────────────────────────')
{
  const contactado = lead('c')
  const b = borradorDeGestion(contactado)

  igual('sin elegir qué pasó no se anota', motivoParaNoAnotar(null, b, contactado, HOY), 'Elige qué pasó.')
  igual(
    'una visita sin día no se anota',
    motivoParaNoAnotar('visita_agendada', b, contactado, HOY),
    'Pon el día y la hora de la visita.',
  )
  igual(
    'ni en una fecha pasada',
    motivoParaNoAnotar('visita_agendada', { ...b, visitaDia: '2026-10-21' }, contactado, HOY),
    'La fecha de la visita ya pasó.',
  )
  igual('una nota vacía no se anota', motivoParaNoAnotar('nota', b, contactado, HOY), 'Escribe la nota.')
  igual('«no contestó» basta', motivoParaNoAnotar('no_contesto', b, contactado, HOY), undefined)

  const p = aParametros('c', 'visita_agendada', 'visita', { ...b, visitaDia: '2026-10-23', visitaHora: '10:30' })
  igual('la visita se manda en hora de Caracas', p.p_meeting_at, '2026-10-23T10:30:00-04:00')
  igual('con su resultado y su canal', [p.p_result, p.p_channel], ['visita_agendada', 'visita'])
  igual(
    'una llamada no manda fecha de visita',
    aParametros('c', 'no_contesto', 'llamada', { ...b, visitaDia: '2026-10-23' }).p_meeting_at,
    undefined,
  )

  const conVisita = lead('r', { status: 'reunion', meeting_at: '2026-10-23T14:30:00Z', meeting_mode: 'videollamada' })
  const misma = borradorDeGestion(conVisita)
  igual('el borrador trae la hora y el modo de la visita', [misma.visitaHora, misma.modo], ['10:30', 'videollamada'])
  igual(
    'posponer a la misma hora no vale',
    motivoParaNoAnotar('visita_pospuesta', { ...misma, visitaDia: '2026-10-23' }, conVisita, HOY),
    'Pon la nueva fecha de la visita.',
  )
  comprueba(anulaLaVisita('no_interesado', conVisita, AHORA), '«no interesado» antes de la visita la anula')
  comprueba(anulaLaVisita('visita_cancelada', conVisita, AHORA), 'cancelarla, también')
  comprueba(!anulaLaVisita('nota', conVisita, AHORA), 'una nota, no')
  comprueba(!anulaLaVisita('visita_realizada', conVisita, AHORA), 'darla por realizada, no')
  comprueba(
    !anulaLaVisita('no_interesado', conVisita, new Date('2026-10-24T00:00:00Z')),
    'después de la visita, nada se anula',
  )
}

console.log('\n── Las cifras de arriba ─────────────────────────────────────')
{
  const cifras = cifrasDeLaAgenda(
    [
      lead('nuevo', { status: 'nuevo' }),
      lead('mensaje', { status: 'contactado' }),
      lead('porVenir', { status: 'reunion', meeting_at: '2026-10-23T14:00:00Z' }),
      lead('realizada', { status: 'visitado', meeting_at: '2026-10-20T14:00:00Z' }),
      lead('cancelada', { status: 'respondio' }),
      lead('afiliado', { status: 'convertido', merchant_id: 'm1' }),
      lead('solicitud', { status: 'convertido' }),
    ],
    AHORA,
  )
  igual('contactados, citas (por venir o no) y activados (con clínica o no)', cifras, {
    apuntados: 7,
    contactados: 6,
    citas: 2,
    citasPorVenir: 1,
    activados: 2,
    conClinica: 1,
  })
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
