/**
 * Pruebas de lo que el inbox entiende de un chat y de un mensaje del Inbox.
 *
 *   npx tsx src/features/admin/whatsapp/inbox.test.ts
 */
import {
  leerChat,
  leerMensaje,
  leerPagina,
  rotuloDeQuien,
  ventanaAbierta,
  vistaPrevia,
} from './inbox'

let failures = 0

function check(ok: boolean, label: string, detail = '') {
  if (!ok) failures++
  console.log(`${ok ? 'OK  ' : 'FALLA'} ${label.padEnd(44)} ${detail}`)
}

// Un mensaje que llega, como lo devuelve GET /api/v1/messages/.
const entrante = {
  id: 'abc',
  from_us: false,
  waba_payload: {
    from: '584141234567',
    id: 'wamid.1',
    timestamp: '1760900000',
    type: 'text',
    text: { body: 'Hola, ¿cuándo pago?' },
  },
  waba_statuses: { sent: null, delivered: null, read: null },
  sender: null,
}
const m1 = leerMensaje(entrante)
check(
  m1.texto === 'Hola, ¿cuándo pago?' && !m1.deHelios,
  'texto entrante',
  JSON.stringify(m1.texto),
)
check(
  m1.hora === 1760900000000,
  'hora en ms desde el timestamp en texto',
  String(m1.hora),
)
check(m1.estado === null, 'un entrante no tiene estado')

const saliente = leerMensaje({
  id: 'def',
  from_us: true,
  waba_payload: { type: 'text', text: { body: 'Mañana' } },
  waba_statuses: { sent: 1760900100, delivered: 1760900101, read: null },
  sender: { username: 'helios-app', first_name: 'Ana', last_name: '' },
})
check(
  saliente.deHelios && saliente.estado === 'entregado',
  'saliente entregado',
  String(saliente.estado),
)
check(
  saliente.hora === 1760900100000,
  'sin timestamp, la hora del envío',
  String(saliente.hora),
)
check(
  saliente.autor === 'Ana',
  'el autor sin apellido vacío',
  String(saliente.autor),
)

const foto = leerMensaje({
  from_us: false,
  waba_payload: {
    type: 'image',
    timestamp: 1,
    image: { id: '987', mime_type: 'image/jpeg', caption: 'Comprobante' },
  },
})
check(
  foto.adjunto?.tipo === 'imagen' &&
    foto.adjunto.id === '987' &&
    foto.texto === 'Comprobante',
  'una foto con su pie',
  JSON.stringify(foto.adjunto),
)

const nota = leerMensaje({
  waba_payload: {
    type: 'audio',
    audio: { id: '5', mime_type: 'audio/ogg; codecs=opus' },
  },
})
check(
  vistaPrevia(nota) === 'Nota de voz',
  'la vista previa de una nota de voz',
  vistaPrevia(nota),
)

const boton = leerMensaje({
  waba_payload: {
    type: 'interactive',
    interactive: {
      type: 'button_reply',
      button_reply: { id: 'x', title: 'Sí, acepto' },
    },
  },
})
check(
  boton.texto === 'Sí, acepto' && boton.rotulo === 'Botón',
  'la respuesta de un botón',
)

const plantilla = leerMensaje({
  from_us: true,
  waba_payload: { type: 'template', template: { name: 'aviso_cuota' } },
})
check(
  plantilla.rotulo === 'Plantilla: aviso_cuota',
  'una plantilla',
  String(plantilla.rotulo),
)
check(
  vistaPrevia(plantilla) === 'Tú: Plantilla: aviso_cuota',
  'vista previa de lo nuestro con «Tú:»',
  vistaPrevia(plantilla),
)

const raro = leerMensaje({ waba_payload: { type: 'order' } })
check(
  raro.rotulo === 'Mensaje de tipo «order»',
  'un tipo que no se conoce no rompe',
  String(raro.rotulo),
)
check(leerMensaje(null).id === '', 'un mensaje vacío no rompe')

const chat = leerChat({
  contact: {
    wa_id: '584141234567',
    phone_number: '584141234567',
    initials: 'MP',
    waba_payload: { wa_id: '584141234567', profile: { name: 'María Pérez' } },
    messaging_window_expires_at: 1760986400,
    resolved: false,
  },
  new_messages: 2,
  last_message: entrante,
  tags: [{ id: 1, name: 'cobranza' }],
})
check(
  chat.nombre === 'María Pérez' && chat.sinLeer === 2,
  'el chat con nombre y sin leer',
)
check(chat.ventanaHasta === 1760986400000, 'la ventana en ms')
check(
  ventanaAbierta(chat, 1760986399000) && !ventanaAbierta(chat, 1760986401000),
  'abierta hasta el segundo exacto',
)
check(!ventanaAbierta({ ventanaHasta: null }), 'sin ventana conocida, cerrada')
check(chat.etiquetas.join() === 'cobranza', 'las etiquetas')

const bsuid = leerChat({
  contact: { wa_id: 'US.abc', phone_number: null, waba_payload: {} },
  new_messages: 0,
})
check(
  bsuid.telefono === null && bsuid.nombre === null && bsuid.waId === 'US.abc',
  'quien oculta su número',
)

const pagina = leerPagina({ count: 41, results: [entrante] }, leerMensaje)
check(pagina.total === 41 && pagina.filas.length === 1, 'una página')
check(pagina.siguiente === null, 'sin siguiente, no hay más')
check(
  leerPagina({ count: 900, results: [], siguiente: 500 }, leerChat)
    .siguiente === 500,
  'una página filtrada vacía con más detrás',
)

const medico = leerChat({
  contact: { wa_id: '584141111111' },
  helios: {
    tipo: 'medico',
    nombre: 'Nadia Khabbaze',
    rol: 'gerente',
    merchant_id: 'm1',
    clinica: 'Clínica Andi',
  },
})
check(
  medico.quien?.tipo === 'medico' &&
    medico.quien.clinica === 'Clínica Andi' &&
    rotuloDeQuien(medico.quien) === 'Médico',
  'un médico',
)
const secretaria = leerChat({ helios: { tipo: 'medico', rol: 'cajero' } })
check(
  secretaria.quien !== null && rotuloDeQuien(secretaria.quien) === 'Secretaria',
  'su secretaria',
)
const paciente = leerChat({
  helios: { tipo: 'paciente', nombre: 'Luis', profile_id: 'p1' },
})
check(
  paciente.quien?.tipo === 'paciente' && paciente.quien.profileId === 'p1',
  'un paciente',
)
check(
  chat.quien === null && leerChat({ helios: { tipo: 'otro' } }).quien === null,
  'sin saber quién es',
)

console.log(failures === 0 ? '\nTodo bien.' : `\n${failures} fallo(s).`)
if (failures > 0) process.exit(1)
