/**
 * Qué modelo contesta, según el entorno de la función.
 *
 * En Helios el asistente solo habla con Anthropic (Gemini se descartó el
 * 2026-10-09) y usa la misma clave que el lector de comprobantes:
 *
 * - `ANTHROPIC_API_KEY`: el secreto del proyecto, el mismo de
 *   `lector-comprobantes`. Sin ella, el asistente contesta que no está
 *   configurado.
 * - `ASISTENTE_MODELO`: opcional; uno de los de `anthropic/modelo.ts`. Sin
 *   él, el de por defecto.
 *
 * Puro, para probarlo: `index.ts` crea el proveedor con lo que diga esto.
 */

import { leerModelo, type ModeloDelAsistente } from './anthropic/modelo.ts';

export type Eleccion =
  | { proveedor: 'anthropic'; apiKey: string; modelo: ModeloDelAsistente }
  | { proveedor: null; falta: 'ANTHROPIC_API_KEY' };

/** Una clave pegada con comillas o espacios alrededor es un error típico al ponerla. */
export function limpiarClave(valor: string | undefined): string | undefined {
  const limpia = valor?.trim().replace(/^(['"])(.*)\1$/, '$2').trim();
  return limpia ? limpia : undefined;
}

export function elegirProveedor(entorno: (nombre: string) => string | undefined): Eleccion {
  const apiKey = limpiarClave(entorno('ANTHROPIC_API_KEY'));
  return apiKey
    ? { proveedor: 'anthropic', apiKey, modelo: leerModelo(entorno('ASISTENTE_MODELO')) }
    : { proveedor: null, falta: 'ANTHROPIC_API_KEY' };
}
