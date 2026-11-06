/**
 * Pruebas de rx-enviar, sin red: CORS, escape, el correo y todos los caminos del
 * manejador con dobles.
 *
 *   npx tsx supabase/functions/rx-enviar/logica.test.ts
 */
import {
  armarCorreo,
  cabecerasCors,
  direccionDe,
  enlaceDePrecios,
  errorDeLaBase,
  esPdf,
  escaparHtml,
  leerPeticion,
  limpiarNombre,
  numeroConCeros,
  origenPermitido,
} from './logica.ts'
import { crearManejador, type Dependencias, type DatosEnvio } from './manejador.ts'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok ' : ' MAL '} ${titulo}${!ok && detalle ? ` → ${detalle}` : ''}`)
}

// ─── CORS ────────────────────────────────────────────────────────────────────

for (const o of ['https://conhelios.com', 'https://www.conhelios.com', 'http://localhost:3002']) {
  comprueba(cabecerasCors(o)['Access-Control-Allow-Origin'] === o, `CORS: ${o} entra`)
}
for (const o of ['https://evil.com', 'http://conhelios.com', 'https://conhelios.com.evil.com', 'http://localhost:3003',
                 'https://otro.vercel.app', 'https://helios-rx.vercel.app.evil.com', 'http://helios-rx.vercel.app',
                 'https://helios-rx.evil.vercel.app', 'https://helios-rx-evil.vercel.app']) {
  comprueba(!origenPermitido(o) && !('Access-Control-Allow-Origin' in cabecerasCors(o)), `CORS: ${o} no entra`)
}
comprueba(!('Access-Control-Allow-Origin' in cabecerasCors(null)), 'CORS: sin origen no hay Allow-Origin')

// ─── Lo puro ─────────────────────────────────────────────────────────────────

const ID = '11111111-2222-4333-8444-555555555555'
comprueba(leerPeticion({ recipe_id: ID, correo: 'a@b.co' })?.recipe_id === ID, 'petición válida')
comprueba(leerPeticion({ recipe_id: 'x', correo: 'a@b.co' }) === null, 'el id debe ser un uuid')
comprueba(leerPeticion({ recipe_id: ID }) === null, 'falta el correo')
comprueba(leerPeticion('hola') === null, 'el cuerpo debe ser un objeto')

comprueba(escaparHtml(`<a href="x">&'`) === '&lt;a href=&quot;x&quot;&gt;&amp;&#39;', 'escape de HTML')
comprueba(limpiarNombre(' Dra. "Ana" <Lara>\r\nBcc: x ') === 'Dra. Ana Lara Bcc: x', 'el nombre del remitente, limpio')
comprueba(direccionDe('Helios <hola@conhelios.com>') === 'hola@conhelios.com', 'la dirección del remitente')
comprueba(direccionDe('sin dirección') === null, 'remitente sin dirección')
comprueba(numeroConCeros(12) === '000012', 'el número con ceros')
comprueba(esPdf(new TextEncoder().encode('%PDF-1.7 x')), 'un PDF')
comprueba(!esPdf(new TextEncoder().encode('\x89PNG\r\n')), 'un PNG no es un PDF')
comprueba(errorDeLaBase('54000')?.estado === 429 && errorDeLaBase('XX000') === null, 'errores de la base')

// ─── El correo ───────────────────────────────────────────────────────────────

