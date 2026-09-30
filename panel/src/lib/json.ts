// ═══════════════════════════════════════════════════════════════════════════
// Leer el JSON de una RPC sin `any` y sin prometerle tipos al compilador.
//
// Lo que devuelve Supabase es `unknown` hasta que se mira. Estas funciones
// miran campo a campo y devuelven el tipo bueno o un respaldo declarado. Es
// el único lector del panel: antes había cinco copias que diferían en los
// casos límite, y de esas diferencias salían un «null» escrito o un `NaN`.
//
// Las reglas, elegidas por ser las más seguras de las cinco:
// - Un dato que puede faltar se queda en `null`, nunca en 0 ni en «null».
//   `''` cuenta como que falta, en texto y en número.
// - Un número que llega como texto se lee (`'12.5'` → 12,5): PostgREST manda
//   así los `numeric` grandes. Uno que no se puede leer es `null`, no `NaN`,
//   y un booleano tampoco es un número.
// - Un número en un campo de texto se lee como su texto (un número de orden,
//   una referencia). Un objeto o un booleano, no: eso es un fallo del contrato.
// ═══════════════════════════════════════════════════════════════════════════

/** Un objeto de la respuesta. Lo que no es objeto llega como `{}`. */
export function comoFila(v: unknown): Record<string, unknown> {
  return typeof v === 'object' && v !== null ? { ...v } : {}
}

/** Un objeto que puede no venir. */
export function filaONula(v: unknown): Record<string, unknown> | null {
  return typeof v === 'object' && v !== null ? comoFila(v) : null
}

/** Una lista de la respuesta. Lo que no es lista llega como `[]`. */
export function comoLista(v: unknown): unknown[] {
  return Array.isArray(v) ? v : []
}

/** Una lista de objetos: cada elemento, como fila. */
export function filas(v: unknown): Array<Record<string, unknown>> {
  return comoLista(v).map(comoFila)
}

/**
 * Una cifra que puede no existir: un porcentaje sin denominador, un límite,
 * una fecha que no llegó. «No hay dato» no es un cero.
 */
export function numeroONulo(v: unknown): number | null {
  if (v === null || v === undefined || v === '' || typeof v === 'boolean') return null
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

/**
 * Una cifra que la base siempre manda (un recuento, una suma con
 * `coalesce`). Si no llega un número es un fallo del contrato y vale 0, para
 * que no se cuele un `NaN` en una suma ni en un orden. Para lo que puede
 * faltar de verdad, `numeroONulo`.
 */
export function numero(v: unknown): number {
  return numeroONulo(v) ?? 0
}

/** Un texto que puede faltar. Vacío cuenta como que falta. */
export function textoONulo(v: unknown): string | null {
  if (typeof v === 'number' && Number.isFinite(v)) return String(v)
  return typeof v === 'string' && v !== '' ? v : null
}

/** Un texto obligatorio. Un número llega convertido; lo demás, el respaldo. */
export function texto(v: unknown, respaldo = ''): string {
  if (typeof v === 'string') return v
  return textoONulo(v) ?? respaldo
}

/** Un booleano: solo `true` es verdad. `'true'` o `1` no lo son. */
export function booleano(v: unknown): boolean {
  return v === true
}

/** Una lista de textos; lo que no sea texto se descarta. */
export function textos(v: unknown): string[] {
  return comoLista(v).filter((x): x is string => typeof x === 'string')
}

/** Una lista de números; lo que no se pueda leer como número se descarta. */
export function numeros(v: unknown): number[] {
  return comoLista(v)
    .map(numeroONulo)
    .filter((x): x is number => x !== null)
}
