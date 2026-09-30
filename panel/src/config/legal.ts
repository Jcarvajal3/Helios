/**
 * Identidad legal y canal de soporte de Helios.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * PENDIENTE (plan D-H10, fase 4): la razón social, el RIF y el domicilio de
 * Helios se definen con el contador, y los textos legales (privacidad,
 * condiciones del financiamiento) los revisa un abogado antes del piloto.
 * Hasta entonces las dos páginas públicas —`/legal/privacidad` y
 * `/soporte`— son marcadores que no afirman nada que no esté decidido.
 *
 * Viven en el código y no en el `.env` a propósito: son texto legal
 * versionado. El día de una disputa hay que poder decir qué decía el sitio en
 * una fecha concreta, y `git log` es lo único que lo demuestra.
 */
type DatosResponsable = {
  /** Vacío mientras no esté decidido: las páginas lo dicen en vez de inventarlo. */
  razonSocial: string
  rif: string
  /** El canal de atención. Vacío hasta que exista (Ajustes › Contacto, H11). */
  soporte: string
}

export const RESPONSABLE: DatosResponsable = {
  razonSocial: '',
  rif: '',
  soporte: '',
}
