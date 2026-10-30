import { createFileRoute } from '@tanstack/react-router'
import { createClient } from '@supabase/supabase-js'

import { INDEXNOW_CLAVE, INDEXNOW_RUTA, PAGINAS_PUBLICAS, SITIO_URL, urlAbsoluta } from '@/config/sitio'
import { consultarDirectorio } from '@/features/directorio/api'
import { paginasPublicas } from '@/features/directorio/paginas'
import { SUPABASE_ANON_KEY, SUPABASE_URL } from '@/lib/supabase'

/**
 * `POST /api/indexnow` — avisa a los buscadores que usan IndexNow (Bing, y
 * por él Copilot, DuckDuckGo y Yahoo) de que el directorio cambió, para que
 * no esperen a volver a rastrear. Lo llama el superadmin al publicar, ocultar
 * o corregir la tarjeta de un médico (`guardarTarjeta`).
 *
 * Manda todas las páginas públicas (`paginasPublicas`): las fijas, las de
 * especialidad y las fichas. IndexNow acepta hasta 10.000 por aviso, así que
 * sobra para miles de médicos, y una página que dejó de existir también se
 * avisa (el buscador ve el 404 y la quita).
 *
 * Solo el equipo (`is_platform_admin()` con la sesión del que llama) y solo
 * en producción (`VERCEL_ENV`): ni local ni las vistas previas avisan de
 * nada. Google no usa IndexNow: a él le llega el sitemap.
 */
export const Route = createFileRoute('/api/indexnow')({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const token = request.headers.get('authorization')?.replace(/^Bearer\s+/i, '') ?? ''
        if (!token) return Response.json({ enviado: false, motivo: 'sin_sesion' }, { status: 401 })

        const comoQuienLlama = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
          global: { headers: { Authorization: `Bearer ${token}` } },
          auth: { persistSession: false, autoRefreshToken: false },
        })
        const { data: esDelEquipo } = await comoQuienLlama.rpc('is_platform_admin')
        if (esDelEquipo !== true) return Response.json({ enviado: false, motivo: 'no_autorizado' }, { status: 403 })

        if (process.env.VERCEL_ENV !== 'production') {
          return Response.json({ enviado: false, motivo: 'solo_produccion' })
        }

        const medicos = await consultarDirectorio().catch(() => [])
        const respuesta = await fetch('https://api.indexnow.org/indexnow', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json; charset=utf-8' },
          body: JSON.stringify({
            host: new URL(SITIO_URL).host,
            key: INDEXNOW_CLAVE,
            keyLocation: urlAbsoluta(INDEXNOW_RUTA),
            urlList: paginasPublicas(PAGINAS_PUBLICAS, medicos).map((p) => urlAbsoluta(p.ruta)),
          }),
        }).catch(() => null)

        return Response.json({ enviado: respuesta?.ok ?? false, estado: respuesta?.status ?? null })
      },
    },
  },
})
