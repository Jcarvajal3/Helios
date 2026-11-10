/**
 * Pruebas de lo que el bot le dice a quien escribe desde el directorio.
 *
 *   npx tsx supabase/functions/whatsapp-webhook/textos_directorio.test.ts
 */
import {
  URL_DE_CONSULTAS,
  URL_DEL_DIRECTORIO,
  digitosDelWhatsApp,
  enlaceAlMedico,
  mensajeAlMedico,
  mensajeContactoDelMedico,
  mensajeMedicoNoDisponible,
  mensajePedirCita,
} from './textos_directorio.ts'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

/** Lo que no se dice hacia fuera (CLAUDE.md, «Nombres»). */
const PROHIBIDO = /pr[eé]stamo|financiamiento|financiar|cr[eé]dito|\bfee\b/i

const ANA = {
  name: 'Dra. Ana Pérez',
  specialty: 'Odontología',
  address: 'Av. Francisco de Miranda, Torre Delta, piso 3',
  city: 'Caracas',
  whatsapp: '+584141234567',
}

console.log('El enlace al médico')
comprueba(digitosDelWhatsApp('+584141234567') === '584141234567', 'E.164 → dígitos con 58')
comprueba(digitosDelWhatsApp('0414-123.45.67') === '584141234567', 'un número nacional también')
comprueba(digitosDelWhatsApp('4141234567') === '584141234567', 'y sin el 0')
comprueba(digitosDelWhatsApp(null) === null && digitosDelWhatsApp('123') === null, 'sin número, null')
comprueba(
  mensajeAlMedico(' Dra. Ana Pérez ') ===
    'Hola, Dra. Ana Pérez. Vi su perfil en el directorio de Helios y quisiera agendar una consulta.',
  'el mensaje de siempre (el de la página)',
)
const enlace = enlaceAlMedico(ANA)
comprueba(
  enlace ===
    `https://wa.me/584141234567?text=${encodeURIComponent('Hola, Dra. Ana Pérez. Vi su perfil en el directorio de Helios y quisiera agendar una consulta.')}`,
  'wa.me con el mensaje ya escrito',
  String(enlace),
)
comprueba(enlaceAlMedico({ name: 'X', whatsapp: null }) === null, 'sin WhatsApp, sin enlace')

console.log('\nEl contacto, con todos los datos')
{
  const t = mensajeContactoDelMedico(ANA)
  console.log(t.replace(/^/gm, '        '))
  comprueba(t.startsWith('💙 ¡Hola!'), 'saluda')
  comprueba(t.includes('*Dra. Ana Pérez*'), 'el nombre del médico')
  comprueba(t.includes('🩺 Odontología'), 'su especialidad')
  comprueba(t.includes('📍 Av. Francisco de Miranda, Torre Delta, piso 3, Caracas'), 'su dirección y su ciudad')
  comprueba(t.includes(String(enlace)), 'el enlace a su WhatsApp')
  comprueba(t.includes('dos cuotas, a los 14 y 28 días, sin inicial'), 'que puede pagar en dos cuotas')
  comprueba(!PROHIBIDO.test(t), 'sin vocabulario prohibido')
  comprueba(!t.includes('$') && !t.includes('Bs'), 'sin montos')
}

console.log('\nEl contacto, sin especialidad ni dirección')
{
  const t = mensajeContactoDelMedico({ name: 'Dr. Luis Gómez', specialty: null, address: null, city: null, whatsapp: '+584241112233' })
  comprueba(t.includes('*Dr. Luis Gómez*'), 'el nombre')
  comprueba(!t.includes('🩺') && !t.includes('📍'), 'no deja líneas vacías de especialidad ni dirección', t)
  comprueba(t.includes('https://wa.me/584241112233?text='), 'el enlace')
  comprueba(!t.includes('null') && !t.includes('undefined'), 'sin «null»')
}
{
  const t = mensajeContactoDelMedico({ ...ANA, address: '  ', city: 'Valencia' })
  comprueba(t.includes('📍 Valencia\n'), 'solo la ciudad', t)
}
{
  const t = mensajeContactoDelMedico({ ...ANA, address: 'C.C. Sambil, Caracas', city: 'caracas' })
  comprueba(t.includes('📍 C.C. Sambil, Caracas\n'), 'no repite la ciudad que ya va en la dirección', t)
}
{
  const t = mensajeContactoDelMedico({ ...ANA, whatsapp: null })
  comprueba(!t.includes('wa.me') && t.includes(URL_DEL_DIRECTORIO), 'sin WhatsApp, al directorio', t)
}

console.log('\nLa variante B pide la cita (docs/06, 2026-11-09)')
{
  const a = mensajeContactoDelMedico(ANA)
  comprueba(
    a.split('\n').at(-1) === 'Puedes pagar tu consulta con Helios en dos cuotas, a los 14 y 28 días, sin inicial.',
    'A cierra con los plazos de siempre',
    String(a.split('\n').at(-1)),
  )
  const b = mensajePedirCita({ name: ' Dra. Ana Pérez ' })
  console.log(b.replace(/^/gm, '        '))
  comprueba(b.startsWith('💙 ¡Hola! Gracias por escribirnos.'), 'saluda')
  comprueba(b.includes('agendar tu consulta con *Dra. Ana Pérez*.'), 'nombra al médico, sin espacios de sobra', b)
  comprueba(b.includes('📅 ¿Qué día te queda mejor?') && b.includes('🕐 ¿A qué hora lo prefieres?'), 'pide el día y la hora')
  comprueba(b.includes('te confirmamos la cita por este chat'), 'dice que la confirmamos por aquí')
  comprueba(!b.includes('wa.me') && !/\+?58\d{10}/.test(b), 'no da el WhatsApp del médico', b)
  comprueba(!b.includes('📍') && !b.includes('🩺'), 'nada más: ni dirección ni especialidad')
  comprueba(!b.includes('14 y 28') && !b.includes('sin inicial') && !b.includes('$') && !b.includes('Bs'), 'ni plazos ni montos', b)
  comprueba(!PROHIBIDO.test(b), 'sin vocabulario prohibido')
}

console.log('\nEl médico que ya no está')
{
  const t = mensajeMedicoNoDisponible()
  console.log(t.replace(/^/gm, '        '))
  comprueba(t.includes('ya no está en nuestro directorio'), 'lo dice')
  comprueba(t.endsWith(URL_DEL_DIRECTORIO), 'enlaza al directorio')
  comprueba(mensajeMedicoNoDisponible('a') === t, "con 'a', igual")
  const b = mensajeMedicoNoDisponible('b')
  comprueba(b.endsWith(URL_DE_CONSULTAS) && !b.includes(URL_DEL_DIRECTORIO), 'desde B, de vuelta a /consultas', b)
  comprueba(!PROHIBIDO.test(t) && !PROHIBIDO.test(b), 'sin vocabulario prohibido')
}

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
