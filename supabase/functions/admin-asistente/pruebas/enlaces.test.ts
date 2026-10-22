/**
 * Los enlaces automáticos y el mapa generado por el panel: cada herramienta de
 * datos tiene que llevar a una pantalla que el mapa real admite.
 */

import assert from 'node:assert/strict';

import { enlacesAutomaticos, tituloDeLaPestana } from '../enlaces.ts';
import { pantallaDe } from '../herramientas/ejecutar.ts';
import { descripcionCompleta, HERRAMIENTAS, nombresDeDatos } from '../herramientas/index.ts';
import type { HerramientaDeDatos } from '../herramientas/tipos.ts';
import { compactarMapa, leerMapa, tituloDeLaRuta, validarEnlace } from '../mapa.ts';
import mapaCrudo from '../mapa.json' with { type: 'json' };

const MAPA = leerMapa(mapaCrudo);
const DATOS = HERRAMIENTAS.filter((h): h is HerramientaDeDatos => h.clase === 'datos');
const ID = '839bba23-640e-4f57-9280-c814013233bc';

Deno.test('el mapa generado: search en listas, cifras con la ruta de su pantalla y fichas con título', () => {
  assert.equal(validarEnlace(MAPA, { titulo: 'x', ruta: '/admin/metricas', search: { vista: 'mora', sub: 'rendimiento' } }).ok, true);
  assert.equal(validarEnlace(MAPA, { titulo: 'x', ruta: '/admin/cobranza', search: { vista: 'otra' } }).ok, false);
  // «true» vuelve a ser booleano: el router lee ?marca=true así.
  const marca = validarEnlace(MAPA, { titulo: 'x', ruta: '/admin/pacientes', search: { marca: 'true' } });
  assert.deepEqual(marca.ok && marca.enlace.search, { marca: true });

  const recuperado = MAPA.cifras.find((c) => c.id === 'cobranza-recuperado');
  assert.equal(recuperado?.ruta, '/admin/metricas');
  assert.equal(recuperado?.rpc, 'admin_collection_recovered');
  assert.equal(tituloDeLaRuta(MAPA, `/admin/pacientes/${ID}`), 'Ficha de un paciente');
  assert.equal(tituloDeLaRuta(MAPA, `/admin/financiamientos/${ID}`), 'Ficha de un financiamiento');
  assert.equal(tituloDeLaRuta(MAPA, '/admin/pagos-clinicas'), 'Pagos a clínicas');
  // Las pantallas de Ronda no están en el mapa de Helios.
  assert.equal(tituloDeLaRuta(MAPA, '/admin/personas'), null);
  assert.equal(tituloDeLaRuta(MAPA, '/admin/metricas'), 'Métricas');
  assert.equal(tituloDeLaRuta(MAPA, '/admin/riesgo'), null);
  assert.equal(tituloDeLaRuta(MAPA, '/admin/no-existe'), null);
});

Deno.test('el mapa compacto nombra solo las RPC que son herramientas', () => {
  const compacto = compactarMapa(MAPA, nombresDeDatos());
  assert.match(compacto, /Recuperado[^\n]*\(admin_collection_recovered\)/);
  assert.doesNotMatch(compacto, /admin_accounting_export|admin_on_time_collection/);
  assert.match(compacto, /- Por cobrar · \/admin\/cobranza \(search: [^)]*vista=calendario\|morosos\|promesas\|semana/);
  assert.match(compacto, /- Métricas › Semana › Rendimiento · \/admin\/metricas: /);
});

Deno.test('cada herramienta de datos lleva a una pantalla que el mapa real admite', () => {
  const entrada = { persona_id: ID, consumo_id: ID, local_id: ID, sql: 'select count(*) from pacientes' };
  for (const h of DATOS) {
    const pantalla = pantallaDe(h, entrada, [{ user_id: ID, charge_id: ID }, {}]);
    assert.ok(pantalla, `${h.nombre} no tiene pantalla`);
    const [enlace] = enlacesAutomaticos(MAPA, [pantalla], []);
    assert.equal(enlace?.ruta, pantalla.ruta, `${h.nombre}: el mapa no admite ${pantalla.ruta}`);
  }
  // Pagos reportados es la vista por defecto de /admin/cobros; el mapa todavía no lista
  // vista=reportados, así que ese parámetro se cae y queda el de la cola.
  const cola = DATOS.find((h) => h.nombre === 'admin_reconciliation_health');
  assert.ok(cola);
  const pantallaCola = pantallaDe(cola, {}, {});
  assert.ok(pantallaCola);
  assert.deepEqual(enlacesAutomaticos(MAPA, [pantallaCola], []), [
    { titulo: 'Pagos reportados', ruta: '/admin/cobros', search: { tab: 'pendientes' } },
  ]);
});

