// ═══════════════════════════════════════════════════════════════════════════
// Helios — compras-simulador: el simulador de Compras en Amazon del superadmin
//
// Corre EL MISMO flujo de compras que el bot de WhatsApp, pero con un
// transporte propio: lo que el bot diría se escribe en
// `purchase_simulator_messages` (`sim_compra_mensaje`) y la sesión vive en
// `purchase_simulator_sessions` (`sim_compra_sesion*`). NUNCA llama a
// `helios_whatsapp_*` ni a 360dialog. El panel lee los mensajes con
// `admin_purchase_sim_messages(p_phone)` (no viajan en la respuesta).
//
//   POST /functions/v1/compras-simulador
//   Authorization: Bearer <JWT del administrador>   (verificación JWT normal)
//   { accion: 'diagnostico' }
//   { accion: 'turno', phone, texto?, respuesta?: {id, title}, adjunto?: {receipt_path} }
//   { accion: 'reiniciar', phone }
//   → { ok: true, estado?, proveedor, proveedor_listo } | { ok: false, error }
//
// Autoriza con `admin_purchase_sim_autorizar()` usando el JWT del usuario
// (42501 si no es administrador de la plataforma); lo demás, con service role.
//
// Secretos: RAINFOREST_API_KEY (solo si el proveedor es `rainforest`).
//
// Despliegue (sin Docker; con verificación JWT, NO --no-verify-jwt):
//   supabase functions deploy compras-simulador --use-api \
//     --project-ref ahyfbnfsbyzdoyjzjvfb
// ═══════════════════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2'

import { crearProveedorCatalogo } from '../whatsapp-webhook/compras/catalogo_rainforest.ts'
import type { PersonalCompra } from '../whatsapp-webhook/compras/flujo.ts'
import { ejecutarTurno, leerPeticion, proveedorListo } from './logica.ts'
import type { Respuesta } from './logica.ts'

const URL_BASE = Deno.env.get('SUPABASE_URL') ?? ''
const CLAVE_ANON = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
const CLAVE_RAINFOREST = Deno.env.get('RAINFOREST_API_KEY') ?? ''

const db = createClient(URL_BASE, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', {
  auth: { persistSession: false, autoRefreshToken: false },
})

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function responder(cuerpo: Respuesta, estado = 200): Response {
  return new Response(JSON.stringify(cuerpo), { status: estado, headers: { ...CORS, 'Content-Type': 'application/json' } })
}

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args)
  if (error) throw Object.assign(new Error(`${fn}: ${error.message}`), { code: error.code })
  return data as T
}

/** El personal dueño del teléfono, igual que lo resuelve el webhook (staff_whatsapp_numbers activo). */
async function resolverPersonal(phone: string): Promise<PersonalCompra | null> {
  const { data: n, error } = await db
    .from('staff_whatsapp_numbers')
    .select('id, phone_e164, user_id, merchant_id')
    .eq('phone_e164', phone)
    .is('revoked_at', null)
    .maybeSingle()
  if (error || !n) return null
  const [{ data: clinica }, { data: roles }, { data: nombre }] = await Promise.all([
    db.from('merchants').select('name').eq('id', n.merchant_id).maybeSingle(),
    db.from('merchant_users').select('role').eq('user_id', n.user_id).eq('merchant_id', n.merchant_id).eq('is_active', true).in('role', ['gerente', 'cajero']),
    db.rpc('helios_staff_name', { p_user_id: n.user_id }),
  ])
  // Solo quien tiene un rol activo de la clínica (como el webhook); si tiene los dos, gerente.
  const lista = (roles ?? []).map((r) => r.role)
  const role: 'gerente' | 'cajero' | null = lista.includes('gerente') ? 'gerente' : lista.includes('cajero') ? 'cajero' : null
  if (!role) return null
  return {
    id: n.id,
    phone_e164: n.phone_e164,
    user_id: n.user_id,
    staff_name: typeof nombre === 'string' ? nombre : null,
    role,
    merchant_id: n.merchant_id,
    merchant_name: clinica?.name ?? null,
  }
}

async function proveedorDeLaBase(): Promise<'mock' | 'rainforest'> {
  const cfg = await rpc<{ catalog_provider?: string } | null>('bot_compra_config', {})
  return cfg?.catalog_provider === 'rainforest' ? 'rainforest' : 'mock'
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return responder({ ok: false, error: 'Método no permitido' }, 405)

  // 1. Autorizar con el JWT del usuario: solo administradores de la plataforma.
  const auth = req.headers.get('Authorization') ?? ''
  let adminId = ''
  if (!auth.toLowerCase().startsWith('bearer ')) return responder({ ok: false, error: 'No autorizado' }, 401)
  try {
    const usuario = createClient(URL_BASE, CLAVE_ANON, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: auth } },
    })
    const { data, error } = await usuario.rpc('admin_purchase_sim_autorizar')
    if (!error && typeof data === 'string') adminId = data
    if (error) return responder({ ok: false, error: error.code === '42501' ? 'Solo personal de Helios' : 'No autorizado' }, error.code === '42501' ? 403 : 401)
  } catch {
    return responder({ ok: false, error: 'No autorizado' }, 401)
  }

  let body: unknown
  try {
    body = await req.json()
  } catch {
    return responder({ ok: false, error: 'JSON inválido' }, 400)
  }
  const peticion = leerPeticion(body)
  if ('error' in peticion) return responder({ ok: false, error: peticion.error }, 400)

  try {
    const proveedor = await proveedorDeLaBase()
    const listo = proveedorListo(proveedor, CLAVE_RAINFOREST.trim() !== '')

    if (peticion.accion === 'diagnostico') return responder({ ok: true, proveedor, proveedor_listo: listo })

    if (peticion.accion === 'reiniciar') {
      if (!adminId) return responder({ ok: false, error: 'No autorizado' }, 401)
      await rpc('sim_compra_reiniciar', { p_phone: peticion.phone, p_actor: adminId })
      return responder({ ok: true, proveedor, proveedor_listo: listo })
    }

    const personal = await resolverPersonal(peticion.phone)
    if (!personal) return responder({ ok: false, error: 'Ese teléfono no es de ningún médico o secretaria activos con WhatsApp registrado' }, 404)

    const { estado } = await ejecutarTurno({
      rpc,
      personal,
      peticion,
      idDelTurno: crypto.randomUUID(),
      proveedorDe: (nombre) => crearProveedorCatalogo(nombre, CLAVE_RAINFOREST),
    })
    return responder({ ok: true, estado, proveedor, proveedor_listo: listo })
  } catch (err) {
    // Sin URL ni claves: solo el mensaje.
    console.error('compras-simulador', err instanceof Error ? err.message.replace(/(api_key|token|apikey)=[^&\s"']+/gi, '$1=***') : 'error')
    return responder({ ok: false, error: 'No se pudo completar el turno' }, 500)
  }
})
