// ═══════════════════════════════════════════════════════════════════════════
// Helios — Lo que el bot le dice a quien escribe desde el directorio
// (docs/04, decisiones de Javier del 2026-10-27). Módulo puro: lo prueba
// `textos_directorio.test.ts`.
//
// «Solo el contacto»: se le da el WhatsApp del médico, con el mensaje de
// siempre ya escrito (el mismo que `mensajeInicial` de la página), y nada
// más. El número de quien escribe no se le pasa al médico.
// ═══════════════════════════════════════════════════════════════════════════

/** La tarjeta del médico, como la devuelve `bot_directorio_interesado`. */
export type TarjetaDelMedico = {
  name: string
  specialty?: string | null
  address?: string | null
  city?: string | null
  /** E.164: '+584141234567'. */
  whatsapp?: string | null
}

export const URL_DEL_DIRECTORIO = 'https://conhelios.com/directorio'

/** Lo que el paciente encuentra escrito al abrir el chat con el médico (= `mensajeInicial` de la página). */
export function mensajeAlMedico(nombre: string): string {
  return `Hola, ${nombre.trim()}. Vi su perfil en el directorio de Helios y quisiera agendar una consulta.`
}

/** Los dígitos de un número venezolano con el 58 delante, o null si no lo es. */
export function digitosDelWhatsApp(numero: string | null | undefined): string | null {
  const d = (numero ?? '').replace(/\D/g, '')
  if (/^58\d{10}$/.test(d)) return d
  if (/^0\d{10}$/.test(d)) return `58${d.slice(1)}`
  if (/^\d{10}$/.test(d)) return `58${d}`
  return null
}

/** El enlace al chat del médico con el mensaje ya escrito, o null sin número. */
export function enlaceAlMedico(t: Pick<TarjetaDelMedico, 'name' | 'whatsapp'>): string | null {
  const d = digitosDelWhatsApp(t.whatsapp)
  return d ? `https://wa.me/${d}?text=${encodeURIComponent(mensajeAlMedico(t.name))}` : null
}

function limpio(v: string | null | undefined): string | null {
  const t = (v ?? '').trim()
  return t === '' ? null : t
}

/** La dirección y la ciudad en una línea, sin repetir la ciudad si ya va en la dirección. */
function lugar(t: TarjetaDelMedico): string | null {
  const direccion = limpio(t.address)
  const ciudad = limpio(t.city)
  if (direccion && ciudad && !direccion.toLowerCase().includes(ciudad.toLowerCase())) return `${direccion}, ${ciudad}`
  return direccion ?? ciudad
}

/** La página de la variante B de la prueba A/B (docs/06). */
export const URL_DE_CONSULTAS = 'https://conhelios.com/consultas'

/**
 * A quien llega desde `/consultas` (variante B, docs/06) el bot ya no le da
 * el WhatsApp del médico (Javier, 2026-11-09): le pide el día y la hora, y
 * nada más. La cita la coordina el equipo desde el superadmin › WhatsApp.
 */
export function mensajePedirCita(t: Pick<TarjetaDelMedico, 'name'>): string {
  return [
    '💙 ¡Hola! Gracias por escribirnos.',
    '',
    `Con gusto te ayudamos a agendar tu consulta con *${t.name.trim()}*.`,
    '',
    'Para coordinarla, cuéntanos por aquí:',
    '📅 ¿Qué día te queda mejor?',
    '🕐 ¿A qué hora lo prefieres?',
    '',
    'Apenas nos respondas, lo coordinamos con tu médico y te confirmamos la cita por este chat.',
  ].join('\n')
}

/**
 * El contacto del médico de la tarjeta, para quien llega desde `/directorio`
 * (variante A). A los de B se les pide la cita (`mensajePedirCita`).
 */
export function mensajeContactoDelMedico(t: TarjetaDelMedico): string {
  const lineas = ['💙 ¡Hola! Gracias por escribirnos.', '', 'Aquí tienes el contacto:', `*${t.name.trim()}*`]
  const especialidad = limpio(t.specialty)
  if (especialidad) lineas.push(`🩺 ${especialidad}`)
  const donde = lugar(t)
  if (donde) lineas.push(`📍 ${donde}`)

  const enlace = enlaceAlMedico(t)
  lineas.push('')
  if (enlace) {
    lineas.push('Escríbele por WhatsApp para agendar tu consulta 👇', enlace)
  } else {
    lineas.push(`Encuentra cómo escribirle en ${URL_DEL_DIRECTORIO}`)
  }
  lineas.push('', 'Puedes pagar tu consulta con Helios en dos cuotas, a los 14 y 28 días, sin inicial.')
  return lineas.join('\n')
}

/**
 * El código no es de una tarjeta publicada: el médico ya no sale (o el código
 * no existe). A quien llegó desde B se le devuelve a `/consultas`, no a
 * `/directorio`, que anuncia otra forma de pago.
 */
export function mensajeMedicoNoDisponible(variante: 'a' | 'b' = 'a'): string {
  return (
    '💙 ¡Hola! Gracias por escribirnos.\n\n' +
    'Ese médico ya no está en nuestro directorio. Aquí puedes ver los médicos disponibles 👇\n' +
    (variante === 'b' ? URL_DE_CONSULTAS : URL_DEL_DIRECTORIO)
  )
}
