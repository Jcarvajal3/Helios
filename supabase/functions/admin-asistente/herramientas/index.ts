/**
 * La lista cerrada de herramientas del asistente.
 *
 * El orden es fijo: las herramientas van al principio del prompt y cualquier
 * cambio de orden rompe la caché. Cómo se le mandan al modelo (modo estricto,
 * etc.) lo decide el proveedor.
 */

import type { DefinicionDeHerramienta } from '../proveedor.ts';
import { analisis } from './analisis.ts';
import { caja } from './caja.ts';
import { consulta } from './consulta.ts';
import { cobranza } from './cobranza.ts';
import { directorio } from './directorio.ts';
import { gerencia } from './gerencia.ts';
import { presentacion } from './presentacion.ts';
import { riesgo } from './riesgo.ts';
import type { Herramienta } from './tipos.ts';

export const HERRAMIENTAS: readonly Herramienta[] = [
  ...gerencia,
  ...caja,
  ...cobranza,
  ...riesgo,
  ...directorio,
  ...analisis,
  ...consulta,
  ...presentacion,
];

const POR_NOMBRE = new Map(HERRAMIENTAS.map((h) => [h.nombre, h]));

export function buscarHerramienta(nombre: string): Herramienta | undefined {
  return POR_NOMBRE.get(nombre);
}

/**
 * La descripción que ve el modelo. Si la pantalla es fija, se nombra desde el
 * campo `pantalla`; las que dependen del id la nombran en su propio texto.
 */
export function descripcionCompleta(h: Herramienta): string {
  if (h.clase !== 'datos' || typeof h.pantalla === 'function') return h.descripcion;
  const { ruta, search } = h.pantalla;
  const url = search ? `${ruta}?${Object.entries(search).map(([k, v]) => `${k}=${v}`).join('&')}` : ruta;
  return `${h.descripcion} Pantalla: ${url}.`;
}

/** Lo que se le enseña al modelo de cada herramienta, en formato neutro. */
export function definiciones(): DefinicionDeHerramienta[] {
  return HERRAMIENTAS.map((h) => ({ nombre: h.nombre, descripcion: descripcionCompleta(h), esquema: h.esquema }));
}

/** Los nombres de las herramientas de datos: las RPC que el modelo sí puede consultar. */
export function nombresDeDatos(): ReadonlySet<string> {
  return new Set(HERRAMIENTAS.flatMap((h) => (h.clase === 'datos' ? [h.nombre] : [])));
}
