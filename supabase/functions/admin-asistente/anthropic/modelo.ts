/**
 * El modelo de Anthropic que contesta.
 *
 * Por defecto `claude-sonnet-5-5` (Javier, 2026-10-23). `ASISTENTE_MODELO`
 * lo cambia sin tocar el código: `claude-opus-5-5` (más fino y más caro) o
 * `claude-haiku-5-5` (más barato). Solo se aceptan esos tres IDs exactos: cualquier otro valor
 * vuelve al de por defecto, porque cada modelo pide parámetros distintos y uno
 * desconocido podría dar un 400 en cada pregunta.
 *
 * - Los tres piensan siempre (adaptativo); el esfuerzo es el único mando, y va
 *   en `low` (Javier, 2026-10-23): respuestas de consulta, rápidas y baratas.
 * - Opus 5.5 y Sonnet 5.5 van con `fallbacks: 'default'` (beta
 *   `server-side-fallback-2026-07-01`): si el clasificador de seguridad
 *   declina, el servidor reintenta con otro modelo dentro de la misma llamada,
 *   como en el lector de comprobantes. Haiku 5.5 no tiene ese respaldo.
 *
 * Mínimo cacheable del prefijo (herramientas + system): lo supera de sobra
 * (lo comprueba `pruebas/anthropic.test.ts`).
 */

export const MODELOS = ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5'] as const;

export type ModeloDelAsistente = (typeof MODELOS)[number];

export const MODELO_POR_DEFECTO: ModeloDelAsistente = 'claude-sonnet-5-5';

export function leerModelo(valor: string | undefined): ModeloDelAsistente {
  const limpio = valor?.trim();
  if (!limpio) return MODELO_POR_DEFECTO;
  const modelo = MODELOS.find((m) => m === limpio);
  if (!modelo) {
    console.warn(`asistente: ASISTENTE_MODELO="${limpio}" no es un modelo admitido; se usa ${MODELO_POR_DEFECTO}`);
    return MODELO_POR_DEFECTO;
  }
  return modelo;
}

export type ParametrosDelModelo = {
  thinking: { type: 'adaptive' };
  output_config: { effort: 'low' | 'medium' | 'high' };
  betas?: string[];
  fallbacks?: 'default';
};

/** Los parámetros que cambian de un modelo a otro. Todo lo demás es común. */
export function parametrosDelModelo(modelo: ModeloDelAsistente): ParametrosDelModelo {
  const comunes = { thinking: { type: 'adaptive' }, output_config: { effort: 'low' } } as const;
  switch (modelo) {
    case 'claude-opus-5-5':
    case 'claude-sonnet-5-5':
      return { ...comunes, betas: ['server-side-fallback-2026-07-01'], fallbacks: 'default' };
    case 'claude-haiku-5-5':
      return { ...comunes };
  }
}
