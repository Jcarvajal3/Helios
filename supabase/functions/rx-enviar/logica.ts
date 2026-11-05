// ═══════════════════════════════════════════════════════════════════════════
// RX — rx-enviar: la lógica pura (CORS, escape, armado del correo). Sin Deno ni
// red, para poder probarla con `npx tsx`. Ver logica.test.ts.
//
// El cuerpo del correo nunca lleva los medicamentos: van solo en el PDF.
// ═══════════════════════════════════════════════════════════════════════════

const ORIGENES = new Set([
  'https://conhelios.com',
  'https://www.conhelios.com',
  'http://localhost:3002',
])

const LOGO = 'https://conhelios.com/correo/logo-helios.png'
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function origenPermitido(origen: string | null): boolean {
  return origen !== null && ORIGENES.has(origen)
}

/** Con un origen que no está en la lista no sale `Access-Control-Allow-Origin`. */
export function cabecerasCors(origen: string | null): Record<string, string> {
  const base: Record<string, string> = {
    Vary: 'Origin',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  }
  if (origen !== null && origenPermitido(origen)) base['Access-Control-Allow-Origin'] = origen
  return base
}

export type Peticion = { recipe_id: string; correo: string }

/** El cuerpo de la petición, o null si no sirve. El correo lo valida la base. */
export function leerPeticion(cuerpo: unknown): Peticion | null {
  if (typeof cuerpo !== 'object' || cuerpo === null) return null
  const { recipe_id, correo } = cuerpo as Record<string, unknown>
  if (typeof recipe_id !== 'string' || !UUID.test(recipe_id)) return null
  if (typeof correo !== 'string' || correo.length === 0 || correo.length > 320) return null
  return { recipe_id, correo }
}

export function escaparHtml(texto: string): string {
  return texto
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

/** En una línea, sin espacios de sobra: para el asunto y el remitente. */
function enUnaLinea(texto: string): string {
  return texto.replace(/\s+/g, ' ').trim()
}

/** Lo que no puede ir en el nombre del remitente de un correo. */
export function limpiarNombre(nombre: string): string {
  return enUnaLinea(nombre.replace(/["<>\\]/g, ''))
}

/** La dirección de `Nombre <correo>` (`helios_email_sender`), o null. */
export function direccionDe(remitente: string): string | null {
  const m = remitente.match(/<([^<>\s]+@[^<>\s]+)>\s*$/)
  return m ? m[1] : null
}

/** «12» → «000012». */
export function numeroConCeros(numero: number): string {
  return String(numero).padStart(6, '0')
}

/** Los primeros bytes de un PDF de verdad. */
export function esPdf(bytes: Uint8Array): boolean {
  return bytes.length > 5 && String.fromCharCode(...bytes.subarray(0, 5)) === '%PDF-'
}

export type DatosCorreo = {
  remitente: string
  doctor: string
  /** Correo del médico, o ''. */
  doctorCorreo: string
  paciente: string
  correo: string
  numero: number
  /** El PDF en base64. */
  pdfBase64: string
}

export type CorreoResend = {
  from: string
  to: string[]
  reply_to?: string
  subject: string
  text: string
  html: string
  attachments: { filename: string; content: string }[]
}

/** Lo que se le manda a Resend. Lanza si el remitente no trae su dirección. */
export function armarCorreo(d: DatosCorreo): CorreoResend {
  const direccion = direccionDe(d.remitente)
  if (!direccion) throw new Error('El remitente no trae una dirección')

  const doctor = enUnaLinea(d.doctor)
  const paciente = enUnaLinea(d.paciente)
  const eDoctor = escaparHtml(doctor)
  const ePaciente = escaparHtml(paciente)

  const text = [
    `Hola, ${paciente}:`,
    '',
    `${doctor} te envió tu récipe. Lo encuentras adjunto en PDF.`,
    '',
    'La hoja Récipe es para la farmacia y la hoja Indicaciones es para ti.',
    '',
    `Si tienes dudas sobre tu tratamiento, consúltalas con ${doctor}.`,
    '',
    'Enviado con Helios',
  ].join('\n')

  const html =
    '<!doctype html><html lang="es"><body style="margin:0;padding:0;background:#F4F6FA">' +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F4F6FA"><tr><td align="center" style="padding:24px 12px">' +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border:1px solid #E3E8F1;border-radius:16px;font-family:\'Source Sans 3\',\'Segoe UI\',Arial,sans-serif;color:#050F2C;font-size:15px;line-height:1.5">' +
    `<tr><td style="padding:24px 28px 8px"><img src="${LOGO}" width="120" height="49" alt="Helios" style="display:block;border:0;color:#002770;font-weight:700;font-size:22px"></td></tr>` +
    '<tr><td style="padding:8px 28px 28px">' +
    `<h1 style="margin:0 0 12px;font-family:Outfit,'Segoe UI',Arial,sans-serif;font-size:22px;color:#002770">Hola, ${ePaciente}</h1>` +
    `<p style="margin:0 0 12px"><b>${eDoctor}</b> te envió tu récipe. Lo encuentras adjunto en PDF.</p>` +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#E8F3FF;border-radius:12px;margin:8px 0 16px"><tr><td style="padding:14px 18px">' +
    '<p style="margin:0 0 4px"><b>Hoja Récipe:</b> para la farmacia.</p>' +
    '<p style="margin:0"><b>Hoja Indicaciones:</b> para ti.</p>' +
    '</td></tr></table>' +
    `<p style="margin:0;color:#6B7690;font-size:13px">Si tienes dudas sobre tu tratamiento, consúltalas con ${eDoctor}.</p>` +
    '</td></tr></table>' +
    '<p style="margin:16px 0 0;color:#6B7690;font-size:12px;font-family:Arial,sans-serif">Enviado con Helios</p>' +
    '</td></tr></table></body></html>'

  const correo: CorreoResend = {
    // Entre comillas: «Dra.» lleva un punto, que sin ellas no vale en un nombre.
    from: `"${limpiarNombre(d.doctor)} vía Helios" <${direccion}>`,
    to: [d.correo],
    subject: `Tu récipe de ${doctor}`,
    text,
    html,
    attachments: [{ filename: `Recipe-${numeroConCeros(d.numero)}.pdf`, content: d.pdfBase64 }],
  }
  if (d.doctorCorreo.includes('@')) correo.reply_to = d.doctorCorreo
  return correo
}

/** El error de una RPC: qué estado HTTP y qué código, si la base lo dijo a propósito. */
export function errorDeLaBase(codigo: string | undefined): { estado: number; error: string } | null {
  switch (codigo) {
    case '42501':
      return { estado: 403, error: 'sin_permiso' }
    case 'P0002':
      return { estado: 404, error: 'no_existe' }
    case '54000':
      return { estado: 429, error: 'tope' }
    case '22023':
      return { estado: 400, error: 'datos' }
    default:
      return null
  }
}
