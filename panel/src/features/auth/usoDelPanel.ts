import { useEffect } from 'react'
import { useRouterState } from '@tanstack/react-router'

import { reportarError } from '@/lib/sentry'
import { supabase } from '@/lib/supabase'

// ═══════════════════════════════════════════════════════════════════════════
// El panel avisa de que alguien de la clínica lo está usando.
//
// Superadmin › Seguimiento decide a quién llamar según cuándo usó Helios cada
// persona por última vez. El inicio de sesión no sirve para eso: la sesión
// dura semanas y quien entra todos los días casi nunca pone su contraseña.
// Así que el panel se anota (`helios_staff_seen_in_panel`, que guarda un día de
// uso en `staff_activity_days`) cuando se abre, cuando se vuelve a la pestaña,
// cuando se navega y cuando se toca o se escribe algo. Como mucho una vez cada
// 5 minutos: para «cuándo fue la última vez» no hace falta más.
// ═══════════════════════════════════════════════════════════════════════════

const CADA_MS = 5 * 60_000

let ultimo: { merchantId: string; at: number } | null = null

/** Anota un uso del panel, salvo que ya se anotara hace menos de 5 minutos. */
export function anotarUsoDelPanel(merchantId: string, ahora = Date.now()): void {
  if (ultimo && ultimo.merchantId === merchantId && ahora - ultimo.at < CADA_MS) return
  ultimo = { merchantId, at: ahora }
  void supabase.rpc('helios_staff_seen_in_panel', { p_merchant_id: merchantId }).then(({ error }) => {
    if (!error) return
    // Que lo intente el siguiente gesto; el panel sigue como si nada.
    ultimo = null
    reportarError(error, { donde: 'helios_staff_seen_in_panel' })
  })
}

const GESTOS = ['pointerdown', 'keydown', 'focus'] as const

/** Para el marco del panel de la clínica (`_comercio`). */
export function useUsoDelPanel(merchantId: string): void {
  const ruta = useRouterState({ select: (s) => s.location.pathname })

  // Al abrir el panel y en cada pantalla a la que se navega.
  useEffect(() => {
    anotarUsoDelPanel(merchantId)
  }, [merchantId, ruta])

  useEffect(() => {
    const alUsarlo = () => {
      if (document.visibilityState === 'visible') anotarUsoDelPanel(merchantId)
    }
    document.addEventListener('visibilitychange', alUsarlo)
    for (const g of GESTOS) window.addEventListener(g, alUsarlo, { passive: true })
    return () => {
      document.removeEventListener('visibilitychange', alUsarlo)
      for (const g of GESTOS) window.removeEventListener(g, alUsarlo)
    }
  }, [merchantId])
}
