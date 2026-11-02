import { useSyncExternalStore } from 'react'

/**
 * Las dos versiones del superadmin, con las mismas pantallas por dentro:
 *
 *   pro   el superadmin de siempre, con su menú por bloques e Inicio.
 *   lite  el menú simplificado (Resumen, Operaciones, Personas, Resultados y
 *         las herramientas), con pestañas por sección y el Resumen como
 *         portada. Cada pestaña abre la pantalla real de Pro, así que no se
 *         pierde ninguna acción ni ninguna regla: solo cambia cómo se llega.
 *
 * Es una preferencia de cada navegador, no un permiso: la seguridad sigue en
 * la base. Se guarda en localStorage y se reparte a todas las pestañas
 * abiertas por el evento `storage`.
 */
export type VersionDelAdmin = 'pro' | 'lite'

const CLAVE = 'helios-admin:version'

/** Los que escuchan en esta pestaña: `storage` solo avisa a las demás. */
const oyentes = new Set<() => void>()

function leer(): VersionDelAdmin {
  try {
    return window.localStorage.getItem(CLAVE) === 'lite' ? 'lite' : 'pro'
  } catch {
    // Modo privado o almacenamiento bloqueado: Pro, que es el de siempre.
    return 'pro'
  }
}

function suscribir(avisar: () => void): () => void {
  oyentes.add(avisar)
  const alCambiarEnOtra = (e: StorageEvent) => {
    if (e.key === CLAVE) avisar()
  }
  window.addEventListener('storage', alCambiarEnOtra)
  return () => {
    oyentes.delete(avisar)
    window.removeEventListener('storage', alCambiarEnOtra)
  }
}

export function cambiarVersionDelAdmin(version: VersionDelAdmin): void {
  try {
    window.localStorage.setItem(CLAVE, version)
  } catch {
    // Sin almacenamiento el cambio dura lo que la pestaña: igual se avisa.
  }
  for (const avisar of oyentes) avisar()
}

/** La versión elegida. En el servidor, Pro: allí no hay localStorage. */
export function useVersionDelAdmin(): VersionDelAdmin {
  return useSyncExternalStore(suscribir, leer, () => 'pro')
}