const base = {
  remitente: 'Helios <hola@conhelios.com>',
  doctor: 'Dra. Ana Lara',
  doctorCorreo: 'ana@example.com',
  paciente: 'Pedro Pérez',
  correo: 'pedro@example.com',
  numero: 12,
  pdfBase64: 'QUJD',
  enlacePrecios: null as string | null,
}
const correo = armarCorreo(base)
comprueba(correo.from === '"Dra. Ana Lara vía Helios" <hola@conhelios.com>', 'el remitente', correo.from)
comprueba(correo.to[0] === 'pedro@example.com', 'el destinatario')
comprueba(correo.reply_to === 'ana@example.com', 'responder va al médico')
comprueba(correo.subject === 'Tu récipe de Dra. Ana Lara', 'el asunto', correo.subject)
comprueba(correo.attachments[0].filename === 'Recipe-000012.pdf' && correo.attachments[0].content === 'QUJD', 'el adjunto')
comprueba(correo.html.includes('https://conhelios.com/correo/logo-helios.png'), 'lleva el logo')
for (const cuerpo of [correo.text, correo.html]) {
  comprueba(cuerpo.includes('Pedro Pérez') && cuerpo.includes('te envió tu récipe') && cuerpo.includes('adjunto en PDF'), 'saludo y aviso')
  comprueba(cuerpo.includes('farmacia') && cuerpo.includes('Indicaciones'), 'para qué es cada hoja')
  comprueba(!/préstamo|financiamiento|financiar|crédito|\bfee\b/i.test(cuerpo), 'sin palabras prohibidas')
  comprueba(!/validez|legal|toda farmacia|cualquier farmacia/i.test(cuerpo), 'sin promesas')
}
comprueba(armarCorreo({ ...base, doctorCorreo: '' }).reply_to === undefined, 'sin correo del médico no hay reply_to')

const hostil = armarCorreo({ ...base, doctor: 'Dr. "<b>X</b>"\r\nBcc: y', paciente: '<script>alert(1)</script> & Co' })
comprueba(!hostil.html.includes('<script>') && hostil.html.includes('&lt;script&gt;'), 'el HTML va escapado')
comprueba(!hostil.html.includes('<b>X</b>'), 'el nombre del médico va escapado')
comprueba(!/[\r\n]/.test(hostil.subject) && !/[\r\n]/.test(hostil.from), 'sin saltos en el asunto ni en el remitente')
comprueba(hostil.from.startsWith('"Dr. bXb/b') || !/[<>]/.test(hostil.from.split(' <')[0]), 'el nombre del remitente, sin < ni >', hostil.from)

let lanzo = false
try {
  armarCorreo({ ...base, remitente: 'sin dirección' })
} catch {
  lanzo = true
}
comprueba(lanzo, 'sin dirección de remitente no se arma')

// ─── El enlace a las farmacias y precios ─────────────────────────────────────

const TOKEN = 'a'.repeat(32)
comprueba(enlaceDePrecios(TOKEN, true) === `https://conhelios.com/rx/#/medicinas/${TOKEN}`, 'el enlace va en el hash')
comprueba(enlaceDePrecios(TOKEN, false) === null, 'sin precios no hay enlace')
comprueba(enlaceDePrecios(TOKEN, undefined) === null, 'si la base no lo dice, no hay enlace')
comprueba(enlaceDePrecios('../otra', true) === null && enlaceDePrecios(undefined, true) === null, 'un token raro no arma enlace')

comprueba(!correo.html.includes('medicinas') && !correo.text.includes('medicinas'), 'sin precios el correo no lo menciona')
const conPrecios = armarCorreo({ ...base, enlacePrecios: enlaceDePrecios(TOKEN, true) })
for (const cuerpo of [conPrecios.text, conPrecios.html]) {
  comprueba(cuerpo.includes(`/rx/#/medicinas/${TOKEN}`), 'lleva el enlace')
  comprueba(cuerpo.includes('Tu médico no elige estas farmacias'), 'dice que no es cosa del médico')
  comprueba(!/recomienda|la mejor|más barat/i.test(cuerpo), 'no recomienda una farmacia')
  comprueba(!/préstamo|financiamiento|financiar|crédito|\bfee\b/i.test(cuerpo), 'sin palabras prohibidas')
}

// ─── El manejador ────────────────────────────────────────────────────────────

const ENVIO: DatosEnvio = {
  envio_id: 'e1',
  pdf_path: 'm/recipes/r.pdf',
  numero: 7,
  paciente_nombre: 'Pedro Pérez',
  doctor_nombre: 'Dra. Ana Lara',
  doctor_correo: 'ana@example.com',
  correo: 'pedro@example.com',
}

type Anotado = { estado: string; provider: string | null; error: string | null }

