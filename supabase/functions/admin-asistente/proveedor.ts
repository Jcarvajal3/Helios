/**
 * La frontera con el modelo de lenguaje.
 *
 * Todo lo demás de la función (el bucle de herramientas, el SSE, el
 * enmascarado, el mapa, la bitácora) habla con esta interfaz y no sabe qué
 * modelo ni qué proveedor hay detrás. Cambiar de proveedor es escribir otra
 * implementación de `Proveedor` y elegirla en `configuracion.ts`. En Helios hay
 * una: `anthropic/proveedor.ts`.
 *
 * El contrato:
 * - `responder` recibe el system, la conversación en formato neutro y las
 *   herramientas, y devuelve un flujo de eventos: trozos de `texto`, cada
 *   `llamada` a herramienta ya completa, y un `fin` con el motivo, el uso de
 *   tokens y el turno del asistente para reenviarlo.
 * - `turno.nativo` es lo que el proveedor necesite para continuar la
 *   conversación tal cual (p. ej. bloques de pensamiento firmados). El bucle lo
 *   guarda y se lo devuelve sin mirarlo.
 * - Si el flujo falla, lanza. `describirError` traduce el fallo a lo que ve el
 *   panel, o devuelve `null` si fue una cancelación (el panel se fue).
 */

import type { ErrorDelAsistente } from './sse.ts';

/** El esquema JSON de la entrada de una herramienta (un objeto). */
export type EsquemaDeEntrada = {
  type: 'object';
  properties?: Record<string, unknown>;
  required?: string[];
  additionalProperties?: boolean;
};

export type DefinicionDeHerramienta = {
  nombre: string;
  descripcion: string;
  esquema: EsquemaDeEntrada;
};

export type BloqueTexto = { tipo: 'texto'; texto: string };

export type BloqueLlamada = { tipo: 'llamada'; id: string; nombre: string; entrada: Record<string, unknown> };

/** El resultado de una llamada: `id` y `nombre` son los de la llamada que contesta. */
export type BloqueResultado = { tipo: 'resultado'; id: string; nombre: string; contenido: string; esError: boolean };

/** Un turno de la conversación, sin nada de ningún proveedor salvo `nativo`. */
export type MensajeNeutral<Nativo = unknown> =
  | { rol: 'persona'; bloques: Array<BloqueTexto | BloqueResultado> }
  | { rol: 'asistente'; bloques: Array<BloqueTexto | BloqueLlamada>; nativo?: Nativo };

/**
 * Por qué terminó una vuelta:
 * - `fin`: contestó.
 * - `herramientas`: pide herramientas (las `llamada` de la vuelta).
 * - `corte`: se quedó sin tokens; si trae llamadas, van truncadas.
 * - `rechazo`: el modelo declinó la pregunta.
 * - `contexto_lleno`: la conversación ya no cabe.
 * - `fallo`: el modelo devolvió algo inservible (p. ej. una llamada mal formada).
 */
export type MotivoDeFin = 'fin' | 'herramientas' | 'corte' | 'rechazo' | 'contexto_lleno' | 'fallo';

export type UsoDeTokens = { entrada: number; salida: number; cacheLeida: number };

export type EventoDelModelo<Nativo = unknown> =
  | { tipo: 'texto'; delta: string }
  | { tipo: 'llamada'; llamada: BloqueLlamada }
  | {
    tipo: 'fin';
    motivo: MotivoDeFin;
    /** El modelo que contestó de verdad (el proveedor puede haberlo cambiado). */
    modelo: string;
    uso: UsoDeTokens;
    turno: { bloques: Array<BloqueTexto | BloqueLlamada>; nativo?: Nativo };
  };

export type PeticionAlModelo<Nativo = unknown> = {
  system: string;
  mensajes: ReadonlyArray<MensajeNeutral<Nativo>>;
  herramientas: ReadonlyArray<DefinicionDeHerramienta>;
  /** `false` en la última vuelta: el modelo tiene que contestar sin consultar más. */
  permitirHerramientas: boolean;
  senal: AbortSignal;
};

/**
 * Cada petición al modelo en una pregunta: a cuál, qué contestó y cuánto tardó
 * en contestar (hasta las cabeceras). Sirve para ver qué cuesta el plan B.
 */
export type IntentoDeModelo = { modelo: string; http: number; ms: number };

export interface Proveedor<Nativo = unknown> {
  /** El modelo configurado, para la bitácora si la vuelta no llega a terminar. */
  readonly modelo: string;
  /** Las peticiones hechas hasta ahora en esta pregunta, si el proveedor las cuenta. */
  intentos?(): ReadonlyArray<IntentoDeModelo>;
  responder(peticion: PeticionAlModelo<Nativo>): AsyncIterable<EventoDelModelo<Nativo>>;
  describirError(error: unknown): ErrorDelAsistente | null;
}
