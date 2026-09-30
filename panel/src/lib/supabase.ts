import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY

if (!url || !key) {
  throw new Error(
    'Faltan VITE_SUPABASE_URL o VITE_SUPABASE_PUBLISHABLE_KEY. Copia .env.example a .env.',
  )
}

/**
 * Cliente de Supabase del panel.
 *
 * La sesión vive solo en el navegador: TanStack Start renderiza en servidor,
 * pero la autenticación del panel es enteramente de cliente. Es lo correcto
 * aquí — el panel es una herramienta interna del local que corre en una
 * tablet fija, no una web pública que necesite SSR autenticado para SEO o
 * primer pintado.
 */
export const supabase = createClient(url, key, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
  },
})

/**
 * Cierra la sesión de ESTE dispositivo, y solo de este.
 *
 * Todo "Salir" del panel pasa por aquí y nunca por `supabase.auth.signOut()`
 * a secas, porque ese lleva por defecto `scope: 'global'`: revoca TODAS las
 * sesiones de la cuenta, en todos los dispositivos. En un local varias
 * tablets pueden compartir la cuenta de caja, y la noche del 2026-09-22 un
 * solo "Cerrar sesión" en una de ellas echó a todas a la vez, hacia la
 * medianoche y con el local abierto.
 *
 * Con `local` se borra el token de esta tablet y las demás siguen cobrando.
 * Echar a una cuenta de todas partes —una baja, una contraseña filtrada— no
 * es algo que se haga desde la barra; eso lo hace el gerente o Ronda.
 */
export function cerrarSesion() {
  return supabase.auth.signOut({ scope: 'local' })
}

/**
 * La URL y la clave pública, sueltas.
 *
 * El cliente de arriba sirve para todo menos para una cosa: la llamada que
 * tiene que salir MIENTRAS la pestaña se está cerrando. Ahí no queda tiempo
 * de esperar a una promesa. Hoy la usa el asistente, que lee la respuesta en
 * streaming con `fetch` (`features/admin/asistente/useAsistente.ts`).
 */
export const SUPABASE_URL = url
export const SUPABASE_ANON_KEY = key

/**
 * Texto útil de un error de Supabase, para enseñárselo a quien está en la
 * barra.
 *
 * Existe porque `error.message` a menudo **no es** lo accionable. PostgREST
 * pone la pista de verdad en `hint`: cuando el panel llamaba a una RPC con
 * una firma que la base no tenía, `message` decía "no se encontró la función"
 * y `hint` decía exactamente cuál era la que sí existía. Enseñar solo el
 * primero convierte un diagnóstico en un misterio.
 *
 * El propio postgrest-js lo avisa en su tipo: "logging only `error.message`
 * hides the hint".
 *
 * Lo que devuelve va a `ErrorBox detail`, que es la línea que de verdad se
 * lee. Por eso aquí no se resume ni se suaviza nada: el título de la caja ya
 * dice qué operación se cayó, y esto tiene que decir por qué.
 */
export function describeError(error: unknown): string | undefined {
  if (!error) return undefined

  // `fetch` falla así cuando no hay red, el proyecto de Supabase está caído o
  // la URL del `.env` apunta a un sitio que no responde. El texto que trae
  // —"Failed to fetch"— no le dice nada a nadie, y sale idéntico para los tres
  // casos, así que se cambia por lo único cierto y accionable de los tres.
  if (error instanceof TypeError && /fetch/i.test(error.message)) {
    return 'No se pudo contactar con el servidor. Comprueba la conexión.'
  }

  if (typeof error === 'object') {
    const e = error as {
      message?: string
      hint?: string
      details?: string
      code?: string
    }
    const parts = [e.message, e.hint, e.details].filter(
      (p): p is string => typeof p === 'string' && p.trim() !== '',
    )

    if (parts.length > 0) return [...new Set(parts)].join(' · ')

    // Sin texto no queda más que el código, y un `23505` a secas es mejor que
    // una caja de error vacía: al menos se puede buscar.
    if (typeof e.code === 'string' && e.code.trim() !== '') return `Error ${e.code}`
  }

  return error instanceof Error ? error.message : undefined
}
