import assert from 'node:assert/strict';

import type { Base } from '../base.ts';
import { ejecutarHerramienta } from '../herramientas/ejecutar.ts';
import { buscarHerramienta } from '../herramientas/index.ts';
import { busquedasDeLaRuta, compactarMapa, leerMapa, validarEnlace } from '../mapa.ts';
import mapaCrudo from '../mapa.json' with { type: 'json' };

/** Un mapa pequeño con la forma que escribe `npm run asistente:mapa`. */
const MAPA = leerMapa({
  version: 1,
  pantallas: [
    {
      id: 'cartera-vencida',
      titulo: 'Cartera vencida',
      descripcion: 'Quién debe. Y otra frase que no entra.',
      ruta: '/admin/cobranza',
      searchConocidos: [{ tramo: 'sin_contactar' }, { vista: 'rendimiento' }],
    },
    { id: 'personas', titulo: 'Personas', descripcion: 'Las cuentas.', ruta: '/admin/personas', searchConocidos: [{ marca: true }] },
    { id: 'ajustes-tasa-bcv', titulo: 'Tasa BCV', descripcion: 'La tasa.', ruta: '/admin/ajustes', search: { tab: 'tasa' } },
    { id: 'fuera', titulo: 'No es del admin', ruta: '/otra' },
    { id: 'incompleta' },
  ],
  cifras: [
    { id: 'mora', titulo: 'Mora', que: 'Vencido sobre vivo.', rpc: 'admin_overview', pantalla: 'riesgo', ruta: '/admin/riesgo', search: { vista: 'resumen' } },
  ],
  acciones: [
    { id: 'aprobar', titulo: 'Aprobar un pago', descripcion: 'x', ruta: '/admin/cobros', soloSuperAdmin: false },
    { id: 'mant', titulo: 'Encender el mantenimiento', descripcion: 'x', ruta: '/admin/ajustes', search: { tab: 'mantenimiento' }, soloSuperAdmin: true },
  ],
  fichas: [{ ruta: '/admin/personas/$id', que: 'La ficha de una persona.' }, { ruta: '/admin/sin-id', que: 'mal' }],
});

const ID = '839bba23-640e-4f57-9280-c814013233bc';

const base: Base = {
  usuario: () => Promise.resolve(ID),
  rpc: () => Promise.reject(new Error('mostrar_enlace no debería leer la base')),
};

async function enlazar(entrada: Record<string, unknown>) {
  const herramienta = buscarHerramienta('mostrar_enlace');
  assert.ok(herramienta);
  return await ejecutarHerramienta(herramienta, entrada, { base, mapa: MAPA });
}

Deno.test('leerMapa descarta lo incompleto, lo que no es del admin y las fichas sin $id', () => {
  assert.deepEqual(MAPA.pantallas.map((p) => p.id), ['cartera-vencida', 'personas', 'ajustes-tasa-bcv']);
  assert.equal(MAPA.fichas.length, 1);
  assert.equal(MAPA.acciones.length, 2);
  assert.equal(MAPA.regenerar, false);
});

Deno.test('mostrar_enlace rechaza una ruta que no está en el mapa', async () => {
  const r = await enlazar({ titulo: 'Ver la bóveda', ruta: '/admin/boveda' });
  assert.equal(r.esError, true);
  assert.match(r.contenido, /no está en el mapa/);
  assert.equal(r.evento, undefined);
});

Deno.test('mostrar_enlace acepta una pantalla del mapa y la manda al panel', async () => {
  const r = await enlazar({
    titulo: 'Ver el rendimiento',
    ruta: '/admin/cobranza',
    search: [{ clave: 'vista', valor: 'rendimiento' }],
  });
  assert.equal(r.esError, false);
  assert.equal(r.contenido, 'ok');
  assert.deepEqual(r.evento, {
    tipo: 'enlace',
    datos: { titulo: 'Ver el rendimiento', ruta: '/admin/cobranza', search: { vista: 'rendimiento' } },
  });
});

