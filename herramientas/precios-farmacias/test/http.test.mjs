import assert from 'node:assert/strict';
import { test } from 'node:test';

import { fetchFalso, relojFalso } from './ayudas.mjs';
import { BloqueoError, ClienteHttp, USER_AGENT } from '../src/http.mjs';
import { rutaPermitida } from '../src/robots.mjs';

function crearCliente(responder, opciones = {}) {
  const reloj = relojFalso();
  const hacerFetch = fetchFalso(responder);
  const cliente = new ClienteHttp({ fetch: hacerFetch, esperar: reloj.esperar, ahora: reloj.ahora, ...opciones });
  return { cliente, reloj, hacerFetch };
}

const sinRobots = (url) => (url.endsWith('/robots.txt') ? undefined : new Response('{}'));

test('robots: regla más larga, comodines y agentes', () => {
  const texto = 'User-agent: *\nDisallow: /busca/*\nDisallow: /privado\nAllow: /privado/abierto\n\nUser-agent: Scrapy\nDisallow: /\n';
  assert.equal(rutaPermitida(texto, 'precios-farmacias/0.1', '/api/catalog_system/pub/products/search'), true);
  assert.equal(rutaPermitida(texto, 'precios-farmacias/0.1', '/busca/algo'), false);
  assert.equal(rutaPermitida(texto, 'precios-farmacias/0.1', '/privado/x'), false);
  assert.equal(rutaPermitida(texto, 'precios-farmacias/0.1', '/privado/abierto/x'), true);
  assert.equal(rutaPermitida(texto, 'Scrapy 2.8.0', '/api'), false);
  assert.equal(rutaPermitida('', 'precios-farmacias/0.1', '/x'), true);
});

test('una ruta que robots.txt cierra no se pide', async () => {
  const { cliente, hacerFetch } = crearCliente((url) =>
    url.endsWith('/robots.txt') ? new Response('User-agent: *\nDisallow: /cerrado/\n') : new Response('{}'),
  );
  await assert.rejects(cliente.obtener('https://a.test/cerrado/x'), BloqueoError);
  assert.deepEqual(hacerFetch.llamadas.map((l) => l.url), ['https://a.test/robots.txt']);
});

test('una petición a la vez por dominio, con la pausa entre cada una, y robots se lee una sola vez', async () => {
  const { cliente, reloj, hacerFetch } = crearCliente(sinRobots);
  await cliente.obtener('https://a.test/1');
  await cliente.obtener('https://a.test/2');
  assert.deepEqual(hacerFetch.llamadas.map((l) => l.url), ['https://a.test/robots.txt', 'https://a.test/1', 'https://a.test/2']);
  assert.deepEqual(reloj.esperas, [2000, 2000]);
  await cliente.obtener('https://b.test/1');
  assert.deepEqual(reloj.esperas, [2000, 2000, 2000], 'b.test solo espera entre su robots y su página');
});

test('se identifica con el User-Agent de la herramienta, sin datos personales', async () => {
  const { cliente, hacerFetch } = crearCliente(sinRobots);
  await cliente.obtener('https://a.test/1');
  assert.equal(hacerFetch.llamadas[1].opciones.headers['User-Agent'], USER_AGENT);
  assert.doesNotMatch(USER_AGENT, /@|mozilla|chrome/i);
  assert.equal(Object.keys(hacerFetch.llamadas[1].opciones.headers).includes('Cookie'), false);
});

test('los errores 5xx y de red se reintentan con espera creciente', async () => {
  let fallos = 0;
  const { cliente, reloj } = crearCliente((url) => {
    if (url.endsWith('/robots.txt')) return undefined;
    fallos += 1;
    if (fallos === 1) return new Response('', { status: 503 });
    if (fallos === 2) throw new Error('conexión caída');
    return new Response('{}');
  });
  const respuesta = await cliente.obtener('https://a.test/1');
  assert.equal(respuesta.status, 200);
  assert.ok(reloj.esperas.includes(5000) && reloj.esperas.includes(10000));
});

test('los reintentos se acaban: no insiste para siempre', async () => {
  const { cliente, hacerFetch } = crearCliente((url) => (url.endsWith('/robots.txt') ? undefined : new Response('', { status: 500 })));
  await assert.rejects(cliente.obtener('https://a.test/1'), /sigue respondiendo 500/);
  assert.equal(hacerFetch.llamadas.length, 1 + 4);
});

test('429: espera lo que pide la fuente, reintenta una vez y luego se detiene', async () => {
  const { cliente, reloj, hacerFetch } = crearCliente((url) =>
    url.endsWith('/robots.txt') ? undefined : new Response('', { status: 429, headers: { 'retry-after': '30' } }),
  );
  await assert.rejects(cliente.obtener('https://a.test/1'), BloqueoError);
  assert.ok(reloj.esperas.includes(30000));
  assert.equal(hacerFetch.llamadas.length, 1 + 2);
});

test('401, 402 y 403 y los desafíos de seguridad detienen de inmediato, sin reintentar', async () => {
  for (const status of [401, 402, 403]) {
    const { cliente, hacerFetch } = crearCliente((url) => (url.endsWith('/robots.txt') ? undefined : new Response('', { status })));
    await assert.rejects(cliente.obtener('https://a.test/1'), BloqueoError);
    assert.equal(hacerFetch.llamadas.length, 2);
  }
  for (const cabecera of ['cf-mitigated', 'x-vercel-mitigated']) {
    const { cliente } = crearCliente((url) => (url.endsWith('/robots.txt') ? undefined : new Response('', { headers: { [cabecera]: 'challenge' } })));
    await assert.rejects(cliente.obtener('https://a.test/1'), BloqueoError);
  }
});

test('un robots.txt bloqueado cuenta como bloqueo de la fuente', async () => {
  const { cliente, hacerFetch } = crearCliente(() => new Response('', { status: 403 }));
  await assert.rejects(cliente.obtener('https://a.test/1'), BloqueoError);
  assert.equal(hacerFetch.llamadas.length, 1);
});
