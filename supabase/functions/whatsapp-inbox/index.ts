// ═══════════════════════════════════════════════════════════════════════════
// Helios — whatsapp-inbox: el Inbox de 360dialog dentro del superadmin
//
// El panel no habla con el Inbox de 360dialog: habla con esta función, que
// guarda el token del Inbox y hace de intermediaria. El navegador nunca ve el
// token, y nadie de fuera del equipo pasa de aquí.
//
//   1. JWT de Supabase obligatorio (verify_jwt = true en config.toml).
//   2. Con ese mismo JWT, `is_platform_admin()`: personal de Helios activo y,
//      si está exigido, con el segundo factor. Si no, 403.
//   3. Cada escritura (contestar, resolver) pasa antes por
//      `admin_whatsapp_inbox_log`, que deja la acción en la bitácora. Si la
//      bitácora no se escribe, al Inbox no llega nada.
//
// Lo que acepta y cómo lo traduce está en logica.ts.
//
// Secretos (supabase secrets set … --project-ref ahyfbnfsbyzdoyjzjvfb):
//   D360_INBOX_URL    https://<stack>.inbox.getchat.360dialog.io
//   D360_INBOX_TOKEN  el token de un usuario del grupo «App integration»
//                     (POST /api/v1/auth/token/ con su usuario y contraseña)
//
// Despliegue (sin Docker):
//   supabase functions deploy whatsapp-inbox --use-api \
//     --project-ref ahyfbnfsbyzdoyjzjvfb
// ═══════════════════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2'

import {
  PAGINAS_POR_FILTRO,
  anotarChats,
  errorDelInbox,
  leerPeticion,
  pagina,
  peticionAlInbox,
  waIdDelChat,
} from './logica.ts'
import type { CodigoDeError, Peticion } from './logica.ts'

/** El Inbox suele contestar en menos de un segundo; un adjunto grande tarda más. */
const ESPERA_MS = 15_000
const ESPERA_ADJUNTO_MS = 30_000

/** Un cuerpo de petición del panel cabe holgado en esto (un texto de 4096). */
const MAX_CUERPO = 32_000

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
}

function json(status: number, cuerpo: unknown): Response {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: {
      ...CORS,
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store',
    },
  })
}

function fallo(
  status: number,
  error: CodigoDeError | string,
  detalle?: string,
): Response {
  return json(status, detalle ? { error, detalle } : { error })
}

/** El cuerpo JSON de la petición, o `null` si no trae (o no es JSON). */
async function leerCuerpo(req: Request): Promise<unknown> {
  if (req.method !== 'POST') return null
  const crudo = await req.text()
  if (crudo.length === 0 || crudo.length > MAX_CUERPO) return null
  try {
    return JSON.parse(crudo)
  } catch {
    return null
  }
}

async function alInbox(
  base: string,
  token: string,
  p: Peticion,
): Promise<{ status: number; cuerpo: unknown; respuesta: Response }> {
  const destino = peticionAlInbox(base, p)
  const respuesta = await fetch(destino.url, {
    method: destino.metodo,
    headers: {
      Authorization: `Token ${token}`,
      Accept: p.tipo === 'adjunto' ? '*/*' : 'application/json',
      ...(destino.cuerpo ? { 'Content-Type': 'application/json' } : {}),
    },
    body: destino.cuerpo ? JSON.stringify(destino.cuerpo) : undefined,
    // El adjunto propio del Inbox redirige (302) a una URL firmada de Google
    // Cloud Storage. fetch la sigue y no le reenvía el Authorization a otro
    // dominio.
    redirect: 'follow',
    signal: AbortSignal.timeout(
      p.tipo === 'adjunto' ? ESPERA_ADJUNTO_MS : ESPERA_MS,
    ),
  })
  if (p.tipo === 'adjunto')
    return { status: respuesta.status, cuerpo: null, respuesta }
  const texto = await respuesta.text()
  let cuerpo: unknown = null
  try {
    cuerpo = texto ? JSON.parse(texto) : null
  } catch {
    cuerpo = null
  }
  return { status: respuesta.status, cuerpo, respuesta }
}

type Base = ReturnType<typeof createClient>

/** El error del Inbox como se le cuenta al panel, con su `reason` si trae. */
function falloDelInbox(
  r: Awaited<ReturnType<typeof alInbox>>,
  error: { status: number; error: CodigoDeError },
  tipo: Peticion['tipo'],
): Response {
  const razon = (r.cuerpo as { reason?: unknown } | null)?.reason
  if (error.error === 'inbox_no_responde')
    console.error('whatsapp-inbox:', tipo, r.status, r.cuerpo)
  return fallo(
    error.status,
    error.error,
    typeof razon === 'string' ? razon : undefined,
  )
}

/**
 * La lista de chats, cada uno con lo que la base sabe de él (`helios`:
 * médico, paciente o `null`). Si se filtra por médicos o pacientes, recorre
 * páginas del Inbox hasta llenar la del panel o hasta `PAGINAS_POR_FILTRO`;
 * `siguiente` dice desde dónde seguir.
 */