Deno.test('una ruta que solo sale en una cifra o una acción también vale', async () => {
  assert.equal((await enlazar({ titulo: 'Ver la mora', ruta: '/admin/riesgo', search: [{ clave: 'vista', valor: 'resumen' }] })).esError, false);
  assert.equal((await enlazar({ titulo: 'Aprobar pagos', ruta: '/admin/cobros' })).esError, false);
});

Deno.test('mostrar_enlace valida los parámetros de la URL contra lo que usa el catálogo', async () => {
  const clave = await enlazar({ titulo: 'x', ruta: '/admin/cobranza', search: [{ clave: 'tab', valor: 'a' }] });
  assert.equal(clave.esError, true);
  assert.match(clave.contenido, /no admite el parámetro «tab»; admite: tramo, vista/);

  const valor = await enlazar({ titulo: 'x', ruta: '/admin/cobranza', search: [{ clave: 'vista', valor: 'mapa' }] });
  assert.equal(valor.esError, true);
  assert.match(valor.contenido, /los válidos son: rendimiento/);

  // El valor sale con el tipo del mapa: el panel espera un booleano.
  const marca = await enlazar({ titulo: 'Marcadas', ruta: '/admin/personas', search: [{ clave: 'marca', valor: 'true' }] });
  assert.deepEqual(marca.evento, { tipo: 'enlace', datos: { titulo: 'Marcadas', ruta: '/admin/personas', search: { marca: true } } });
});

Deno.test('varias entradas con la misma ruta suman sus parámetros', () => {
  assert.deepEqual([...busquedasDeLaRuta(MAPA, '/admin/ajustes')], [['tab', ['tasa', 'mantenimiento']]]);
});

Deno.test('una ficha vale solo con un uuid y sin parámetros', async () => {
  const bien = await enlazar({ titulo: 'Ver la ficha', ruta: `/admin/personas/${ID}` });
  assert.equal(bien.esError, false);
  const mal = await enlazar({ titulo: 'Ver la ficha', ruta: '/admin/personas/maria' });
  assert.equal(mal.esError, true);
  const truco = await enlazar({ titulo: 'Ver', ruta: `/admin/personas/${ID}/../../ajustes` });
  assert.equal(truco.esError, true);
  const conSearch = await enlazar({ titulo: 'Ver', ruta: `/admin/personas/${ID}`, search: [{ clave: 'tab', valor: 'x' }] });
  assert.equal(conSearch.esError, true);
});

Deno.test('validarEnlace pide título', () => {
  assert.deepEqual(validarEnlace(MAPA, { titulo: '  ', ruta: '/admin/cobranza' }), {
    ok: false,
    error: 'El enlace necesita un título.',
  });
});

Deno.test('el mapa compacto es estable y lleva rutas, parámetros y una línea', () => {
  const a = compactarMapa(MAPA);
  assert.equal(a, compactarMapa(leerMapa(JSON.parse(JSON.stringify(MAPA)))));
  assert.match(a, /- Cartera vencida · \/admin\/cobranza \(search: tramo=sin_contactar; vista=rendimiento\): Quién debe\.\n/);
  assert.match(a, /- Tasa BCV · \/admin\/ajustes\?tab=tasa: La tasa\./);
  assert.match(a, /- Encender el mantenimiento · \/admin\/ajustes\?tab=mantenimiento \(solo super admin\)/);
  assert.match(a, /- Mora \(admin_overview\) · \/admin\/riesgo\?vista=resumen: Vencido sobre vivo\./);
  assert.match(a, /- La ficha de una persona\. · \/admin\/personas\/\$id \(\$id es el uuid\)/);
});

Deno.test('el mapa.json de la función se carga entero y enlaza las fichas', () => {
  const mapa = leerMapa(mapaCrudo);
  assert.ok(mapa.pantallas.length >= 5);
  assert.ok(mapa.fichas.some((f) => f.ruta === '/admin/pacientes/$id'));
  assert.ok(mapa.fichas.some((f) => f.ruta === '/admin/financiamientos/$id'));
  const r = validarEnlace(mapa, { titulo: 'Cartera', ruta: '/admin/cobranza' });
  assert.equal(r.ok, true);
});
