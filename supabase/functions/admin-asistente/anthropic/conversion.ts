/**
 * Del formato neutro de `proveedor.ts` al de la API de Anthropic, y vuelta.
 *
 * Puro (solo tipos del SDK), para probarlo sin red. El turno del asistente se
 * guarda entero como `nativo` (sus bloques tal cual, pensamiento firmado
 * incluido) y se reenvía así: la API exige ver el pensamiento de la vuelta que
 * pidió las herramientas.
 *
 * Con `fallbacks`, un bloque `fallback` marca dónde un modelo declinó y otro
 * siguió. Lo de antes de la última marca se reenvía solo como texto (el
 * pensamiento y las llamadas del modelo que declinó no valen) y sus llamadas
 * no se ejecutan.
 */

import type Anthropic from 'npm:@anthropic-ai/sdk@1';

import type {
  BloqueLlamada,
  BloqueTexto,
  DefinicionDeHerramienta,
  MensajeNeutral,
  MotivoDeFin,
} from '../proveedor.ts';

type Bloque = Anthropic.Beta.Messages.BetaContentBlock;

/** Lo que se guarda de cada turno del asistente: su contenido tal cual. */
export type NativoAnthropic = Bloque[];

/**
 * Las que van con `strict: true` (la API solo deja pasar entradas que cumplen
 * el esquema). La API admite 20 como mucho y el asistente tiene 31, así que
 * solo van estrictas las de entrada con forma: la consulta SQL y las de
 * presentación, cuyas tablas y gráficos se arman con lo que llega. Las demás
 * leen su entrada con `herramientas/esquema.ts`, que recorta los rangos y
 * devuelve al modelo un error si falta algo (2026-10-23: con las 31 estrictas,
 * la API contestaba 400).
 */
export const ESTRICTAS: ReadonlySet<string> = new Set(['consultar_datos', 'mostrar_enlace', 'mostrar_grafico', 'mostrar_tabla']);

/** El tope de herramientas estrictas por petición de la API. */
export const MAX_ESTRICTAS = 20;

/**
 * Las herramientas para la API. Sin `eager_input_streaming`: las entradas son
 * pequeñas y el panel no enseña la entrada a medio escribir, así que no hay
 * espera que ahorrar, y con él la API dejaría de validar el esquema.
 */
export function aHerramientas(definiciones: ReadonlyArray<DefinicionDeHerramienta>): Anthropic.Beta.Messages.BetaTool[] {
  return definiciones.map((d) => ({
    name: d.nombre,
    description: d.descripcion,
    input_schema: d.esquema,
    ...(ESTRICTAS.has(d.nombre) ? { strict: true } : {}),
  }));
}

/** Lo que vale reenviar de un turno: tras un `fallback`, lo de antes de la marca va solo como texto. */
export function paraReenviar(contenido: ReadonlyArray<Bloque>): Anthropic.Beta.Messages.BetaContentBlockParam[] {
  const marca = contenido.findLastIndex((b) => b.type === 'fallback');
  return contenido.flatMap((b, i): Anthropic.Beta.Messages.BetaContentBlockParam[] => {
    if (i > marca) return [b as Anthropic.Beta.Messages.BetaContentBlockParam];
    return b.type === 'text' ? [{ type: 'text', text: b.text }] : [];
  });
}

export function aMensajes(
  mensajes: ReadonlyArray<MensajeNeutral<NativoAnthropic>>,
): Anthropic.Beta.Messages.BetaMessageParam[] {
  return mensajes.map((m): Anthropic.Beta.Messages.BetaMessageParam => {
    if (m.rol === 'asistente') {
      if (m.nativo) return { role: 'assistant', content: paraReenviar(m.nativo) };
      return {
        role: 'assistant',
        content: m.bloques.map((b): Anthropic.Beta.Messages.BetaContentBlockParam =>
          b.tipo === 'texto'
            ? { type: 'text', text: b.texto }
            : { type: 'tool_use', id: b.id, name: b.nombre, input: b.entrada }
        ),
      };
    }
    // Un turno de solo texto va como cadena: igual para la API, más corto.
    if (m.bloques.length === 1 && m.bloques[0].tipo === 'texto') return { role: 'user', content: m.bloques[0].texto };
    return {
      role: 'user',
      content: m.bloques.map((b): Anthropic.Beta.Messages.BetaContentBlockParam =>
        b.tipo === 'texto'
          ? { type: 'text', text: b.texto }
          : { type: 'tool_result', tool_use_id: b.id, content: b.contenido, is_error: b.esError }
      ),
    };
  });
}

const esFila = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/**
 * Los bloques del turno que le importan al bucle: el texto y las llamadas. Las
 * llamadas de antes de un `fallback` son del modelo que declinó: no se hacen.
 */
export function bloquesDelTurno(contenido: ReadonlyArray<Bloque>): Array<BloqueTexto | BloqueLlamada> {
  const marca = contenido.findLastIndex((b) => b.type === 'fallback');
  return contenido.flatMap((b, i): Array<BloqueTexto | BloqueLlamada> => {
    if (b.type === 'text') return [{ tipo: 'texto', texto: b.text }];
    if (b.type === 'tool_use' && i > marca) {
      return [{ tipo: 'llamada', id: b.id, nombre: b.name, entrada: esFila(b.input) ? b.input : {} }];
    }
    return [];
  });
}

export function motivoDeFin(razon: Anthropic.Beta.Messages.BetaStopReason | null): MotivoDeFin {
  switch (razon) {
    case 'tool_use':
      return 'herramientas';
    case 'max_tokens':
      return 'corte';
    case 'refusal':
      return 'rechazo';
    case 'model_context_window_exceeded':
      return 'contexto_lleno';
    default:
      return 'fin';
  }
}
