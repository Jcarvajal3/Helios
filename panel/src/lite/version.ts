import { useSyncExternalStore } from 'react'

import { useRolDelEquipo } from '@/features/admin/role'

/**
 * Las dos versiones del superadmin, con las mismas rutas por dentro:
 *
 *   pro   el superadmin de siempre, con su menú por bloques e Inicio.
 *   lite  el diseño y la estructura de la maqueta del rediseño
 *         (Resumen, Operaciones, Personas, Resultados y las herramientas).
 *
 * Es una preferencia de cada navegador, no un permiso: la seguridad sigue en
 * la base. Se guarda en localStorage y se reparte a todas las pestañas
 * abiertas por el evento `storage`.
 *
 * Sin nada guardado, la de su rol: Lite para el super admin y Pro para los
 * demás (Javier, 2026-11-02). En cuanto alguien usa el interruptor, manda lo
 * que eligió.
 */
export type VersionDelAdmin = 'pro' | 'lite'

const CLAVE = 'helios-admin:version'

/** Los que escuchan en esta pestaña: `storage` solo avisa a las demás. */
const oyentes = new Set<() => void>()

/** Lo elegido en este navegador, o `null` si nunca se usó el interruptor. */
function leer(): VersionDelAdmin | null {
  try {
    const guardada = window.localStorage.getItem(CLAVE)
    return guardada === 'lite' || guardada === 'pro' ? guardada : null
  } catch {
    // Modo privado o almacenamiento bloqueado: la de su rol.
    return null
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
    // Sin almacenamiento el cambio no se guarda: igual se avisa.
  }
  for (const avisar of oyentes) avisar()
}

/**
 * La versión que se ve: la elegida en este navegador o, sin elegir, la de su
 * rol. En el servidor y mientras se lee el rol, Pro.
 */
export function useVersionDelAdmin(): VersionDelAdmin {
  const elegida = useSyncExternalStore(suscribir, leer, () => null)
  const rol = useRolDelEquipo()
  return elegida ?? (rol === 'super_admin' ? 'lite' : 'pro')
}
