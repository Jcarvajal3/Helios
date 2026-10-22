import assert from 'node:assert/strict';

import { elegirProveedor, limpiarClave } from '../configuracion.ts';

const entorno = (valores: Record<string, string>) => (nombre: string) => valores[nombre];

Deno.test('la clave se limpia de comillas y espacios pegados', () => {
  assert.equal(limpiarClave('  "sk-ant-XYZ" '), 'sk-ant-XYZ');
  assert.equal(limpiarClave("'sk-ant-XYZ'"), 'sk-ant-XYZ');
  assert.equal(limpiarClave('""'), undefined);
  assert.equal(limpiarClave(undefined), undefined);
});

Deno.test('con la clave de Anthropic, Sonnet 5.5 por defecto', () => {
  assert.deepEqual(elegirProveedor(entorno({ ANTHROPIC_API_KEY: 'a' })), {
    proveedor: 'anthropic',
    apiKey: 'a',
    modelo: 'claude-sonnet-5-5',
  });
});

Deno.test('sin la clave no hay proveedor, y se dice cuál falta (la de Gemini no sirve)', () => {
  assert.deepEqual(elegirProveedor(entorno({})), { proveedor: null, falta: 'ANTHROPIC_API_KEY' });
  assert.deepEqual(elegirProveedor(entorno({ GEMINI_API_KEY: 'g' })), { proveedor: null, falta: 'ANTHROPIC_API_KEY' });
});

Deno.test('ASISTENTE_MODELO elige entre los admitidos; uno desconocido vuelve al de por defecto', () => {
  assert.deepEqual(elegirProveedor(entorno({ ANTHROPIC_API_KEY: 'a', ASISTENTE_MODELO: 'claude-haiku-5-5' })), {
    proveedor: 'anthropic',
    apiKey: 'a',
    modelo: 'claude-haiku-5-5',
  });
  const eleccion = elegirProveedor(entorno({ ANTHROPIC_API_KEY: 'a', ASISTENTE_MODELO: 'gemini-3.8-flash' }));
  assert.equal(eleccion.proveedor === 'anthropic' && eleccion.modelo, 'claude-sonnet-5-5');
});
