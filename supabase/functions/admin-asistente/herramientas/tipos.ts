/**
 * La forma de una herramienta del asistente.
 *
 * Dos clases:
 * - **datos**: una RPC de lectura de la lista cerrada. El modelo ve nombres
 *   legibles (`desde`, `semanas`) y `argumentos` los traduce a los `p_*` de la
 *   RPC, recortando lo que se sale de rango.
 * - **presentacion**: no leen la base. El panel las dibuja (enlace, gráfico,
 *   tabla) y el modelo recibe `ok` o el motivo del rechazo.
 */

import type { NivelDeDetalle } from '../enmascarar.ts';
import type { Mapa } from '../mapa.ts';
import type { EsquemaDeEntrada } from '../proveedor.ts';
import type { Evento } from '../sse.ts';

export type { EsquemaDeEntrada };

export type Entrada = Record<string, unknown>;

/**
 * Cómo se enmascara lo que devuelve la RPC (ver `enmascarar.ts`): `ficha`
 * deja el nombre entero de la persona por la que se pregunta; teléfono y
 * cédula van tapados siempre.
 */
export type DatosPersonales = NivelDeDetalle;

/** Una pantalla del panel, en la forma en que la valida el mapa. */
export type PantallaDeHerramienta = { ruta: string; search?: Record<string, string> };

/**
 * Dónde se ve lo que lee una herramienta: fija, o calculada cuando depende del
 * id (la ficha de una persona, de un local o de un consumo). `null` si con esa
 * entrada no hay una pantalla que enlazar.
 */
export type PantallaDeDatos =
  | PantallaDeHerramienta
  | ((entrada: Entrada, datos: unknown) => PantallaDeHerramienta | null);

export type HerramientaDeDatos = {
  clase: 'datos';
  /** El nombre que ve el modelo: el de la RPC. */
  nombre: string;
  rpc: string;
  /** Lo que el panel pinta mientras corre: «Leyendo la cartera vencida». */
  rotulo: string;
  /**
   * Lo que contesta y lo que no. Si `pantalla` es fija, `definiciones()` le
   * añade «Pantalla: …» al final: la fuente es el campo, no el texto.
   */
  descripcion: string;
  /** La pantalla que el panel enlaza solo al final de la respuesta. */
  pantalla: PantallaDeDatos;
  esquema: EsquemaDeEntrada;
  /** De la entrada del modelo a los parámetros `p_*` de la RPC. */
  argumentos(entrada: Entrada): Record<string, unknown>;
  /** Quita campos que confunden (los que llevan el fee sumado) o que pesan sin aportar. */
  recortar?(datos: unknown): unknown;
  /**
   * La tabla o el gráfico de lo leído, armados con los datos ya enmascarados.
   * El bucle los pinta al final de la respuesta; la nota vuelve al modelo.
   */
  visualizar?(entrada: Entrada, datos: unknown): Visualizacion | null;
  datosPersonales: DatosPersonales;
};

export type Visualizacion = { evento?: Evento; nota?: string };

export type ResultadoDePresentacion =
  | { ok: true; evento: Evento; nota?: string }
  | { ok: false; error: string };

export type HerramientaDePresentacion = {
  clase: 'presentacion';
  nombre: string;
  descripcion: string;
  esquema: EsquemaDeEntrada;
  presentar(entrada: Entrada, mapa: Mapa): ResultadoDePresentacion;
};

export type Herramienta = HerramientaDeDatos | HerramientaDePresentacion;
