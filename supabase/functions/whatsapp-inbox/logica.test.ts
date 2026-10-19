/**
 * Pruebas de lo que la función del inbox acepta y de cómo se lo pide al Inbox.
 *
 *   npx tsx supabase/functions/whatsapp-inbox/logica.test.ts
 */
import {
  errorDelInbox,
  leerPeticion,
  pagina,
  peticionAlInbox,
  rutaRelativa,
} from './logica.ts'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(
    `${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`,
  )
}

const igual = (a: unknown, b: unknown) =>
  JSON.stringify(a) === JSON.stringify(b)

const BASE = 'https://helios.inbox.getchat.360dialog.io/'
const u = (ruta: string) =>
  new URL(`https://x.supabase.co/functions/v1/whatsapp-inbox${ruta}`)

console.log('La ruta')
comprueba(
  igual(rutaRelativa('/whatsapp-inbox/chats'), ['chats']),
  'sin el prefijo de functions',
)
comprueba(
  igual(rutaRelativa('/functions/v1/whatsapp-inbox/adjunto/123'), [
    'adjunto',
    '123',
  ]),
  'con el prefijo',
)

console.log('Lo que acepta')
const chats = leerPeticion(
  'GET',
  u('/chats?q=%20ana%20&sin_leer=1&limite=500&desde=-3'),
  null,
)
comprueba(
  igual(chats, {
    tipo: 'chats',
    busqueda: 'ana',
    sinLeer: true,
    limite: 100,
    desde: 0,
  }),
  'chats: recorta la búsqueda y acota límite y desde',
  JSON.stringify(chats),
)
comprueba(
  igual(leerPeticion('GET', u('/chats'), null), {
    tipo: 'chats',
    busqueda: null,
    sinLeer: false,
    limite: 30,
    desde: 0,
  }),
  'chats: valores por defecto',
)
comprueba(
  igual(
    leerPeticion(
      'GET',
      u('/mensajes?wa_id=584141234567&antes_de=1700000000.7&marcar=1'),
      null,
    ),
    {
      tipo: 'mensajes',
      waId: '584141234567',
      antesDe: 1700000000,
      limite: 30,
      marcarRecibidos: true,
    },
  ),
  'mensajes: antes_de entero',
)
comprueba(
  'error' in leerPeticion('GET', u('/mensajes?wa_id=58414/../users'), null),
  'mensajes: wa_id con barras, no',
)
comprueba(
  'error' in leerPeticion('GET', u('/mensajes'), null),
  'mensajes: sin wa_id, no',
)
comprueba(
  'error' in leerPeticion('GET', u('/mensajes?wa_id=1&antes_de=abc'), null),
  'mensajes: antes_de raro, no',
)

comprueba(
  igual(
    leerPeticion('POST', u('/mensajes'), {
      wa_id: '584141234567',
      texto: '  Hola  ',
    }),
    {
      tipo: 'enviar',
      waId: '584141234567',
      texto: 'Hola',
    },
  ),
  'enviar: recorta el texto',
)
comprueba(
  'error' in
    leerPeticion('POST', u('/mensajes'), {
      wa_id: '584141234567',
      texto: '   ',
    }),
  'enviar: vacío, no',
)
comprueba(
  'error' in
    leerPeticion('POST', u('/mensajes'), {
      wa_id: '584141234567',
      texto: 'a'.repeat(4097),
    }),
  'enviar: más de 4096, no',
)
comprueba(
  'error' in leerPeticion('POST', u('/mensajes'), null),
  'enviar: sin cuerpo, no',
)

comprueba(
  igual(
    leerPeticion('POST', u('/resolver'), {
      wa_id: 'US.123abc',
      resuelto: true,
    }),
    {
      tipo: 'resolver',
      waId: 'US.123abc',
      resuelto: true,
    },
  ),
  'resolver: un BSUID vale',
)
comprueba(
  'error' in
    leerPeticion('POST', u('/resolver'), { wa_id: '1', resuelto: 'sí' }),
  'resolver: resuelto no booleano, no',
)

comprueba(
  igual(leerPeticion('GET', u('/adjunto/1234567890?mime=image/jpeg'), null), {
    tipo: 'adjunto',
    id: '1234567890',
    mime: 'image/jpeg',
  }),
  'adjunto: id y mime',
)
comprueba(
  igual(leerPeticion('GET', u('/adjunto/abc?mime=text/html;x=1'), null), {
    tipo: 'adjunto',
    id: 'abc',
    mime: null,
  }),
  'adjunto: un mime con parámetros se ignora',
)
comprueba(
  'error' in leerPeticion('GET', u('/adjunto/a%2Fb'), null),
  'adjunto: id con barra codificada, no',
)

const desconocida = leerPeticion('DELETE', u('/chats'), null)
comprueba(
  'error' in desconocida && desconocida.error === 'ruta_desconocida',
  'otro método: ruta desconocida',
)
comprueba(
  'error' in leerPeticion('GET', u('/chats/x/y'), null),
  'ruta con sobras: no',
)

console.log('Lo que se le pide al Inbox')
comprueba(
  peticionAlInbox(BASE, {
    tipo: 'chats',
    busqueda: 'ana',
    sinLeer: true,
    limite: 30,
    desde: 60,
  }).url ===
    'https://helios.inbox.getchat.360dialog.io/api/v1/chats/?limit=30&offset=60&search=ana&unread=true',
  'chats',
)
comprueba(
  peticionAlInbox(BASE, {
    tipo: 'mensajes',
    waId: '58414',
    antesDe: 1700,
    limite: 20,
    marcarRecibidos: true,
  }).url ===
    'https://helios.inbox.getchat.360dialog.io/api/v1/messages/?wa_id=58414&limit=20&before_time=1700&mark_as_received=1',
  'mensajes',
)
const enviar = peticionAlInbox(BASE, {
  tipo: 'enviar',
  waId: '58414',
  texto: 'Hola',
})
comprueba(
  enviar.metodo === 'POST' &&
    igual(enviar.cuerpo, {
      wa_id: '58414',
      type: 'text',
      text: { body: 'Hola' },
    }),
  'enviar: texto',
)
const resolver = peticionAlInbox(BASE, {
  tipo: 'resolver',
  waId: '58414',
  resuelto: false,
})
comprueba(
  resolver.metodo === 'PATCH' &&
    resolver.url.endsWith('/api/v1/chats/58414/resolve/') &&
    igual(resolver.cuerpo, { resolved: false }),
  'resolver',
)
comprueba(
  peticionAlInbox(BASE, {
    tipo: 'adjunto',
    id: '99',
    mime: 'audio/ogg',
  }).url.endsWith(
    '/api/v1/media/99/?mime_type_type=audio&mime_type_subtype=ogg',
  ),
  'adjunto con mime',
)

console.log('Lo que contestó el Inbox')
comprueba(errorDelInbox(202) === null, '202: bien')
comprueba(
  errorDelInbox(453)?.error === 'ventana_cerrada',
  '453: ventana cerrada',
)
comprueba(
  errorDelInbox(403)?.error === 'sin_permiso_en_inbox',
  '403 al escribir: sin permiso en ese chat',
)
comprueba(
  errorDelInbox(403, true)?.error === 'token_invalido',
  '403 al comprobar: token inválido',
)
comprueba(errorDelInbox(503)?.error === 'inbox_no_responde', '503: no responde')
comprueba(
  igual(pagina({ count: 2, next: 'https://x', results: [1, 2] }), {
    count: 2,
    results: [1, 2],
  }),
  'página sin next',
)
comprueba(igual(pagina(null), { count: 0, results: [] }), 'página vacía')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
