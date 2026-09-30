import * as Sentry from '@sentry/react'

/**
 * Errores del panel a Sentry.
 *
 * Sin `VITE_SENTRY_DSN` no hace nada: en local, y en cualquier despliegue que
 * no la tenga, el panel funciona igual y no manda nada a ninguna parte.
 *
 * Solo en el navegador. El servidor de Vercel pinta el armazón vacío y todos
 * los datos se piden desde la tablet, así que lo que se rompe, se rompe aquí.
 */
const dsn = import.meta.env.VITE_SENTRY_DSN as string | undefined

let iniciado = false

export function initSentry() {
  if (iniciado || typeof window === 'undefined' || !dsn) return
  iniciado = true

  Sentry.init({
    dsn,
    environment:
      (import.meta.env.VITE_SENTRY_ENVIRONMENT as string | undefined) ?? import.meta.env.MODE,
    // Ni IP ni cookies: el panel enseña nombres, cédulas y montos, y nada de
    // eso tiene que salir del sistema para depurar un fallo.
    sendDefaultPii: false,
    // Solo errores. El rendimiento gasta la cuota y no es lo que hoy falta ver.
    tracesSampleRate: 0,
    ignoreErrors: [
      // El navegador lo lanza cuando un observador tarda un fotograma; no
      // rompe nada y en una tablet sale a cada rato.
      'ResizeObserver loop',
      // Sin red. `describeError` ya se lo dice al cajero, y el indicador de
      // conexión lo pinta: en Sentry solo sería ruido de cada wifi del local.
      'Failed to fetch',
      'NetworkError when attempting to fetch resource',
      'Load failed',
    ],
  })
}

/**
 * Un error que React atrapó. Los atrapa el router antes de que lleguen a
 * `window.onerror`, así que Sentry no los vería solo.
 */
export function reportarError(error: unknown, extra?: Record<string, unknown>) {
  if (!iniciado) return
  Sentry.captureException(error, extra ? { extra } : undefined)
}