function dobles(cambios: Partial<Dependencias> = {}) {
  const anotados: Anotado[] = []
  const enviados: { clave: string; idem: string; cuerpo: any }[] = []
  const deps: Dependencias = {
    usuario: async (a) => (a === 'Bearer bueno' ? 'u1' : null),
    prepararEnvio: async () => ({ data: ENVIO, error: null }),
    claveResend: async () => 'clave',
    remitente: async () => 'Helios <hola@conhelios.com>',
    bajarPdf: async () => new TextEncoder().encode('%PDF-1.7'),
    anotarResultado: async (_id, estado, provider, error) => {
      anotados.push({ estado, provider, error })
    },
    mandarResend: async (clave, idem, cuerpo) => {
      enviados.push({ clave, idem, cuerpo })
      return { ok: true, estado: 200, id: 'prov-1', mensaje: null }
    },
    aBase64: (b) => Buffer.from(b).toString('base64'),
    datosPrecios: async () => ({ token_precios: 'b'.repeat(32), hay_precios: true }),
    ...cambios,
  }
  return { manejar: crearManejador(deps), anotados, enviados }
}

function peticion(auth = 'Bearer bueno', cuerpo: unknown = { recipe_id: ID, correo: 'pedro@example.com' }, origen = 'http://localhost:3002') {
  return new Request('https://x.test/rx-enviar', {
    method: 'POST',
    headers: { Authorization: auth, Origin: origen, 'Content-Type': 'application/json' },
    body: typeof cuerpo === 'string' ? cuerpo : JSON.stringify(cuerpo),
  })
}

