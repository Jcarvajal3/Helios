/**
 * Identidad legal y canales de contacto de Helios.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Helios lo opera **Quarto Latam, C.A.** (decisión de Javier, 2026-10-06).
 * El RIF y el domicilio se completan con el contador (plan D-H10). La
 * política de privacidad la revisa un abogado antes del piloto; hasta
 * entonces `/legal/privacidad` es un marcador que no afirma nada que no esté
 * decidido. Las condiciones del servicio (`/legal/terminos`) son las reglas
 * del negocio ya decididas, dichas en claro.
 *
 * Viven en el código y no en el `.env` a propósito: son texto legal
 * versionado. El día de una disputa hay que poder decir qué decía el sitio en
 * una fecha concreta, y `git log` es lo único que lo demuestra.
 */
type DatosResponsable = {
  razonSocial: string
  /** Vacío mientras no esté decidido: las páginas lo omiten en vez de inventarlo. */
  rif: string
  /** Correo de atención. Vacío hasta que exista (Ajustes › Contacto, H11). */
  soporte: string
  /**
   * El WhatsApp de Helios, solo dígitos con el código de país
   * (p. ej. `584141234567`). Es el mismo número del bot y de los pacientes
   * (360dialog con coexistencia, plan §15). Vacío mientras no esté
   * publicado. «Quiero afiliarme» no lleva aquí: lleva al formulario de
   * `/afiliacion` (2026-10-09).
   */
  whatsapp: string
}

export const RESPONSABLE: DatosResponsable = {
  razonSocial: 'Quarto Latam, C.A.',
  rif: '',
  soporte: '',
  whatsapp: '',
}

/** «Quarto Latam, C.A.» o «Quarto Latam, C.A. (RIF J-…)». */
export function operador(): string {
  return RESPONSABLE.rif
    ? `${RESPONSABLE.razonSocial} (RIF ${RESPONSABLE.rif})`
    : RESPONSABLE.razonSocial
}
