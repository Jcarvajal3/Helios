// ═══════════════════════════════════════════════════════════════════════════
// RX — rx-enviar: el manejador HTTP. Todo lo de fuera (Supabase, Resend) llega
// por `Dependencias`, así que las pruebas lo recorren entero sin red.
//
// 1. Sesión: sin un JWT válido, 401.
// 2. `rx_preparar_envio` con el JWT del médico: la base decide si puede, aplica
//    el tope y anota el envío.
// 3. Desde ahí, todo camino termina en `rx_resultado_envio`.
//
// En la consola nunca salen datos del paciente: ni el nombre, ni el correo, ni
// el mensaje de Resend (puede traer la dirección). Ese mensaje queda en el envío.
// ═══════════════════════════════════════════════════════════════════════════

import { armarCorreo, cabecerasCors, errorDeLaBase, esPdf, leerPeticion } from './logica.ts'

const MAX_BYTES = 5 * 1024 * 1024
const NO_SE_PUDO = 'No pudimos enviar el correo. Intenta de nuevo.'

export type ErrorRpc = { message: string; code?: string }

export type DatosEnvio = {
  envio_id: string
  pdf_path: string
  numero: number
  paciente_nombre: string
  doctor_nombre: string
  doctor_correo: string
  correo: string
}

export type RespuestaResend = { ok: boolean; estado: number; id: string | null; mensaje: string | null }

export type Dependencias = {
  /** El id del usuario de ese JWT, o null si no vale. */
  usuario(authorization: string): Promise<string | null>
  /** Con el JWT del médico. */
  prepararEnvio(authorization: string, recipeId: string, correo: string): Promise<{ data: DatosEnvio | null; error: ErrorRpc | null }>
  // De aquí en adelante, con la service_role.
  claveResend(): Promise<string | null>
  remitente(): Promise<string | null>
  bajarPdf(ruta: string): Promise<Uint8Array>
  anotarResultado(envioId: string, estado: 'enviado' | 'fallido', providerId: string | null, error: string | null): Promise<void>
  mandarResend(clave: string, idempotencia: string, cuerpo: unknown): Promise<RespuestaResend>
  aBase64(bytes: Uint8Array): string
}

/** Un fallo después de preparar el envío: lo que se anota y lo que se responde. */
class FalloDeEnvio extends Error {
  constructor(
    readonly estado: number,
    readonly codigo: string,
    readonly mensaje: string,
    readonly detalle: string,
  ) {
    super(detalle)
  }
}

export function crearManejador(deps: Dependencias): (req: Request) => Promise<Response> {
  return async (req) => {
    const cors = cabecerasCors(req.headers.get('Origin'))
    const responder = (estado: number, cuerpo: unknown) =>
      new Response(JSON.stringify(cuerpo), { status: estado, headers: { ...cors, 'Content-Type': 'application/json' } })
    const error = (estado: number, codigo: string, mensaje: string) => responder(estado, { error: codigo, mensaje })

    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors })
    if (req.method !== 'POST') return error(405, 'metodo', 'Solo se admite POST.')

    const authorization = req.headers.get('Authorization') ?? ''
    if (!/^Bearer\s+\S+$/.test(authorization)) return error(401, 'sin_sesion', 'Hace falta iniciar sesión.')
    if (!(await deps.usuario(authorization))) {
      return error(401, 'sin_sesion', 'La sesión no es válida o caducó. Vuelve a iniciar sesión.')
    }

    let cuerpo: unknown
    try {
      cuerpo = await req.json()
    } catch {
      return error(400, 'peticion', 'La petición no es un JSON válido.')
    }
    const peticion = leerPeticion(cuerpo)
    if (!peticion) return error(400, 'peticion', 'Faltan el récipe o el correo.')

    const preparado = await deps.prepararEnvio(authorization, peticion.recipe_id, peticion.correo)
    if (preparado.error || !preparado.data) {
      const conocido = errorDeLaBase(preparado.error?.code)
      if (conocido) return error(conocido.estado, conocido.error, preparado.error!.message)
      console.error('rx-enviar: rx_preparar_envio falló', preparado.error?.code ?? 'sin código')
      return error(500, 'preparar', NO_SE_PUDO)
    }
    const envio = preparado.data

    try {
      const [clave, remitente] = await Promise.all([deps.claveResend(), deps.remitente()])
      if (!clave || !remitente) {
        const falta = !clave ? 'Falta la clave de Resend' : 'Falta el remitente'
        throw new FalloDeEnvio(503, 'no_configurado', 'El envío de correos todavía no está configurado en Helios.', falta)
      }

      let pdf: Uint8Array
      try {
        pdf = await deps.bajarPdf(envio.pdf_path)
      } catch (e) {
        const detalle = `No se pudo bajar el PDF: ${e instanceof Error ? e.message : String(e)}`
        throw new FalloDeEnvio(502, 'pdf', 'No encontramos el PDF de este récipe. Vuelve a generarlo.', detalle)
      }
      if (pdf.length > MAX_BYTES) {
        throw new FalloDeEnvio(502, 'pdf', 'El PDF de este récipe pesa demasiado.', `El PDF pesa ${pdf.length} bytes`)
      }
      if (!esPdf(pdf)) {
        throw new FalloDeEnvio(502, 'pdf', 'El archivo de este récipe no es un PDF. Vuelve a generarlo.', 'El archivo no es un PDF')
      }

      const correo = armarCorreo({
        remitente,
        doctor: envio.doctor_nombre,
        doctorCorreo: envio.doctor_correo,
        paciente: envio.paciente_nombre,
        correo: envio.correo,
        numero: envio.numero,
        pdfBase64: deps.aBase64(pdf),
      })

      const resend = await deps.mandarResend(clave, envio.envio_id, correo)
      if (!resend.ok) {
        console.error('rx-enviar: Resend respondió', resend.estado)
        throw new FalloDeEnvio(502, 'resend', NO_SE_PUDO, `Resend ${resend.estado}: ${resend.mensaje ?? ''}`)
      }

      await anotar(deps, envio.envio_id, 'enviado', resend.id, null)
      return responder(200, { ok: true })
    } catch (e) {
      const fallo =
        e instanceof FalloDeEnvio
          ? e
          : new FalloDeEnvio(502, 'envio', NO_SE_PUDO, e instanceof Error ? e.message : String(e))
      await anotar(deps, envio.envio_id, 'fallido', null, fallo.detalle)
      return error(fallo.estado, fallo.codigo, fallo.mensaje)
    }
  }
}

/** Si no se puede anotar, el correo ya salió o ya falló: no cambia la respuesta. */
async function anotar(
  deps: Dependencias,
  envioId: string,
  estado: 'enviado' | 'fallido',
  providerId: string | null,
  detalle: string | null,
): Promise<void> {
  try {
    await deps.anotarResultado(envioId, estado, providerId, detalle)
  } catch {
    console.error('rx-enviar: no se pudo anotar el resultado del envío', envioId)
  }
}