async function principal() {
  // El enlace llega al correo por la service_role, y si falla el récipe sale igual.
  let conEnlace = dobles()
  let respuesta = await conEnlace.manejar(peticion())
  comprueba(respuesta.status === 200 && conEnlace.enviados[0].cuerpo.text.includes(`/rx/#/medicinas/${'b'.repeat(32)}`), 'el correo lleva el enlace')
  comprueba(!JSON.stringify(await respuesta.json()).includes('b'.repeat(32)), 'el médico no recibe el enlace en la respuesta')
  conEnlace = dobles({ datosPrecios: async () => { throw new Error('caída') } })
  respuesta = await conEnlace.manejar(peticion())
  comprueba(respuesta.status === 200 && !conEnlace.enviados[0].cuerpo.text.includes('medicinas'), 'si fallan los precios, el récipe sale sin enlace')
  conEnlace = dobles({ datosPrecios: async () => ({ token_precios: 'b'.repeat(32), hay_precios: false }) })
  await conEnlace.manejar(peticion())
  comprueba(!conEnlace.enviados[0].cuerpo.text.includes('medicinas'), 'sin precios no hay enlace')

  let d = dobles()
  let r = await d.manejar(new Request('https://x.test', { method: 'OPTIONS', headers: { Origin: 'http://localhost:3002' } }))
  comprueba(r.status === 204 && r.headers.get('Access-Control-Allow-Origin') === 'http://localhost:3002', 'OPTIONS con CORS')

  r = await d.manejar(new Request('https://x.test', { method: 'GET' }))
  comprueba(r.status === 405, 'GET → 405')

  r = await d.manejar(new Request('https://x.test', { method: 'POST', body: '{}' }))
  let j = await r.json()
  comprueba(r.status === 401 && j.error === 'sin_sesion' && Boolean(j.mensaje), 'sin JWT → 401')

  r = await d.manejar(peticion('Bearer malo'))
  comprueba(r.status === 401, 'JWT que no vale → 401')

  r = await d.manejar(peticion('Bearer bueno', 'no es json'))
  comprueba(r.status === 400, 'cuerpo que no es JSON → 400')

  r = await d.manejar(peticion('Bearer bueno', { recipe_id: 'x', correo: 'a@b.co' }))
  comprueba(r.status === 400 && d.anotados.length === 0, 'id malo → 400, sin anotar')

  // La base dice que no: se le pasa su mensaje al médico.
  for (const [code, estado] of [['42501', 403], ['P0002', 404], ['54000', 429], ['22023', 400]] as const) {
    d = dobles({ prepararEnvio: async () => ({ data: null, error: { code, message: 'Mensaje de la base.' } }) })
    r = await d.manejar(peticion())
    j = await r.json()
    comprueba(r.status === estado && j.mensaje === 'Mensaje de la base.' && d.enviados.length === 0 && d.anotados.length === 0, `base ${code} → ${estado}`)
  }
  d = dobles({ prepararEnvio: async () => ({ data: null, error: { code: 'XX000', message: 'detalle interno' } }) })
  r = await d.manejar(peticion())
  j = await r.json()
  comprueba(r.status === 500 && !j.mensaje.includes('interno'), 'un error desconocido no se le enseña al médico')

  // Sin clave o sin remitente.
  for (const cambio of [{ claveResend: async () => null }, { remitente: async () => null }]) {
    d = dobles(cambio)
    r = await d.manejar(peticion())
    j = await r.json()
    comprueba(r.status === 503 && j.error === 'no_configurado' && d.anotados[0]?.estado === 'fallido' && d.enviados.length === 0, 'sin configurar → 503, fallido')
  }

  // El PDF.
  d = dobles({ bajarPdf: async () => { throw new Error('no está') } })
  r = await d.manejar(peticion())
  comprueba(r.status === 502 && d.anotados[0]?.estado === 'fallido' && d.enviados.length === 0, 'sin PDF → fallido')
  d = dobles({ bajarPdf: async () => new TextEncoder().encode('\x89PNG') })
  r = await d.manejar(peticion())
  comprueba(r.status === 502 && d.anotados[0]?.estado === 'fallido' && d.enviados.length === 0, 'no es PDF → fallido')
  d = dobles({ bajarPdf: async () => new Uint8Array(5 * 1024 * 1024 + 1) })
  r = await d.manejar(peticion())
  comprueba(r.status === 502 && d.anotados[0]?.estado === 'fallido' && d.enviados.length === 0, 'más de 5 MB → fallido')

  // Resend.
  d = dobles({ mandarResend: async () => ({ ok: false, estado: 422, id: null, mensaje: 'Inválido' }) })
  r = await d.manejar(peticion())
  j = await r.json()
  comprueba(r.status === 502 && d.anotados[0]?.estado === 'fallido' && d.anotados[0]?.error === 'Resend 422: Inválido' && !j.mensaje.includes('422'), 'Resend rechaza → fallido')
  d = dobles({ mandarResend: async () => { throw new Error('timeout') } })
  r = await d.manejar(peticion())
  comprueba(r.status === 502 && d.anotados[0]?.estado === 'fallido' && d.anotados[0]?.error === 'timeout', 'Resend no contesta → fallido')
  d = dobles({ remitente: async () => 'sin dirección' })
  r = await d.manejar(peticion())
  comprueba(r.status === 502 && d.anotados[0]?.estado === 'fallido', 'remitente malo → fallido')

  // El camino bueno.
  d = dobles()
  r = await d.manejar(peticion())
  j = await r.json()
  comprueba(r.status === 200 && j.ok === true, 'envío → {ok:true}')
  comprueba(r.headers.get('Access-Control-Allow-Origin') === 'http://localhost:3002', 'la respuesta lleva CORS')
  comprueba(d.anotados.length === 1 && d.anotados[0].estado === 'enviado' && d.anotados[0].provider === 'prov-1', 'queda como enviado')
  comprueba(d.enviados[0].idem === 'e1' && d.enviados[0].clave === 'clave', 'Idempotency-Key es el envío')
  comprueba(d.enviados[0].cuerpo.attachments[0].filename === 'Recipe-000007.pdf', 'el adjunto lleva su número')
  comprueba(d.enviados[0].cuerpo.attachments[0].content === Buffer.from('%PDF-1.7').toString('base64'), 'el PDF va en base64')

  // Si no se puede anotar, el correo ya salió: sigue siendo ok.
  d = dobles({ anotarResultado: async () => { throw new Error('caída') } })
  r = await d.manejar(peticion())
  comprueba(r.status === 200, 'si no se puede anotar, sigue siendo ok')

  console.log(fallos ? `\n${fallos} FALLOS` : '\nTodo en verde')
  if (fallos) process.exit(1)
}

principal()