Deno.test('las pantallas que dependen del id: la ficha, o la lista si no hay una sola fila', () => {
  const buscar = DATOS.find((h) => h.nombre === 'admin_user_directory');
  const ficha = DATOS.find((h) => h.nombre === 'admin_user_detail');
  assert.ok(buscar && ficha);
  assert.deepEqual(pantallaDe(buscar, {}, [{ user_id: ID }]), { ruta: `/admin/pacientes/${ID}` });
  assert.deepEqual(pantallaDe(buscar, {}, [{ user_id: ID }, { user_id: ID }]), { ruta: '/admin/pacientes' });
  assert.deepEqual(pantallaDe(ficha, { persona_id: ID.toUpperCase() }, null), { ruta: `/admin/pacientes/${ID}` });
  const orden = DATOS.find((h) => h.nombre === 'admin_charge_detail');
  assert.ok(orden);
  assert.deepEqual(pantallaDe(orden, { consumo_id: ID }, null), { ruta: `/admin/financiamientos/${ID}` });
  assert.equal(pantallaDe(ficha, { persona_id: 'maría' }, null), null);
});

Deno.test('la descripción nombra la pantalla fija desde el campo', () => {
  const recuperado = DATOS.find((h) => h.nombre === 'admin_collection_recovered');
  assert.ok(recuperado);
  assert.match(descripcionCompleta(recuperado), /Pantalla: \/admin\/metricas\?vista=mora&sub=rendimiento\.$/);
  for (const h of DATOS) {
    assert.equal(descripcionCompleta(h).match(/Pantalla/g)?.length, 1, `${h.nombre} nombra la pantalla más de una vez`);
  }
});

Deno.test('enlacesAutomaticos: sin repetir pestañas, sin las ya enlazadas, como mucho tres, y sin el search que el mapa no admite', () => {
  const r = enlacesAutomaticos(
    MAPA,
    [
      // Una pestaña que ya no existe cae a la pantalla, con su nombre.
      { ruta: '/admin/cobranza', search: { vista: 'rendimiento' } },
      { ruta: '/admin/cobranza' },
      { ruta: '/admin/resumen', search: { semana: '2026-09-21' } },
      { ruta: '/admin/metricas', search: { vista: 'mora', sub: 'cupos', otra: 'x' } },
      { ruta: '/admin/no-existe' },
      { ruta: '/admin/alertas' },
      { ruta: '/admin/metricas', search: { vista: 'caja', sub: 'proyeccion' } },
      { ruta: '/admin/pagos-clinicas' },
    ],
    [{ titulo: 'Ver las alertas', ruta: '/admin/alertas' }],
  );
  assert.deepEqual(r, [
    { titulo: 'Por cobrar', ruta: '/admin/cobranza' },
    { titulo: 'Métricas › Riesgo › Cupos', ruta: '/admin/metricas', search: { vista: 'mora', sub: 'cupos' } },
    { titulo: 'Métricas › Caja › Proyección y banco', ruta: '/admin/metricas', search: { vista: 'caja', sub: 'proyeccion' } },
  ]);
});

Deno.test('el título de una pestaña: la sub-pestaña, la pestaña o la pantalla', () => {
  assert.equal(tituloDeLaPestana(MAPA, { ruta: '/admin/metricas', search: { vista: 'semana', sub: 'rendimiento' } }), 'Métricas › Semana › Rendimiento');
  assert.equal(tituloDeLaPestana(MAPA, { ruta: '/admin/metricas', search: { vista: 'caja' } }), 'Métricas › Caja');
  assert.equal(tituloDeLaPestana(MAPA, { ruta: '/admin/cobranza', search: { vista: 'semana' } }), 'Por cobrar › Cohortes');
  assert.equal(tituloDeLaPestana(MAPA, { ruta: '/admin/avisos' }), 'Avisos');
  assert.equal(tituloDeLaPestana(MAPA, { ruta: '/admin/cobranza', search: { vista: 'promesas' } }), 'Promesas');
  assert.equal(tituloDeLaPestana(MAPA, { ruta: '/admin/cobranza', search: { vista: 'calendario' } }), 'Por cobrar');
});
