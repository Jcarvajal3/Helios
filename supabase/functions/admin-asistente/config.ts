/**
 * Lo que se ajusta del asistente, en un solo sitio.
 *
 * El asistente no es esencial y no debe salir caro: respuestas cortas y pocas
 * vueltas. El modelo se elige con una variable de entorno (ver
 * `configuracion.ts`).
 */

/** Tope por vuelta, pensamiento incluido (los tres modelos piensan siempre). */
export const MAX_TOKENS = 16000;

/**
 * Vueltas con el modelo por pregunta. En la última ya no puede consultar
 * (`tool_choice: none`) y contesta con lo que tiene.
 */
export const MAX_VUELTAS = 6;

/** Lo más largo que se devuelve al modelo de una sola herramienta, en caracteres de JSON. */
export const MAX_RESULTADO = 30000;

/** Lo que el panel puede mandar por turno. */
export const LIMITES_CONVERSACION = {
  turnos: 30,
  caracteresPersona: 4000,
  caracteresAsistente: 12000,
} as const;
