/**
 * El enmascarado de datos personales en lo que devuelven las herramientas.
 *
 * Lo hace el servidor al serializar el resultado, no el modelo: lo que no llega
 * al proveedor no se puede repetir ni guardar. La regla es estricta:
 *
 * - Teléfono y cédula: SIEMPRE tapados, también en la ficha de una persona;
 *   quedan las tres últimas cifras, que bastan para reconocerla.
 * - Fecha de nacimiento, correo, dirección e IP: fuera.
 * - Nombres de persona: en las listas, solo el primer nombre y la inicial del
 *   apellido («MARÍA P.»). Enteros solo en la ficha de la persona por la que se
 *   pregunta (`admin_user_detail`, `admin_collection_case`).
 * - Textos libres (notas, motivos, descripciones): se tapan los números que
 *   parecen un teléfono o una cédula escritos a mano.
 */

/** `lista`: varias personas. `ficha`: la persona por la que se pregunta. */
export type NivelDeDetalle = 'lista' | 'ficha';

const TELEFONO = /^(phone|phone_e164|telefono|whatsapp|payer_phone|reference_phone)$/i;
const CEDULA = /^(document_number|cedula|id_number|document_id|national_id|payer_document|payer_id|owner_document)$/i;
const FUERA = /^(birth_date|fecha_nacimiento|ip|ip_address|email|correo|address|direccion|recipient)$/i;
const NOMBRE = /^(full_name|other_name|created_by_name|user_name|holder_name|payer_name|actor_name|reviewed_by_name|imported_by_name|discarded_by_name|reference_name|beneficiary_name)$/i;
const TEXTO_LIBRE = /^(note|notes|nota|description|reason|review_note|void_reason|blacklist_reason|comment|message)$/i;

/** Deja las `n` últimas cifras y tapa las demás; los signos se quedan. */
function dejarUltimas(valor: string, n: number): string {
  const total = (valor.match(/\d/g) ?? []).length;
  let vistas = 0;
  return valor.replace(/\d/g, (d) => (++vistas > total - n ? d : '•'));
}

/** «+584141234567» → «+58•••••••567». Deja el país y las tres últimas cifras. */
export function taparTelefono(valor: string): string {
  const limpio = valor.replace(/[\s-]/g, '');
  const pais = limpio.startsWith('+') ? limpio.slice(0, 3) : '';
  return pais + dejarUltimas(limpio.slice(pais.length), 3);
}

/** «V-12345678» → «V-•••••678». Deja la letra y las tres últimas cifras. */
export function taparCedula(valor: string): string {
  return dejarUltimas(valor.trim(), 3);
}

/**
 * «MARÍA JOSEFINA PÉREZ GÓMEZ» → «MARÍA P.». Con cuatro palabras o más, el
 * apellido es la tercera; con dos o tres, la segunda (no se puede distinguir
 * un segundo nombre de un apellido, y basta con una inicial).
 */
export function acortarNombre(valor: string): string {
  const palabras = valor.trim().split(/\s+/).filter(Boolean);
  if (palabras.length <= 1) return palabras[0] ?? '';
  const apellido = palabras.length >= 4 ? palabras[2] : palabras[1];
  return `${palabras[0]} ${apellido.charAt(0)}.`;
}

/** Tapa en un texto libre lo que parece un teléfono venezolano o una cédula. */
export function taparNumerosSueltos(texto: string): string {
  return texto
    .replace(/(?:\+?58[\s-]?)?0?4\d{2}[\s-]?\d{3}[\s-]?\d{2}[\s-]?\d{2}/g, (m) => dejarUltimas(m, 3))
    .replace(/\b[VEJvej]-?\d{6,9}\b/g, (m) => dejarUltimas(m, 3))
    .replace(/\b\d{7,}\b/g, (m) => dejarUltimas(m, 3));
}

/** Copia el valor aplicando la regla de arriba a cualquier profundidad. */
export function enmascarar(valor: unknown, nivel: NivelDeDetalle = 'lista'): unknown {
  if (Array.isArray(valor)) return valor.map((v) => enmascarar(v, nivel));
  if (valor === null || typeof valor !== 'object') return valor;
  const salida: Record<string, unknown> = {};
  for (const [clave, v] of Object.entries(valor)) {
    if (typeof v === 'string' && TELEFONO.test(clave)) salida[clave] = taparTelefono(v);
    else if (typeof v === 'string' && CEDULA.test(clave)) salida[clave] = taparCedula(v);
    else if (v !== null && FUERA.test(clave)) salida[clave] = '(oculto)';
    else if (typeof v === 'string' && nivel === 'lista' && NOMBRE.test(clave)) salida[clave] = acortarNombre(v);
    else if (typeof v === 'string' && TEXTO_LIBRE.test(clave)) salida[clave] = taparNumerosSueltos(v);
    else salida[clave] = enmascarar(v, nivel);
  }
  return salida;
}
