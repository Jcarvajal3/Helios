/**
 * Lo que el panel enseña lo lee gente que no programa: sin identificadores,
 * con el número de orden como «#1013», fechas legibles y títulos de pantalla
 * que se entienden.
 */

import assert from 'node:assert/strict';

import type { Base } from '../base.ts';
import { enlacesAutomaticos } from '../enlaces.ts';
import { visualizarRendimiento } from '../herramientas/analisis.ts';
import { visualizarConsulta } from '../herramientas/consulta.ts';
import { ejecutarHerramienta } from '../herramientas/ejecutar.ts';
import { buscarHerramienta } from '../herramientas/index.ts';
import { celdaLegible, diaLegible, esIdentificador, etiquetaLegible } from '../herramientas/legible.ts';
import { leerMapa } from '../mapa.ts';
import mapaCrudo from '../mapa.json' with { type: 'json' };

const ID = '981fda8f-25ef-45fe-a90d-b0942e1cb74e';
const MAPA_REAL = leerMapa(mapaCrudo);
const MAPA_VACIO = leerMapa({ pantallas: [], fichas: [], cifras: [] });
const sinBase: Base = { usuario: () => Promise.resolve('u'), rpc: () => Promise.resolve({ data: null, error: null }) };

Deno.test('las piezas: identificadores, fechas, órdenes y sí/no', () => {
  assert.equal(esIdentificador('user_id', ['x']), true);
  assert.equal(esIdentificador('referencia', [ID, null]), true);
  assert.equal(esIdentificador('persona', ['MARÍA P.']), false);
  assert.equal(diaLegible('2026-09-24'), '24 sep');
  assert.equal(diaLegible('2026-09-25T02:47:48+00:00'), '24 sep');
  assert.equal(diaLegible('Bar Nocturno'), null);
  assert.equal(etiquetaLegible('numero_orden', 1013), '#1013');
  assert.equal(etiquetaLegible('en_grupo', true), 'Sí');
  assert.equal(etiquetaLegible('sistema', null), 'Sin dato');
  assert.equal(celdaLegible('numero_orden', 1013), '#1013');
  assert.equal(celdaLegible('numero_orden', '#1013'), '#1013');
});

Deno.test('una tabla de consulta quita los identificadores y escribe la orden con #', () => {
  const datos = { filas: [{ orden_id: ID, numero_orden: 1013, user_id: ID, paciente: 'JAVIER C.', clinica: 'Consultorio A', consulta_usd: 12.5, total_a_cobrar_usd: 14.24 }] };
  const v = visualizarConsulta({ titulo: 'Órdenes', mostrar: 'tabla' }, datos);
  assert.ok(v?.evento?.tipo === 'tabla');
  assert.deepEqual(v.evento.datos.columnas.map((c) => c.rotulo), ['Orden', 'Paciente', 'Clínica', 'Financiado ($)', 'Total a cobrar ($)']);
  assert.deepEqual(v.evento.datos.filas[0], {
    numero_orden: '#1013',
    paciente: 'JAVIER C.',
    clinica: 'Consultorio A',
    consulta_usd: 12.5,
    total_a_cobrar_usd: 14.24,
  });
});

Deno.test('una consulta que solo trae identificadores no se pinta, y un select * tampoco', () => {
  const soloIds = visualizarConsulta({ titulo: 'x', mostrar: 'tabla' }, { filas: [{ consumo_id: ID, user_id: ID }, { consumo_id: ID, user_id: ID }] });
  assert.equal(soloIds?.evento, undefined);
  assert.match(soloIds?.nota ?? '', /solo trae identificadores/);

  const mirar = visualizarConsulta(
    { sql: 'select * from consumos limit 1', titulo: 'Estructura de consumos', mostrar: 'tabla' },
    { filas: [{ consumo_id: ID, numero_orden: 1013, user_id: ID }] },
  );
  assert.equal(mirar?.evento, undefined);
  assert.match(mirar?.nota ?? '', /select \*/);
});

Deno.test('un gráfico no usa identificadores como rótulo: sale la tabla sin ellos', () => {
  const datos = { filas: [{ user_id: ID, persona: 'JAVIER C.', consumos: 8 }, { user_id: ID, persona: 'USUARIO P.', consumos: 1 }] };
  const conId = visualizarConsulta({ titulo: 'x', mostrar: 'barras', etiqueta: 'user_id', valor: 'consumos' }, datos);
  assert.equal(conId?.evento?.tipo, 'tabla');
  assert.match(conId?.nota ?? '', /identificadores internos/);
  // Sin decirlo, el rótulo es la primera columna de texto que no es un id.
  const solo = visualizarConsulta({ titulo: 'x', mostrar: 'barras' }, datos);
  assert.ok(solo?.evento?.tipo === 'grafico');
  assert.deepEqual(solo.evento.datos.puntos.map((p) => p.etiqueta), ['JAVIER C.', 'USUARIO P.']);
});

