import assert from 'node:assert/strict';

import { crearFiltroDeTexto } from '../texto.ts';

/** Pasa los trozos por el filtro y devuelve lo que sale, trozo a trozo. */
function filtrar(trozos: string[]): { salidas: string[]; total: string; cortado: boolean } {
  const filtro = crearFiltroDeTexto();
  const salidas = trozos.map((t) => filtro.empujar(t));
  salidas.push(filtro.vaciar());
  return { salidas, total: salidas.join(''), cortado: filtro.cortado };
}

Deno.test('el texto normal sale entero y en el mismo trozo', () => {
  const r = filtrar(['Se recuperaron 2,40 € esta semana.', ' La mora es del 3,75 %.']);
  assert.deepEqual(r.salidas, ['Se recuperaron 2,40 € esta semana.', ' La mora es del 3,75 %.', '']);
  assert.equal(r.cortado, false);
});

Deno.test('una llamada escrita como texto se corta desde el principio de su palabra', () => {
  const llaves = filtrar(['Se recuperaron 2,40 €.\n\n{mostrar_enlace(ruta="/admin/cobranza", titulo:"Ver"}']);
  assert.equal(llaves.total, 'Se recuperaron 2,40 €.');
  assert.equal(llaves.cortado, true);

  const basura = filtrar(['Cada persona gasta 25,75 €.\n\n narod:mostrar_e', 'nlace(...)', ' y más texto']);
  assert.equal(basura.total, 'Cada persona gasta 25,75 €.');
});

Deno.test('la marca partida entre dos trozos también se corta, y lo que no la completa se suelta', () => {
  const partida = filtrar(['Hay 2 alertas. {mos', 'trar_enlace(ruta="/admin/alertas")}']);
  assert.deepEqual(partida.salidas, ['Hay 2 alertas. ', '', '']);

  // «mostrar» como palabra española se retiene un trozo y sale con el siguiente.
  const verbo = filtrar(['Para mostr', 'ar la cifra, abre la pantalla.']);
  assert.deepEqual(verbo.salidas, ['Para ', 'mostrar la cifra, abre la pantalla.', '']);
  assert.equal(verbo.cortado, false);

  // Lo retenido al final de la vuelta sale al vaciar.
  assert.deepEqual(filtrar(['Esto es lo que hay que m']).salidas, ['Esto es lo que hay que ', 'm']);
});
