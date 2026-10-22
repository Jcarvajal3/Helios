/**
 * El protocolo con el panel: eventos SSE (`event: <tipo>` + `data: <json>`).
 *
 * Los tipos de aquí son el contrato. El cliente del panel parte el flujo con
 * las mismas reglas: un evento por bloque, separado por una línea en blanco, y
 * los comentarios (`: ping`) se ignoran.
 */

/** Un valor de la URL, con el tipo que usa el catálogo del panel (`true`, no `"true"`). */
export type ValorDeBusqueda = string | number | boolean;

export type Enlace = { titulo: string; ruta: string; search?: Record<string, ValorDeBusqueda> };

export type PuntoDeGrafico = { etiqueta: string; valor: number; valor2?: number };

export type Grafico = {
  tipo: 'barras' | 'lineas' | 'reparto';
  titulo: string;
  unidad: 'eur' | 'numero' | 'pct';
  puntos: PuntoDeGrafico[];
  leyenda?: { valor: string; valor2?: string };
};

export type UnidadDeColumna = 'eur' | 'numero' | 'pct' | 'texto' | 'fecha';

export type Tabla = {
  titulo: string;
  columnas: Array<{ clave: string; rotulo: string; unidad?: UnidadDeColumna }>;
  /** Una fila por objeto, con una entrada por `clave` de columna. */
  filas: Array<Record<string, string | number | null>>;
};

export type EstadoHerramienta = 'consultando' | 'hecho' | 'error';

/**
 * Qué clase de fallo fue, para que el panel elija el aviso sin leer el texto:
 * - `saturado`: el modelo no contesta (≥ 500) ni con los de reserva.
 * - `cuota`: 429, se gastó la cuota del proyecto.
 * - `configuracion`: clave, permiso, modelo o cuenta; reintentar no sirve.
 * - `conversacion_larga`: ya no cabe; hay que empezar otra.
 * - `otro`: lo demás (sin red, rechazo, respuesta inservible…).
 */
export type CodigoDeError = 'saturado' | 'cuota' | 'configuracion' | 'conversacion_larga' | 'otro';

export type ErrorDelAsistente = {
  codigo: CodigoDeError;
  /** La frase para la persona, sin nada técnico. */
  mensaje: string;
  reintentar: boolean;
  /** El fallo del proveedor, ya enmascarado, para diagnosticar. */
  detalle?: string;
};

export type Evento =
  | { tipo: 'texto'; datos: { delta: string } }
  | { tipo: 'herramienta'; datos: { id: string; rotulo: string; estado: EstadoHerramienta } }
  | { tipo: 'enlace'; datos: Enlace }
  | { tipo: 'grafico'; datos: Grafico }
  | { tipo: 'tabla'; datos: Tabla }
  | {
    tipo: 'fin';
    datos: {
      modelo: string;
      entrada: number;
      salida: number;
      cacheLeida: number;
      /** Diagnóstico del plan B: cada petición al modelo, con su código y su espera. */
      intentos?: Array<{ modelo: string; http: number; ms: number }>;
    };
  }
  | { tipo: 'error'; datos: ErrorDelAsistente };

/**
 * Un evento en el formato del cable. `JSON.stringify` escapa los saltos de
 * línea, así que `data:` siempre cabe en una sola línea.
 */
export function formatearEvento(evento: Evento): string {
  return `event: ${evento.tipo}\ndata: ${JSON.stringify(evento.datos)}\n\n`;
}

/** Comentario SSE: mantiene viva la conexión mientras corre una consulta larga. */
export const PING = ': ping\n\n';

export type Canal = {
  stream: ReadableStream<Uint8Array>;
  enviar(evento: Evento): void;
  cerrar(): void;
  /** Se dispara si el panel corta la conexión: hay que dejar de gastar tokens. */
  senal: AbortSignal;
};

/**
 * Un flujo SSE al que se le empujan eventos. Enviar después de cerrar, o
 * después de que el panel se haya ido, no hace nada: el bucle no tiene que
 * preguntar antes de cada evento.
 */
export function crearCanal(opciones: { pingMs?: number } = {}): Canal {
  const codificador = new TextEncoder();
  const corte = new AbortController();
  let controlador: ReadableStreamDefaultController<Uint8Array> | null = null;
  let cerrado = false;
  let latido: ReturnType<typeof setInterval> | undefined;

  const escribir = (texto: string) => {
    if (cerrado || !controlador) return;
    try {
      controlador.enqueue(codificador.encode(texto));
    } catch {
      cerrado = true;
    }
  };

  const terminar = () => {
    if (latido !== undefined) clearInterval(latido);
    cerrado = true;
  };

  const stream = new ReadableStream<Uint8Array>({
    start(c) {
      controlador = c;
      const pingMs = opciones.pingMs ?? 15000;
      if (pingMs > 0) latido = setInterval(() => escribir(PING), pingMs);
    },
    cancel() {
      terminar();
      corte.abort();
    },
  });

  return {
    stream,
    senal: corte.signal,
    enviar: (evento) => escribir(formatearEvento(evento)),
    cerrar() {
      if (cerrado) return;
      terminar();
      try {
        controlador?.close();
      } catch {
        // ya estaba cerrado por el otro lado
      }
    },
  };
}
