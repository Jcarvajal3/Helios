import { useEffect } from 'react'
import { useRouterState } from '@tanstack/react-router'

import { GTM_ID } from '@/config/sitio'

/**
 * Las páginas que se miden: el sitio público (portada, médicos, pacientes,
 * afiliación, directorio y su prueba A/B, fichas de médico, las páginas por
 * especialidad, legal y soporte). Es una lista de las que sí, no de las que
 * no: una ruta nueva del panel nunca queda medida por descuido.
 */
const RUTAS_PUBLICAS =
  /^\/(?:$|medicos|pacientes|afiliacion|consultas|directorio|medico\/|consulta-medica-en-cuotas|odontologia-en-cuotas|cosmetologia-en-cuotas|legal\/|soporte)/

/** Para no cargar el contenedor dos veces en la misma pestaña. */
let cargado = false

function cargarGtm() {
  if (cargado || typeof document === 'undefined') return
  cargado = true

  // El código estándar de Google Tag Manager: el aviso de inicio y el script.
  // Después, las navegaciones dentro de la web (sin recargar) las ve el
  // contenedor con su activador «Historial».
  const w = window as unknown as { dataLayer?: unknown[] }
  w.dataLayer = w.dataLayer || []
  w.dataLayer.push({ 'gtm.start': Date.now(), event: 'gtm.js' })

  const script = document.createElement('script')
  script.async = true
  script.src = `https://www.googletagmanager.com/gtm.js?id=${GTM_ID}`
  document.head.appendChild(script)
}

/**
 * Carga Google Tag Manager al entrar en una página pública. Se monta una
 * vez en la raíz: si el visitante llega al panel y luego vuelve a una página
 * pública sin recargar, se carga entonces.
 */
export function GoogleTagManager() {
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const publica = RUTAS_PUBLICAS.test(pathname)

  useEffect(() => {
    if (publica) cargarGtm()
  }, [publica])

  return null
}
