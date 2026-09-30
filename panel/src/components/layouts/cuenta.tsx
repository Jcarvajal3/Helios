import { createContext, useContext, useMemo } from 'react'
import type { ReactNode } from 'react'

/**
 * Quién ha entrado. Va al pie de la barra, y no es cosmético: el super admin
 * enseñaba el rol —"Super admin" u "Operador"— pero nunca el nombre ni el
 * correo, y en el panel del local la identidad estaba escondida en una
 * pestaña entera. Un panel que no dice en qué cuenta estás es un panel en el
 * que tarde o temprano alguien hace algo desde la cuenta equivocada.
 */
export type Account = {
  /** El nombre de la persona, o su correo si no dio nombre. */
  name: string
  /** El rol, en palabras. Es lo que explica por qué el menú tiene lo que tiene. */
  detail: string
  /**
   * El nombre tal como lo guarda la base, si lo hay. Va aparte de `name`
   * porque `name` puede ser un correo, y de un correo no sale un nombre de pila.
   */
  nombreCompleto?: string | null
}

/** La cuenta tal como la leen las pantallas. */
export type CuentaDelPanel = {
  /** Lo que se lee en el pie: el nombre, o el correo. */
  nombre: string
  /** El rol, en palabras. */
  detalle: string
  /** Con lo que saluda Inicio. `null` si la cuenta no tiene nombre guardado. */
  nombreDePila: string | null
}

/**
 * La primera palabra del nombre, con mayúscula inicial. `null` si no hay
 * nombre o si lo que hay es un correo: «Buenas tardes, javier.c@…» es peor
 * que un saludo sin nombre.
 */
export function nombreDePila(nombreCompleto: string | null | undefined): string | null {
  const limpio = nombreCompleto?.trim() ?? ''
  if (limpio === '' || limpio.includes('@')) return null
  const primera = limpio.split(/\s+/)[0]
  return primera.charAt(0).toLocaleUpperCase('es') + primera.slice(1)
}

/**
 * Una o dos letras para el disco. De un correo se coge lo de antes de la
 * arroba, que es lo único que distingue a dos personas del mismo dominio.
 */
export function iniciales(nombre: string): string {
  const limpio = (nombre.includes('@') ? nombre.slice(0, nombre.indexOf('@')) : nombre).trim()
  const partes = limpio.split(/[\s._-]+/).filter(Boolean)
  if (partes.length === 0) return '?'
  if (partes.length === 1) return partes[0].slice(0, 2).toUpperCase()
  return (partes[0][0] + partes[1][0]).toUpperCase()
}

const Cuenta = createContext<CuentaDelPanel | null>(null)

/** La pone el marco (`PanelShell`): todo lo que cuelga del panel sabe quién es. */
export function CuentaProvider({ account, children }: { account: Account; children: ReactNode }) {
  const { name, detail, nombreCompleto } = account
  const valor = useMemo<CuentaDelPanel>(
    () => ({ nombre: name, detalle: detail, nombreDePila: nombreDePila(nombreCompleto) }),
    [name, detail, nombreCompleto],
  )
  return <Cuenta.Provider value={valor}>{children}</Cuenta.Provider>
}

/**
 * La cuenta que ha entrado. Inicio saluda con `useCuentaDelPanel()?.nombreDePila`.
 *
 * `null` fuera del marco (la portada, el login): ahí no hay nadie dentro.
 */
export function useCuentaDelPanel(): CuentaDelPanel | null {
  return useContext(Cuenta)
}
