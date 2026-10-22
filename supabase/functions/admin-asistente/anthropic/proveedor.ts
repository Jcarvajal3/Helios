/**
 * El proveedor Anthropic: la única pieza que conoce el SDK y los modelos.
 *
 * - Modelo y parámetros por modelo: `modelo.ts` (Sonnet 5.5 por defecto, con el
 *   respaldo del servidor si el clasificador declina).
 * - Caché: las herramientas y el system son el prefijo estable; el punto de
 *   caché va al final del system (cubre los dos) y la caché automática cubre
 *   la conversación que crece dentro de una pregunta.
 * - La última vuelta va con `tool_choice: none`.
 * - `refusal` llega como motivo `rechazo`: el bucle no ejecuta nada de esa
 *   vuelta, porque un rechazo puede cortar una llamada a medias.
 */

import Anthropic from 'npm:@anthropic-ai/sdk@1';

import { MAX_TOKENS } from '../config.ts';
import type { EventoDelModelo, PeticionAlModelo, Proveedor } from '../proveedor.ts';
import type { ErrorDelAsistente } from '../sse.ts';
import { aHerramientas, aMensajes, bloquesDelTurno, motivoDeFin, type NativoAnthropic } from './conversion.ts';
import { type ModeloDelAsistente, parametrosDelModelo } from './modelo.ts';

/** Traduce un fallo de la API a lo que ve el panel; `null` si fue una cancelación. */
export function describirErrorDeAnthropic(error: unknown): ErrorDelAsistente | null {
  if (error instanceof Anthropic.APIUserAbortError) return null;
  if (error instanceof Anthropic.APIConnectionError) {
    return { codigo: 'otro', mensaje: 'No se pudo conectar con el asistente. Vuelve a intentarlo.', reintentar: true };
  }
  const detalle = error instanceof Anthropic.APIError ? `Anthropic ${error.status ?? '?'}: ${error.message.slice(0, 160)}` : undefined;
  if (error instanceof Anthropic.RateLimitError) {
    return { codigo: 'cuota', mensaje: 'El asistente llegó a su límite de consultas; prueba en un minuto.', reintentar: true, detalle };
  }
  if (error instanceof Anthropic.InternalServerError) {
    return {
      codigo: 'saturado',
      mensaje: 'El asistente está saturado en este momento. Vuelve a intentarlo en un minuto.',
      reintentar: true,
      detalle,
    };
  }
  if (error instanceof Anthropic.AuthenticationError) {
    return { codigo: 'configuracion', mensaje: 'El asistente no está bien configurado: la clave no es válida.', reintentar: false, detalle };
  }
  if (error instanceof Anthropic.PermissionDeniedError || error instanceof Anthropic.NotFoundError) {
    return {
      codigo: 'configuracion',
      mensaje: 'El asistente no está bien configurado: la clave no tiene acceso al modelo.',
      reintentar: false,
      detalle,
    };
  }
  // Un 400 u otro fallo: reintentar la misma petición daría lo mismo.
  return { codigo: 'otro', mensaje: 'El asistente no pudo completar la consulta.', reintentar: false, detalle };
}

export function crearProveedorAnthropic(opciones: {
  apiKey: string;
  modelo: ModeloDelAsistente;
}): Proveedor<NativoAnthropic> {
  const cliente = new Anthropic({ apiKey: opciones.apiKey });

  async function* responder(p: PeticionAlModelo<NativoAnthropic>): AsyncGenerator<EventoDelModelo<NativoAnthropic>> {
    const params = {
      model: opciones.modelo,
      max_tokens: MAX_TOKENS,
      ...parametrosDelModelo(opciones.modelo),
      system: [{ type: 'text', text: p.system, cache_control: { type: 'ephemeral' } }],
      tools: aHerramientas(p.herramientas),
      ...(p.permitirHerramientas ? {} : { tool_choice: { type: 'none' } }),
      cache_control: { type: 'ephemeral' },
      messages: aMensajes(p.mensajes),
    };
    // `fallbacks: 'default'` todavía no está en los tipos del SDK (igual que en el lector).
    const stream = cliente.beta.messages.stream(
      params as unknown as Parameters<typeof cliente.beta.messages.stream>[0],
      { signal: p.senal },
    );

    for await (const evento of stream) {
      if (evento.type === 'content_block_delta' && evento.delta.type === 'text_delta') {
        yield { tipo: 'texto', delta: evento.delta.text };
      }
    }
    const mensaje = await stream.finalMessage();

    const bloques = bloquesDelTurno(mensaje.content);
    for (const b of bloques) if (b.tipo === 'llamada') yield { tipo: 'llamada', llamada: b };

    yield {
      tipo: 'fin',
      motivo: motivoDeFin(mensaje.stop_reason),
      modelo: mensaje.model,
      uso: {
        entrada: mensaje.usage.input_tokens + (mensaje.usage.cache_creation_input_tokens ?? 0),
        salida: mensaje.usage.output_tokens,
        cacheLeida: mensaje.usage.cache_read_input_tokens ?? 0,
      },
      turno: { bloques, nativo: mensaje.content },
    };
  }

  return { modelo: opciones.modelo, responder, describirError: describirErrorDeAnthropic };
}