Deno.test('mostrar_tabla del modelo también pierde los identificadores', async () => {
  const h = buscarHerramienta('mostrar_tabla');
  assert.ok(h);
  const r = await ejecutarHerramienta(h, {
    titulo: 'Estructura de consumos',
    columnas: [{ clave: 'consumo_id', rotulo: 'Consumo id' }, { clave: 'numero_orden', rotulo: 'Número orden' }, { clave: 'user', rotulo: 'User id' }],
    filas: [[ID, 1013, ID]],
  }, { base: sinBase, mapa: MAPA_VACIO });
  assert.ok(r.evento?.tipo === 'tabla');
  assert.deepEqual(r.evento.datos.columnas.map((c) => c.clave), ['numero_orden']);
  assert.deepEqual(r.evento.datos.filas, [{ numero_orden: '#1013' }]);
  assert.match(r.contenido, /identificadores/);

  const soloIds = await ejecutarHerramienta(h, {
    titulo: 'x', columnas: [{ clave: 'consumo_id', rotulo: 'Consumo' }], filas: [[ID]],
  }, { base: sinBase, mapa: MAPA_VACIO });
  assert.equal(soloIds.esError, true);
});

Deno.test('mostrar_grafico no acepta un identificador como etiqueta', async () => {
  const h = buscarHerramienta('mostrar_grafico');
  assert.ok(h);
  const r = await ejecutarHerramienta(h, { tipo: 'barras', titulo: 'x', unidad: 'numero', puntos: [{ etiqueta: ID, valor: 1 }] }, {
    base: sinBase,
    mapa: MAPA_VACIO,
  });
  assert.equal(r.esError, true);
});

Deno.test('el rendimiento de las clínicas llega en tabla, de la que más financió, con el cambio en %', () => {
  const datos = {
    desde: '2026-08-27',
    hasta: '2026-09-25',
    locales: [
      { nombre: 'Consultorio B', consumo_usd: 10, consumo_anterior_usd: 0, consumos: 2, personas: 2, nuevas: 1, ticket_medio_usd: 5, merchant_id: ID },
      { nombre: 'Consultorio A', consumo_usd: 60, consumo_anterior_usd: 40, consumos: 8, personas: 5, nuevas: 3, ticket_medio_usd: 7.5, merchant_id: ID },
    ],
  };
  const v = visualizarRendimiento({}, datos);
  assert.ok(v?.evento?.tipo === 'tabla');
  assert.deepEqual(v.evento.datos.filas.map((f) => [f.clinica, f.cambio]), [['Consultorio A', 50], ['Consultorio B', null]]);
  assert.deepEqual(v.evento.datos.columnas.map((c) => c.rotulo), [
    'Clínica', 'Financiado ($)', 'Frente al periodo anterior', 'Órdenes', 'Pacientes', 'Nuevos', 'Monto medio ($)',
  ]);
  assert.ok(!v.evento.datos.columnas.some((c) => /id/i.test(c.clave)));
  assert.equal(visualizarRendimiento({}, { locales: [datos.locales[0]] }), null);
});

Deno.test('el enlace a una pestaña lleva su nombre: Promesas, no Por cobrar', () => {
  assert.deepEqual(enlacesAutomaticos(MAPA_REAL, [{ ruta: '/admin/cobranza', search: { vista: 'promesas' } }], []), [
    { titulo: 'Promesas', ruta: '/admin/cobranza', search: { vista: 'promesas' } },
  ]);
});

Deno.test('el calendario de cobro pide las dos fechas y no enseña el cotejo con el libro', async () => {
  const h = buscarHerramienta('admin_receivables_by_day');
  assert.ok(h && h.clase === 'datos');
  const sinFechas = await ejecutarHerramienta(h, { desde: '2026-09-22' }, { base: sinBase, mapa: MAPA_VACIO });
  assert.equal(sinFechas.esError, true);
  assert.deepEqual(h.recortar?.({ cotejo: { libro_usd: 1 }, periodo: { cuotas: 4 } }), { periodo: { cuotas: 4 } });
});
