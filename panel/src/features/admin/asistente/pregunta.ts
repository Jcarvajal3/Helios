import { normalizar } from '@/features/admin/catalogo'

/**
 * Las palabras con que empieza una pregunta, sin tildes: «qué», «cuánto»,
 * «por qué»… `normalizar` ya quita las tildes de lo tecleado.
 */
const INTERROGATIVAS = [
  'que',
  'cuanto',
  'cuanta',
  'cuantos',
  'cuantas',
  'quien',
  'quienes',
  'como',
  'por que',
  'porque',
  'cual',
  'cuales',
  'donde',
  'cuando',
]

/**
 * Si lo tecleado en la paleta parece una pregunta para el asistente y no algo
 * que buscar: empieza por «¿», acaba en «?» o su primera palabra es
 * interrogativa. Entonces «Preguntarle al asistente» sale la primera.
 */
export function pareceUnaPregunta(texto: string): boolean {
  const limpio = texto.trim()
  if (limpio.startsWith('¿') || (limpio.endsWith('?') && limpio.length > 1)) return true
  const normal = normalizar(limpio)
  return INTERROGATIVAS.some((p) => normal === p || normal.startsWith(`${p} `))
}
