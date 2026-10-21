/**
 * Pruebas de lo que el webhook entiende de cada mensaje.
 *
 *   npx tsx supabase/functions/whatsapp-webhook/logica.test.ts
 */
import {
  decisionDelBoton,
  decisionDelTexto,
  extraerEventos,
  horaDelEstado,
  igualSeguro,
  normalizar,
} from './logica.ts'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const ID = '3f1c2a9e-7b4d-4c1e-9a2b-1d2e3f4a5b6c'

console.log('Los eventos')

const cloud = {
  object: 'whatsapp_business_account',
  entry: [
    {
      id: 'WABA',
      changes: [
        {
          field: 'messages',
          value: {
            messaging_product: 'whatsapp',
            contacts: [{ wa_id: '584141234567', profile: { name: 'José' } }],
            messages: [
              { id: 'wamid.T', from: '584141234567', type: 'text', text: { body: 'Sí' } },
              {
                id: 'wamid.I',
                from: '584141234567',
                type: 'interactive',
                interactive: { type: 'button_reply', button_reply: { id: `confirmar:${ID}`, title: 'Sí, acepto' } },
              },
              {
                id: 'wamid.B',
                from: '584141234567',
                type: 'button',
                button: { payload: `rechazar:${ID}`, text: 'No' },
              },
            ],
            statuses: [
              {
                id: 'wamid.S',
                status: 'failed',
                timestamp: '1759690800',
                errors: [{ code: 131026, title: 'Message undeliverable' }],
              },
            ],
          },
        },
      ],
    },
  ],
}

const eventos = extraerEventos(cloud)
const mensajes = eventos.filter((e) => e.kind === 'message')
const estados = eventos.filter((e) => e.kind === 'status')
comprueba(mensajes.length === 3 && estados.length === 1, 'tres mensajes y un estado', JSON.stringify(eventos))

const [t, i, b] = mensajes
comprueba(t?.kind === 'message' && t.texto === 'Sí' && t.boton === null, 'un texto')
comprueba(
  i?.kind === 'message' && i.boton === `confirmar:${ID}` && i.texto === 'Sí, acepto',
  'un botón interactivo',
)
comprueba(b?.kind === 'message' && b.boton === `rechazar:${ID}` && b.texto === 'No', 'un botón de plantilla')

const s = estados[0]
comprueba(
  s?.kind === 'status' && s.status === 'failed' && s.error?.code === 131026 && s.timestamp === '1759690800',
  'un estado con su error',
)
comprueba(horaDelEstado('1759690800') === '2025-10-05T19:00:00.000Z', 'la hora de un estado')
comprueba(horaDelEstado(null) === null && horaDelEstado('ayer') === null, 'una hora rara es null')

const onPremise = { messages: [{ id: 'wamid.P', from: '58414', type: 'text', text: { body: 'hola' } }] }
comprueba(extraerEventos(onPremise).length === 1, 'el formato on-premise también')
comprueba(extraerEventos(null).length === 0 && extraerEventos('x').length === 0, 'basura: nada')
comprueba(
  extraerEventos({ entry: [{ changes: [{ value: { messages: [{ type: 'text' }] } }] }] }).length === 0,
  'un mensaje sin id ni remitente se ignora',
)

const conFoto = {
  messages: [
    { id: 'wamid.F', from: '58414', type: 'image', image: { id: 'media-9', mime_type: 'image/jpeg', sha256: 'x' } },
    { id: 'wamid.D', from: '58414', type: 'document', document: { id: 'media-10', mime_type: 'application/pdf', filename: 'pago.pdf' } },
  ],
}
const [foto, pdf] = extraerEventos(conFoto)
comprueba(
  foto.kind === 'message' && foto.adjunto?.id === 'media-9' && foto.adjunto.mime === 'image/jpeg',
  'una foto trae su adjunto',
)
comprueba(pdf.kind === 'message' && pdf.adjunto?.mime === 'application/pdf', 'un PDF también')
comprueba(
  extraerEventos(onPremise).every((e) => e.kind === 'message' && e.adjunto === null),
  'un texto no trae adjunto',
)

console.log('\nLas decisiones')
comprueba(decisionDelBoton(`confirmar:${ID}`)?.decision === 'si', 'confirmar es sí')
comprueba(decisionDelBoton(`rechazar:${ID.toUpperCase()}`)?.chargeId === ID, 'el id va en minúsculas')
comprueba(decisionDelBoton(`rechazar:${ID}`)?.decision === 'no', 'rechazar es no')
comprueba(decisionDelBoton('confirmar:123') === null && decisionDelBoton(null) === null, 'un botón ajeno no decide')

for (const si of ['Sí', 'si', 'SI', 'sí!', ' Sí, acepto ', 'Acepto', 'si acepto 👍']) {
  comprueba(decisionDelTexto(si) === 'si', `«${si}» es sí`)
}
for (const no of ['No', 'NO.', 'no acepto']) {
  comprueba(decisionDelTexto(no) === 'no', `«${no}» es no`)
}
for (const nada of ['si claro pero tengo una duda', 'hola', '1234', '', 'nop', 'sii']) {
  comprueba(decisionDelTexto(nada) === null, `«${nada}» no decide nada`)
}
comprueba(normalizar('  ¡Sí,   ACEPTO! ') === 'si acepto', 'normalizar')
// La moneda (bot.ts / datos.ts): el título del botón se normaliza a palabras;
// los símbolos se pierden, por eso `leerMoneda` mira «$» y «€» en crudo.
comprueba(normalizar('Dólares (USD)') === 'dolares usd' && normalizar('Euros (EUR)') === 'euros eur', 'normalizar los botones de moneda')
comprueba(normalizar('€80') === '80' && normalizar('$') === '', 'normalizar quita $ y €')
for (const moneda of ['euros', 'dólares', '€', 'USD']) {
  comprueba(decisionDelTexto(moneda) === null, `«${moneda}» no decide nada`)
}

console.log('\nEl secreto')
comprueba(igualSeguro('abc', 'abc') && !igualSeguro('abc', 'abd') && !igualSeguro('abc', 'abcd'), 'compara bien')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
