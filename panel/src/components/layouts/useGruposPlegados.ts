import { useCallback, useEffect, useState } from 'react'

import type { NavGroup } from '@/config/navigation'

/** Dónde se recuerda qué grupos plegó esta persona. */
const CLAVE_PLEGADOS = 'helios-panel:menu-plegado'

/** Cómo se identifica un grupo, en el almacenamiento y en `aria-controls`. */
export function claveDeGrupo(group: NavGroup, index: number): string {
  return group.espacio ?? group.title ?? String(index)
}

/**
 * Qué grupos del menú plegó esta persona. Por defecto, ninguno.
 *
 * En `localStorage`: es una preferencia de quien usa este navegador y tiene
 * que seguir igual mañana. Se lee después de montar, por lo mismo que el
 * plegado de la barra: en el servidor no hay almacenamiento y sembrarlo allí
 * rompe la hidratación.
 */
export function useGruposPlegados(): {
  plegados: ReadonlyArray<string>
  alternarPlegado: (clave: string) => void
  /** Lo despliega si estaba plegado. No hace nada si ya estaba abierto. */
  desplegar: (clave: string) => void
} {
  const [plegados, setPlegados] = useState<ReadonlyArray<string>>([])

  useEffect(() => {
    try {
      const crudo: unknown = JSON.parse(window.localStorage.getItem(CLAVE_PLEGADOS) ?? '[]')
      if (Array.isArray(crudo)) {
        setPlegados(crudo.filter((c): c is string => typeof c === 'string'))
      }
    } catch {
      // Almacenamiento bloqueado o un valor roto: todo desplegado, que es el
      // valor por defecto.
    }
  }, [])

  const cambiar = useCallback((cambio: (previos: ReadonlyArray<string>) => ReadonlyArray<string>) => {
    setPlegados((previos) => {
      const siguientes = cambio(previos)
      if (siguientes === previos) return previos
      try {
        window.localStorage.setItem(CLAVE_PLEGADOS, JSON.stringify(siguientes))
      } catch {
        // Se pierde al recargar y no pasa nada.
      }
      return siguientes
    })
  }, [])

  const alternarPlegado = useCallback(
    (clave: string) =>
      cambiar((previos) =>
        previos.includes(clave) ? previos.filter((c) => c !== clave) : [...previos, clave],
      ),
    [cambiar],
  )

  const desplegar = useCallback(
    (clave: string) =>
      cambiar((previos) => (previos.includes(clave) ? previos.filter((c) => c !== clave) : previos)),
    [cambiar],
  )

  return { plegados, alternarPlegado, desplegar }
}
