import { describeError } from '@/lib/supabase'

/**
 * Un teléfono venezolano escrito como sea a E.164 (`+584149783031`), o `null`.
 * Espeja `helios_normalize_ve_phone`: acepta `0414…`, `+58 0414…`,
 * `0414-978-3031` y `584149783031`. Quita el 0 de troncal que sobra tras el +58.
 */
export function normalizarTelefonoPiloto(valor: string): string | null {
  let digitos = valor.replace(/\D/g, '')
  if (digitos.startsWith('58')) digitos = digitos.slice(2)
  digitos = digitos.replace(/^0/, '')
  return /^\d{10}$/.test(digitos) ? `+58${digitos}` : null
}

/** Frase para el error `telefono_piloto_invalido: <valor>` que lanza la base. */
export function explicarErrorDePilotos(error: unknown): string | undefined {
  const texto = describeError(error)
  const m = texto?.match(/telefono_piloto_invalido:?\s*(.*)/)
  if (!m) return texto
  const valor = m[1].trim()
  return `El teléfono piloto${valor ? ` «${valor}»` : ''} no es válido. Usa el formato 0414 123 4567 o +58 414 123 4567.`
}
