import assert from 'node:assert/strict';

import { crearCanal, formatearEvento, PING } from '../sse.ts';

async function leerTodo(stream: ReadableStream<Uint8Array>): Promise<string> {
  const decodificador = new TextDecoder();
  let texto = '';
  const lector = stream.getReader();
  for (;;) {
    const { value, done } = await lector.read();
    if (done) return texto;
    texto += decodificador.decode(value, { stream: true });
  }
}

Deno.test('un evento es event + data en una línea + línea en blanco', () => {
  assert.equal(formatearEvento({ tipo: 'texto', datos: { delta: 'Hola' } }), 'event: texto\ndata: {"delta":"Hola"}\n\n');
});

Deno.test('los saltos de línea del texto no rompen el evento', () => {
  const cable = formatearEvento({ tipo: 'texto', datos: { delta: 'uno\ndos\r\n\ntres' } });
  const lineas = cable.split('\n');
  assert.equal(lineas.length, 4);
  assert.equal(lineas[0], 'event: texto');
  assert.deepEqual(JSON.parse(lineas[1].slice('data: '.length)), { delta: 'uno\ndos\r\n\ntres' });
  assert.equal(lineas[2], '');
});

Deno.test('los tipos del protocolo salen con su nombre', () => {
  assert.match(formatearEvento({ tipo: 'fin', datos: { modelo: 'm', entrada: 1, salida: 2, cacheLeida: 3 } }), /^event: fin\n/);
  assert.match(
    formatearEvento({ tipo: 'herramienta', datos: { id: 't1', rotulo: 'Leyendo', estado: 'consultando' } }),
    /"estado":"consultando"/,
  );
  assert.match(formatearEvento({ tipo: 'error', datos: { codigo: 'otro', mensaje: 'x', reintentar: true } }), /"reintentar":true/);
});

Deno.test('el canal escribe en orden, cierra y después no escribe nada', async () => {
  const canal = crearCanal({ pingMs: 0 });
  canal.enviar({ tipo: 'texto', datos: { delta: 'a' } });
  canal.enviar({ tipo: 'enlace', datos: { titulo: 'Ver', ruta: '/admin/cobranza' } });
  canal.cerrar();
  canal.enviar({ tipo: 'texto', datos: { delta: 'tarde' } });
  canal.cerrar();
  const texto = await leerTodo(canal.stream);
  assert.equal(
    texto,
    'event: texto\ndata: {"delta":"a"}\n\n' +
      'event: enlace\ndata: {"titulo":"Ver","ruta":"/admin/cobranza"}\n\n',
  );
});

Deno.test('si el panel corta, se dispara la señal para dejar de gastar', async () => {
  const canal = crearCanal({ pingMs: 0 });
  assert.equal(canal.senal.aborted, false);
  await canal.stream.cancel();
  assert.equal(canal.senal.aborted, true);
  canal.enviar({ tipo: 'texto', datos: { delta: 'nadie escucha' } });
});

Deno.test('el latido es un comentario que el cliente ignora', async () => {
  const canal = crearCanal({ pingMs: 5 });
  await new Promise((r) => setTimeout(r, 30));
  canal.cerrar();
  const texto = await leerTodo(canal.stream);
  assert.ok(texto.startsWith(PING));
  assert.ok(texto.split('\n\n').every((b) => b === '' || b.startsWith(':')));
});
