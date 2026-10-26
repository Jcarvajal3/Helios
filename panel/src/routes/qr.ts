import { createFileRoute } from '@tanstack/react-router'

/**
 * A dónde lleva el QR impreso. Para cambiar el destino basta tocar esta
 * constante: el QR (`conhelios.com/qr`) no cambia nunca.
 */
const DESTINO_DEL_QR = '/afiliacion'

/**
 * `/qr` — la dirección fija que llevan los QR impresos (volantes, afiches),
 * hoy hacia la afiliación de médicos. Redirige con un 302 y sin caché, a
 * propósito: un 301 se queda guardado en el teléfono que ya lo escaneó y
 * cambiar el destino no le llegaría. Lo que traiga la dirección
 * (`/qr?origen=feria`) pasa tal cual al destino. El router no distingue
 * mayúsculas: `/QR` también sirve.
 */
export const Route = createFileRoute('/qr')({
  server: {
    handlers: {
      GET: ({ request }) => {
        const destino = new URL(DESTINO_DEL_QR, request.url)
        destino.search = new URL(request.url).search
        return new Response(null, {
          status: 302,
          headers: {
            Location: destino.pathname + destino.search,
            'Cache-Control': 'no-store',
          },
        })
      },
    },
  },
})