async function listarChats(
  db: Base,
  base: string,
  token: string,
  p: Extract<Peticion, { tipo: 'chats' }>,
): Promise<Response> {
  const filas: Record<string, unknown>[] = []
  let desde = p.desde
  let count = 0
  let siguiente: number | null = null

  for (let i = 0; i < (p.quien ? PAGINAS_POR_FILTRO : 1); i++) {
    let r: Awaited<ReturnType<typeof alInbox>>
    try {
      r = await alInbox(base, token, { ...p, desde })
    } catch (e) {
      console.error('whatsapp-inbox: el Inbox no respondió', p.tipo, e)
      return fallo(504, 'inbox_no_responde')
    }
    const error = errorDelInbox(r.status)
    if (error) return falloDelInbox(r, error, p.tipo)

    const pag = pagina(r.cuerpo, desde)
    count = pag.count
    const ids = pag.results
      .map(waIdDelChat)
      .filter((id): id is string => id !== null)
    let quienes: unknown = {}
    if (ids.length > 0) {
      const { data, error: errorDeLaBase } = await db.rpc(
        'admin_whatsapp_inbox_contacts',
        { p_wa_ids: ids },
      )
      // Sin filtro, un fallo de la base solo deja los chats sin etiqueta.
      if (errorDeLaBase && p.quien) return fallo(502, 'base_no_responde')
      if (errorDeLaBase)
        console.error('whatsapp-inbox: quién es cada chat', errorDeLaBase)
      quienes = data
    }
    filas.push(...anotarChats(pag.results, quienes, p.quien))

    siguiente = pag.siguiente
    if (siguiente === null || filas.length >= p.limite) break
    desde = siguiente
  }

  return json(200, { count, results: filas, siguiente })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  const base = Deno.env.get('D360_INBOX_URL') ?? ''
  const token = Deno.env.get('D360_INBOX_TOKEN') ?? ''
  if (!supabaseUrl || !anonKey) return fallo(500, 'mal_configurada')

  const autorizacion = req.headers.get('Authorization') ?? ''
  if (!autorizacion.startsWith('Bearer ')) return fallo(401, 'sin_sesion')

  // Todo lo que se pregunta a la base va con el JWT de quien pide: las
  // mismas reglas que si lo hiciera desde el panel.
  const db = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: autorizacion } },
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const { data: esDelEquipo, error: errorDeAcceso } =
    await db.rpc('is_platform_admin')
  // 42501: el rol de quien llama ni siquiera puede preguntarlo (una clave
  // anónima en vez de una sesión). Es un «no», no una avería.
  if (errorDeAcceso?.code === '42501')
    return fallo(403, 'solo_personal_de_helios')
  if (errorDeAcceso) return fallo(502, 'base_no_responde')
  if (esDelEquipo !== true) return fallo(403, 'solo_personal_de_helios')

  const url = new URL(req.url)
  const p = leerPeticion(req.method, url, await leerCuerpo(req))
  if ('error' in p)
    return fallo(p.error === 'ruta_desconocida' ? 404 : 400, p.error, p.detalle)

  // Sin secretos, el panel enseña cómo configurarlo en vez de un error.
  const configurado = base.startsWith('https://') && token.length > 0
  if (!configurado) {
    return p.tipo === 'estado'
      ? json(200, { configurado: false, conectado: false })
      : fallo(503, 'sin_configurar')
  }

  // La huella antes que el envío: si la bitácora falla, no sale nada.
  if (p.tipo === 'enviar' || p.tipo === 'resolver') {
    const { error } = await db.rpc('admin_whatsapp_inbox_log', {
      p_action:
        p.tipo === 'enviar'
          ? 'whatsapp_inbox.message_sent'
          : 'whatsapp_inbox.chat_resolved',
      p_wa_id: p.waId,
      p_detail:
        p.tipo === 'enviar'
          ? { caracteres: p.texto.length }
          : { resuelto: p.resuelto },
    })
    if (error)
      return fallo(
        error.code === '42501' ? 403 : 502,
        'no_se_pudo_anotar',
        error.message,
      )
  }

  if (p.tipo === 'chats') return listarChats(db, base, token, p)

  let r: Awaited<ReturnType<typeof alInbox>>
  try {
    r = await alInbox(base, token, p)
  } catch (e) {
    console.error('whatsapp-inbox: el Inbox no respondió', p.tipo, e)
    return fallo(504, 'inbox_no_responde')
  }

  const error = errorDelInbox(r.status, p.tipo === 'estado')
  if (p.tipo === 'estado')
    return json(200, { configurado: true, conectado: error === null })
  if (error) return falloDelInbox(r, error, p.tipo)

  switch (p.tipo) {
    case 'mensajes':
      return json(200, pagina(r.cuerpo))
    case 'enviar': {
      const id = (r.cuerpo as { id?: unknown } | null)?.id
      return json(202, { id: typeof id === 'string' ? id : null })
    }
    case 'resolver':
      return json(200, r.cuerpo ?? {})
    case 'adjunto':
      return new Response(r.respuesta.body, {
        status: 200,
        headers: {
          ...CORS,
          'Content-Type':
            p.mime ??
            r.respuesta.headers.get('Content-Type') ??
            'application/octet-stream',
          // Es de un paciente: solo el navegador de quien lo pidió lo guarda.
          'Cache-Control': 'private, max-age=3600',
        },
      })
  }
})
