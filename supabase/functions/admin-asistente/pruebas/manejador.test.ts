/**
 * El manejador de punta a punta, sin red: Supabase, el proveedor y el bucle son
 * de mentira. Cubre el orden de las comprobaciones y el flujo SSE.
 */

import assert from 'node:assert/strict';

import type { Base, RespuestaDeBase } from '../base.ts';
import type { OpcionesDeCorrida, ResumenDeCorrida } from '../bucle.ts';
import { crearManejador, type Dependencias, SIN_CLAVE } from '../manejador.ts';
import { leerMapa } from '../mapa.ts';
import type { EventoDelModelo, Proveedor } from '../proveedor.ts';

const ID = '839bba23-640e-4f57-9280-c814013233bc';

/** Aquí el bucle es de mentira: el proveedor solo tiene que existir. */
const PROVEEDOR: Proveedor = {
  modelo: 'gemini-3.8-flash',
  // deno-lint-ignore require-yield
  async *responder(): AsyncGenerator<EventoDelModelo> {
    return;
  },
  describirError: () => null,
};

type Escenario = {
  usuario?: string | null;
  esAdmin?: boolean;
  configurado?: boolean;
  log?: RespuestaDeBase;
};

function preparar(e: Escenario = {}) {
  const llamadas: Array<[string, Record<string, unknown> | undefined]> = [];
  const corridas: OpcionesDeCorrida[] = [];
  const base: Base = {
    usuario: () => Promise.resolve(e.usuario === undefined ? ID : e.usuario),
    rpc: (nombre, args) => {
      llamadas.push([nombre, args]);
      if (nombre === 'is_platform_admin') return Promise.resolve({ data: e.esAdmin ?? true, error: null });
      if (nombre === 'admin_assistant_log') return Promise.resolve(e.log ?? { data: 41, error: null });
      return Promise.resolve({ data: null, error: null });
    },
  };
  const entorno: Record<string, string> = { SUPABASE_URL: 'http://x', SUPABASE_ANON_KEY: 'anon' };
  const deps: Dependencias = {
    entorno: (n) => entorno[n],
    crearBase: () => base,
    crearProveedor: () => (e.configurado ? PROVEEDOR : null),
    correr: (o): Promise<ResumenDeCorrida> => {
      corridas.push(o);
      o.canal.enviar({ tipo: 'texto', datos: { delta: 'Se recuperaron 24,40 €.' } });
      o.canal.enviar({ tipo: 'fin', datos: { modelo: 'gemini-3.8-flash', entrada: 100, salida: 20, cacheLeida: 5000 } });
      return Promise.resolve({
        herramientas: ['admin_collection_recovered', 'admin_collection_recovered'],
        modelo: 'gemini-3.8-flash',
        entrada: 100,
        salida: 20,
        cacheLeida: 5000,
      });
    },
    mapa: leerMapa({}),
    system: 'system',
    ahora: () => new Date('2026-09-25T18:00:00Z'),
  };
  return { manejar: crearManejador(deps), llamadas, corridas };
}

const PREGUNTA = { conversacion: [{ rol: 'persona', texto: '¿Cuánto se recuperó esta semana?' }], rutaActual: '/admin/cobranza' };

function peticion(cuerpo: unknown = PREGUNTA, token: string | null = 'Bearer abc'): Request {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = token;
  return new Request('http://x/functions/v1/admin-asistente', { method: 'POST', headers, body: JSON.stringify(cuerpo) });
}

async function cuerpo(r: Response): Promise<{ error: string; mensaje: string }> {
  return await r.json();
}

Deno.test('sin sesión: 401', async () => {
  const { manejar, llamadas } = preparar();
  const r = await manejar(peticion(PREGUNTA, null));
  assert.equal(r.status, 401);
  assert.equal((await cuerpo(r)).error, 'sin_sesion');
  assert.equal(llamadas.length, 0);

  const caducada = await preparar({ usuario: null }).manejar(peticion());
  assert.equal(caducada.status, 401);
});

Deno.test('con sesión y sin ser del equipo: 403, y no se dice si hay clave', async () => {
  const { manejar } = preparar({ esAdmin: false });
  const r = await manejar(peticion());
  assert.equal(r.status, 403);
  assert.equal((await cuerpo(r)).error, 'sin_permiso');
});

Deno.test('sin la clave: 503 con el mensaje claro, sin gastar cupo', async () => {
  const { manejar, llamadas } = preparar();
  const r = await manejar(peticion());
  assert.equal(r.status, 503);
  assert.deepEqual(await cuerpo(r), { error: 'sin_clave', mensaje: SIN_CLAVE });
  assert.ok(!llamadas.some(([n]) => n === 'admin_assistant_log'));
});

Deno.test('una petición mal formada: 400 antes de mirar la clave', async () => {
  const { manejar } = preparar();
  const r = await manejar(peticion({ conversacion: 'hola' }));
  assert.equal(r.status, 400);
});

Deno.test('el límite superado: 429 con el mensaje de la base', async () => {
  const mensaje = 'Has hecho 30 preguntas en la última hora; el límite es 30';
  const { manejar, corridas } = preparar({ configurado: true, log: { data: null, error: { message: mensaje, code: '22023' } } });
  const r = await manejar(peticion());
  assert.equal(r.status, 429);
  assert.deepEqual(await cuerpo(r), { error: 'limite', mensaje });
  assert.equal(corridas.length, 0);
});

Deno.test('con todo en regla: SSE, la corrida recibe el contexto y queda la línea de la respuesta', async () => {
  const { manejar, llamadas, corridas } = preparar({ configurado: true });
  const r = await manejar(peticion());
  assert.equal(r.status, 200);
  assert.match(r.headers.get('Content-Type') ?? '', /^text\/event-stream/);
  const texto = await r.text();
  assert.equal(
    texto,
    'event: texto\ndata: {"delta":"Se recuperaron 24,40 €."}\n\n' +
      'event: fin\ndata: {"modelo":"gemini-3.8-flash","entrada":100,"salida":20,"cacheLeida":5000}\n\n',
  );

  assert.equal(corridas.length, 1);
  assert.equal(corridas[0].proveedor, PROVEEDOR);
  const ultimo = corridas[0].mensajes[corridas[0].mensajes.length - 1];
  assert.equal(ultimo.rol, 'persona');
  assert.match(JSON.stringify(ultimo.bloques), /mirando \/admin\/cobranza/);

  const lineas = llamadas.filter(([n]) => n === 'admin_assistant_log');
  assert.deepEqual(lineas, [
    ['admin_assistant_log', { p_question: '¿Cuánto se recuperó esta semana?' }],
    ['admin_assistant_log', {
      p_question: '¿Cuánto se recuperó esta semana?',
      p_tools: ['admin_collection_recovered'],
      p_input_tokens: 100,
      p_output_tokens: 20,
      p_model: 'gemini-3.8-flash',
      p_log_id: 41,
    }],
  ]);
});

Deno.test('OPTIONS contesta el CORS y un GET no vale', async () => {
  const { manejar } = preparar();
  const opciones = await manejar(new Request('http://x', { method: 'OPTIONS' }));
  assert.equal(opciones.headers.get('Access-Control-Allow-Origin'), '*');
  const get = await manejar(new Request('http://x', { method: 'GET' }));
  assert.equal(get.status, 405);
});
