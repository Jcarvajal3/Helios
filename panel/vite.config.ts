import { defineConfig } from 'vite'
import { devtools } from '@tanstack/devtools-vite'

import { tanstackStart } from '@tanstack/react-start/plugin/vite'
import { nitro } from 'nitro/vite'

import viteReact from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { sentryVitePlugin } from '@sentry/vite-plugin'

// Los source maps solo se generan si hay a dónde subirlos: con
// SENTRY_AUTH_TOKEN (más SENTRY_ORG y SENTRY_PROJECT) en el entorno de Vercel.
// Se suben y se borran del build, así que nunca se sirven al público. Sin el
// token, el build es el de siempre.
const subirMapas = Boolean(process.env.SENTRY_AUTH_TOKEN)

const config = defineConfig({
  resolve: { tsconfigPaths: true },
  build: {
    sourcemap: subirMapas ? 'hidden' : false,
    // El servidor sale partido en trozos que se importan entre sí. Sin esto,
    // rolldown no garantiza el orden de evaluación entre trozos con ciclo, y un
    // valor importado se lee antes de existir: tumbó la web entera el
    // 2026-09-25 («TRAMOS_VENCIDOS is not iterable») sin que tsc, las pruebas
    // ni el build lo vieran, porque solo pasa al arrancar el servidor.
    rolldownOptions: { output: { strictExecutionOrder: true } },
  },
  plugins: [
    devtools(),
    tailwindcss(),
    tanstackStart(),
    nitro({
      // Cabeceras de seguridad en todas las respuestas (producción desde el
      // 2026-10-08). Nadie puede meter el panel en un iframe (clickjacking);
      // la CSP completa queda fuera a propósito: la portada carga fuentes de
      // Google y shaders, y una política mal hecha la rompe sin avisar.
      // Van como ruta de Vercel y no como `routeRules`: el preset de Nitro
      // escribe esas reglas sin `continue: true`, y una ruta solo de
      // cabeceras sin `continue` corta el enrutado antes de llegar al
      // servidor.
      vercel: {
        config: {
          version: 3,
          routes: [
            {
              src: '/(.*)',
              headers: {
                'X-Frame-Options': 'DENY',
                'Content-Security-Policy': "frame-ancestors 'none'",
                'X-Content-Type-Options': 'nosniff',
                'Referrer-Policy': 'strict-origin-when-cross-origin',
                'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
              },
              continue: true,
            },
          ],
        },
      },
    }),
    viteReact(),
    subirMapas &&
      sentryVitePlugin({
        org: process.env.SENTRY_ORG,
        project: process.env.SENTRY_PROJECT,
        authToken: process.env.SENTRY_AUTH_TOKEN,
        telemetry: false,
        sourcemaps: {
          // Solo lo que corre en la tablet; el servidor pinta el armazón vacío.
          // Nitro deja el cliente en `.output/public` en local y en
          // `.vercel/output/static` con el preset de Vercel.
          assets: ['./.output/public/**', './.vercel/output/static/**'],
          filesToDeleteAfterUpload: [
            './.output/public/**/*.map',
            './.vercel/output/static/**/*.map',
          ],
        },
        // Una subida fallida no puede tumbar un despliegue del panel.
        errorHandler: (err) => console.warn('[sentry] ', err),
      }),
  ],
})

export default config
