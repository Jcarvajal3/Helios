/**
 * Reglas del perfil de un comercio, compartidas entre el alta y la edición.
 *
 * Son las mismas que impone la base (`normalize_tax_id` y el check
 * `merchants_social_url_is_http`, migración 20260825170000). Aquí se repiten
 * a propósito: la barrera de verdad es la de allá, pero descubrir que el RIF
 * está mal después de pulsar "Crear" es peor que verlo mientras se escribe.
 */

/**
 * RIF venezolano: una letra de tipo y ocho o nueve dígitos.
 *
 * J jurídico · G gobierno · V venezolano · E extranjero · P pasaporte.
 *
 * Devuelve el problema en texto, o null si está bien.
 */
export function validateTaxId(raw: string): string | null {
  const clean = raw.replace(/[^A-Za-z0-9]/g, '').toUpperCase()

  if (clean === '') return 'El RIF es obligatorio.'
  if (!/^[JGVEP]/.test(clean)) return 'Empieza por J, G, V, E o P.'
  if (!/^[JGVEP][0-9]{8,9}$/.test(clean)) {
    return 'Después de la letra van 8 o 9 dígitos (ej. J-123456789).'
  }

  return null
}

/** Cómo lo guarda la base: mayúscula, un guion, sin espacios. */
export function formatTaxId(raw: string): string {
  const clean = raw.replace(/[^A-Za-z0-9]/g, '').toUpperCase()
  if (clean.length < 2) return clean
  return `${clean[0]}-${clean.slice(1)}`
}

/**
 * La red social se teclea como se lee — "instagram.com/barnocturno" — pero se
 * guarda como URL completa, porque la app la abre como enlace.
 *
 * Sin el `https://` delante, `Linking.openURL` no hace nada: no falla, no
 * avisa, simplemente no pasa nada al tocar. Por eso el check de la base exige
 * el esquema y aquí se añade solo.
 */
export function normalizeSocialUrl(raw: string): string {
  const trimmed = raw.trim()
  if (trimmed === '') return ''
  return /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`
}

export function validateSocialUrl(raw: string): string | null {
  if (raw.trim() === '') return null

  try {
    const url = new URL(normalizeSocialUrl(raw))
    if (!url.hostname.includes('.')) return 'Eso no parece una dirección web.'
    return null
  } catch {
    return 'Eso no parece una dirección web.'
  }
}
