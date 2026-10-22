/**
 * El proveedor Anthropic, sin red: el modelo y sus parámetros, y la
 * conversión al formato de la API. El proveedor en sí importa el SDK y no se
 * carga aquí.
 */

import assert from 'node:assert/strict';

import type Anthropic from 'npm:@anthropic-ai/sdk@1';

import { aHerramientas, aMensajes, bloquesDelTurno, motivoDeFin, paraReenviar } from '../anthropic/conversion.ts';
import { leerModelo, MODELO_POR_DEFECTO, parametrosDelModelo } from '../anthropic/modelo.ts';
import { definiciones } from '../herramientas/index.ts';
import { leerMapa } from '../mapa.ts';
import mapaCrudo from '../mapa.json' with { type: 'json' };
import { construirSystem } from '../prompt.ts';

type Bloque = Anthropic.Beta.Messages.BetaContentBlock;

Deno.test('por defecto Sonnet 5.5, y ASISTENTE_MODELO solo admite los tres IDs exactos', () => {
  assert.equal(MODELO_POR_DEFECTO, 'claude-sonnet-5-5');
  assert.equal(leerModelo(undefined), 'claude-sonnet-5-5');
  assert.equal(leerModelo(' claude-opus-5-5 '), 'claude-opus-5-5');
  assert.equal(leerModelo('claude-haiku-5-5'), 'claude-haiku-5-5');
  assert.equal(leerModelo('claude-haiku-4-5'), 'claude-sonnet-5-5');
  assert.equal(leerModelo('gemini-3.8-flash'), 'claude-sonnet-5-5');
});

Deno.test('los tres piensan con esfuerzo low; el respaldo del servidor solo en Opus y Sonnet 5.5', () => {
  const comunes = { thinking: { type: 'adaptive' }, output_config: { effort: 'low' } };
  const respaldo = { betas: ['server-side-fallback-2026-07-01'], fallbacks: 'default' };
  assert.deepEqual(parametrosDelModelo('claude-opus-5-5'), { ...comunes, ...respaldo });
  assert.deepEqual(parametrosDelModelo('claude-sonnet-5-5'), { ...comunes, ...respaldo });
  assert.deepEqual(parametrosDelModelo('claude-haiku-5-5'), comunes);
});

Deno.test('las herramientas van con strict y los resultados como tool_result', () => {
  const tools = aHerramientas(definiciones());
  assert.equal(tools.length, 31);
  assert.ok(tools.every((t) => t.strict === true && t.input_schema.type === 'object'));

  assert.deepEqual(aMensajes([
    { rol: 'persona', bloques: [{ tipo: 'texto', texto: 'Hola' }] },
    { rol: 'asistente', bloques: [{ tipo: 'llamada', id: 't1', nombre: 'admin_overview', entrada: {} }] },
    { rol: 'persona', bloques: [{ tipo: 'resultado', id: 't1', nombre: 'admin_overview', contenido: 'ok', esError: false }] },
  ]), [
    { role: 'user', content: 'Hola' },
    { role: 'assistant', content: [{ type: 'tool_use', id: 't1', name: 'admin_overview', input: {} }] },
    { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'ok', is_error: false }] },
  ]);
});

Deno.test('del turno salen el texto y las llamadas; el motivo se traduce', () => {
  assert.deepEqual(
    bloquesDelTurno([
      { type: 'text', text: 'Miro.', citations: null },
      { type: 'tool_use', id: 't1', name: 'admin_overview', input: { dias: 7 } },
    ] as unknown as Bloque[]),
    [{ tipo: 'texto', texto: 'Miro.' }, { tipo: 'llamada', id: 't1', nombre: 'admin_overview', entrada: { dias: 7 } }],
  );
  assert.equal(motivoDeFin('tool_use'), 'herramientas');
  assert.equal(motivoDeFin('refusal'), 'rechazo');
  assert.equal(motivoDeFin('max_tokens'), 'corte');
  assert.equal(motivoDeFin('model_context_window_exceeded'), 'contexto_lleno');
  assert.equal(motivoDeFin('end_turn'), 'fin');
});

/** Un turno en el que Opus declinó a media llamada y Sonnet siguió. */
const TURNO_CON_RESPALDO = [
  { type: 'thinking', thinking: '', signature: 'firma-opus' },
  { type: 'text', text: 'Empiezo.', citations: null },
  { type: 'tool_use', id: 't0', name: 'admin_collections', input: {} },
  { type: 'fallback', from: { model: 'claude-opus-5-5' }, to: { model: 'claude-sonnet-5-5' }, trigger: { type: 'refusal' } },
  { type: 'thinking', thinking: '', signature: 'firma-sonnet' },
  { type: 'tool_use', id: 't1', name: 'admin_overview', input: { dias: 7 } },
] as unknown as Bloque[];

Deno.test('tras un fallback, lo de antes de la marca se reenvía solo como texto', () => {
  assert.deepEqual(paraReenviar(TURNO_CON_RESPALDO), [
    { type: 'text', text: 'Empiezo.' },
    { type: 'thinking', thinking: '', signature: 'firma-sonnet' },
    { type: 'tool_use', id: 't1', name: 'admin_overview', input: { dias: 7 } },
  ]);
  // Sin fallback, el turno va tal cual (pensamiento firmado incluido).
  const sinRespaldo = TURNO_CON_RESPALDO.slice(4);
  assert.deepEqual(paraReenviar(sinRespaldo), sinRespaldo);
});

Deno.test('tras un fallback, las llamadas del modelo que declinó no se hacen', () => {
  assert.deepEqual(bloquesDelTurno(TURNO_CON_RESPALDO), [
    { tipo: 'texto', texto: 'Empiezo.' },
    { tipo: 'llamada', id: 't1', nombre: 'admin_overview', entrada: { dias: 7 } },
  ]);
});

Deno.test('el prefijo cacheado (herramientas + system) supera el mínimo cacheable', () => {
  const prefijo = JSON.stringify(aHerramientas(definiciones())) + construirSystem(leerMapa(mapaCrudo));
  // Cuatro caracteres por token es una cuenta por lo bajo para español y JSON.
  const tokensPorLoBajo = Math.floor(prefijo.length / 4);
  assert.ok(tokensPorLoBajo > 4096, `el prefijo ronda ${tokensPorLoBajo} tokens; el mínimo más alto es 4096`);
});
