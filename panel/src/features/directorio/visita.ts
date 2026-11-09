import { useEffect, useRef } from 'react'
import { useMatch } from '@tanstack/react-router'

import { apuntarVisita } from './api'
import type { VarianteDelDirectorio } from './directorio'

/**
 * Apunta la visita a una página del directorio (prueba A/B, docs/06): una
 * vez por página montada y por ruta, solo en el navegador.
 *
 * - En desarrollo, React (StrictMode) monta, desmonta y vuelve a montar: el
 *   `ref` sobrevive a ese ensayo, así que la misma carga no se apunta dos
 *   veces.
 * - La ruta es la de la página que la llama (su `match`), no la de la
 *   barra: al ir de `/directorio` a `/directorio/odontologia`, la página
 *   que se va ya ve la dirección nueva antes de desmontarse y, con la de la
 *   barra, la apuntaba otra vez.
 * - Cambiar el filtro (`?especialidad=`, `?precio=`) no es otra visita: no
 *   cambia la ruta. Pasar de una ficha a otra (`/medico/a` → `/medico/b`)
 *   con el mismo componente montado sí lo es.
 */
export function useVisitaDelDirectorio(variante: VarianteDelDirectorio): void {
  const ruta = useMatch({ strict: false, select: (m) => m.pathname })
  const apuntada = useRef<string | null>(null)
  useEffect(() => {
    const clave = `${variante}|${ruta}`
    if (apuntada.current === clave) return
    apuntada.current = clave
    apuntarVisita(variante)
  }, [variante, ruta])
}
