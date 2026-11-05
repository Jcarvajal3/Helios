// ═══════════════════════════════════════════════════════════════════════════
// RX — rx-enviar: le manda al paciente su récipe por correo, con el PDF adjunto
// (rx/README.md). No pasa por `outbound_messages`.
//
//   POST { recipe_id, correo }   Authorization: Bearer <jwt del médico>
//   → { ok: true } o { error, mensaje }
//
// Con el JWT del médico llama a `rx_preparar_envio`, así es la base la que
// decide si puede. Con la service_role baja el PDF del bucket privado `rx` (la
// ruta se la da la base), lee la clave de Resend y el remitente y anota el
// resultado (`rx_resultado_envio`). El flujo está en manejador.ts y lo puro en
// logica.ts.
//
// Sin JWT en la pasarela: la propia función comprueba la sesión, para responder
// 401 con `{error, mensaje}` y con sus cabeceras de CORS.
//
// Despliegue (sin Docker):
//   supabase functions deploy rx-enviar --use-api --project-ref ahyfbnfsbyzdoyjzjvfb
// ═══════════════════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2'
import { encodeBase64 } from 'jsr:@std/encoding@1/base64'

import { crearManejador, type DatosEnvio } from './manejador.ts'

const URL_BASE = Deno.env.get('SUPABASE_URL') ?? ''
const CLAVE_ANON = Deno.env.get('SUPABASE_ANON_KEY') ?? ''

const sinSesion = { persistSession: false, autoRefreshToken: false }

const servicio = createClient(URL_BASE, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: sinSesion })

function delMedico(authorization: string) {
  return createClient(URL_BASE, CLAVE_ANON, {
    global: { headers: { Authorization: authorization } },
    auth: sinSesion,
  })
}

async function rpcServicio<T>(nombre: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await servicio.rpc(nombre, args)
  if (error) throw new Error(`${nombre}: ${error.message}`)
  return data as T
}

Deno.serve(
  crearManejador({
    async usuario(authorization) {
      const { data, error } = await delMedico(authorization).auth.getUser()
      return error || !data.user ? null : data.user.id
    },

    async prepararEnvio(authorization, recipeId, correo) {
      const { data, error } = await delMedico(authorization).rpc('rx_preparar_envio', {
        p_id: recipeId,
        p_correo: correo,
      })
      return {
        data: (data as DatosEnvio | null) ?? null,
        error: error ? { message: error.message, code: error.code } : null,
      }
    },

    claveResend: () => rpcServicio<string | null>('helios_resend_api_key'),
    remitente: () => rpcServicio<string | null>('helios_email_sender'),

    async bajarPdf(ruta) {
      const { data, error } = await servicio.storage.from('rx').download(ruta)
      if (error) throw new Error(error.message)
      return new Uint8Array(await data.arrayBuffer())
    },

    async anotarResultado(envioId, estado, providerId, detalle) {
      await rpcServicio('rx_resultado_envio', {
        p_envio_id: envioId,
        p_estado: estado,
        p_provider_id: providerId,
        p_error: detalle,
      })
    },

    async mandarResend(clave, idempotencia, cuerpo) {
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${clave}`,
          'Content-Type': 'application/json',
          'Idempotency-Key': idempotencia,
        },
        body: JSON.stringify(cuerpo),
        signal: AbortSignal.timeout(30_000),
      })
      const datos = await r.json().catch(() => null) as { id?: string; message?: string } | null
      return { ok: r.ok, estado: r.status, id: datos?.id ?? null, mensaje: datos?.message ?? null }
    },

    aBase64: encodeBase64,
  }),
)
