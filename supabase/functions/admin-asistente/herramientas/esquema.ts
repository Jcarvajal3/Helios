/**
 * Piezas para escribir los esquemas (`strict: true`) y leer lo que llega.
 *
 * El modo estricto no admite `minimum`/`maximum` ni `minLength`: los rangos van
 * escritos en la descripción y se recortan al leer. Aunque la API valide el
 * esquema, la lectura vuelve a comprobarlo todo: un parámetro que no encaja se
 * descarta y la RPC usa su valor por defecto, nunca recibe basura.
 */

import type { EsquemaDeEntrada } from './tipos.ts';

type Propiedad = Record<string, unknown>;

/** Un objeto estricto: `additionalProperties: false`, como pide `strict`. */
export function objeto(propiedades: Record<string, Propiedad>, requeridas: string[] = []): EsquemaDeEntrada {
  return { type: 'object', properties: propiedades, required: requeridas, additionalProperties: false };
}

export const sinParametros = (): EsquemaDeEntrada => objeto({});

export const fecha = (descripcion: string): Propiedad => ({ type: 'string', format: 'date', description: descripcion });

export const entero = (descripcion: string): Propiedad => ({ type: 'integer', description: descripcion });

export const uuid = (descripcion: string): Propiedad => ({ type: 'string', format: 'uuid', description: descripcion });

export const textoLibre = (descripcion: string): Propiedad => ({ type: 'string', description: descripcion });

export const opcion = (valores: readonly string[], descripcion: string): Propiedad => ({
  type: 'string',
  enum: [...valores],
  description: descripcion,
});

export const DESDE = fecha('Primer día del rango, inclusive (YYYY-MM-DD). Si se omite, la RPC usa su valor por defecto.');
export const HASTA = fecha('Último día del rango, inclusive (YYYY-MM-DD). Si se omite, hasta hoy.');

// ── Lectura ────────────────────────────────────────────────────────────────

const FECHA = /^\d{4}-\d{2}-\d{2}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** 'YYYY-MM-DD' de un día que existe, o `undefined`. */
export function leerFecha(v: unknown): string | undefined {
  if (typeof v !== 'string' || !FECHA.test(v)) return undefined;
  const d = new Date(`${v}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v ? v : undefined;
}

/** Un entero dentro de `[min, max]` (recortado), o `undefined` si no es un número. */
export function leerEntero(v: unknown, min: number, max: number): number | undefined {
  if (typeof v !== 'number' || !Number.isFinite(v)) return undefined;
  return Math.min(max, Math.max(min, Math.trunc(v)));
}

export function leerUuid(v: unknown): string | undefined {
  return typeof v === 'string' && UUID.test(v.trim()) ? v.trim().toLowerCase() : undefined;
}

/** Una entrada que no se puede usar. El mensaje vuelve al modelo para que la corrija. */
export class ErrorDeEntrada extends Error {}

/** Un uuid que la herramienta no puede omitir. */
export function uuidObligatorio(v: unknown, campo: string): string {
  const id = leerUuid(v);
  if (!id) throw new ErrorDeEntrada(`«${campo}» tiene que ser un uuid; búscalo antes con la herramienta que lo da.`);
  return id;
}

export function leerOpcion<T extends string>(v: unknown, valores: readonly T[]): T | undefined {
  return valores.find((x) => x === v);
}

export function leerTexto(v: unknown, max = 200): string | undefined {
  if (typeof v !== 'string') return undefined;
  const t = v.trim().slice(0, max);
  return t === '' ? undefined : t;
}

/**
 * Los argumentos de la RPC sin las claves vacías: lo que no viene no se manda,
 * y así manda el `default` de la función en la base.
 */
export function sinVacios(args: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(args).filter(([, v]) => v !== undefined));
}

/** Rango de fechas de la entrada, ya como `p_from`/`p_to`. */
export function rango(entrada: Record<string, unknown>): { p_from?: string; p_to?: string } {
  return { p_from: leerFecha(entrada.desde), p_to: leerFecha(entrada.hasta) };
}

// ── Recortes ───────────────────────────────────────────────────────────────

type Fila = Record<string, unknown>;

export const esFila = (v: unknown): v is Fila => typeof v === 'object' && v !== null && !Array.isArray(v);

/** Copia el objeto sin esas claves (solo el primer nivel). */
export function sinClaves(v: unknown, claves: readonly string[]): unknown {
  if (!esFila(v)) return v;
  return Object.fromEntries(Object.entries(v).filter(([k]) => !claves.includes(k)));
}

/** Aplica `sinClaves` a cada fila de una lista. */
export function filasSinClaves(v: unknown, claves: readonly string[]): unknown {
  return Array.isArray(v) ? v.map((f) => sinClaves(f, claves)) : v;
}
