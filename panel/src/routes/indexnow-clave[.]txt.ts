import { createFileRoute } from '@tanstack/react-router'

import { INDEXNOW_CLAVE } from '@/config/sitio'

/**
 * `/indexnow-clave.txt` — la clave de IndexNow, tal cual. Los buscadores la
 * leen para comprobar que el aviso de una página nueva (`/api/indexnow`)
 * viene del dueño de conhelios.com.
 */
export const Route = createFileRoute('/indexnow-clave.txt')({
  server: {
    handlers: {
      GET: () =>
        new Response(INDEXNOW_CLAVE, {
          headers: {
            'Content-Type': 'text/plain; charset=utf-8',
            'Cache-Control': 'public, max-age=86400',
          },
        }),
    },
  },
})
