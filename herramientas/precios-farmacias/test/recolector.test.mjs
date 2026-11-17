import assert from 'node:assert/strict';
import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { fetchFalso, leerFixture, relojFalso } from './ayudas.mjs';
import { COLUMNAS, leerCsv } from '../src/filas.mjs';
import { FUENTES } from '../src/fuentes/index.mjs';
import { crearFuenteVtex, filasDeProducto } from '../src/fuentes/vtex.mjs';
import { ClienteHttp } from '../src/http.mjs';
import { correrRecoleccion } from '../src/recolector.mjs';
import { precioDeFicha } from '../src/verificar.mjs';

const BASE = 'https://farmacia.test';
const AHORA = new Date('2026-11-06T14:00:00Z');

function producto(i, cambios = {}) {
  return {
    productName: `PRODUCTO ${i} TAB 10MG X10`,
    brand: 'LAB',
    link: `${BASE}/${i}/p`,
    'Clase terapéutica': ['Clase'],
    items: [
      {
        itemId: String(i),
        nameComplete: `PRODUCTO ${i} TAB 10MG X10`,
        sellers: [{ sellerDefault: true, commertialOffer: { Price: i + 0.5, IsAvailable: true } }],
      },
    ],
    ...cambios,
  };
}

// Tienda VTEX falsa: catálogos por categoría, con la cabecera «resources» real.
function tiendaFalsa(catalogo, { codigoMoneda = 'USD', fallaEn } = {}) {
  return fetchFalso((url) => {
    if (url.endsWith('/robots.txt')) return undefined;
    if (url.includes('/saleschannel/1')) return Response.json({ CurrencyCode: codigoMoneda });
    if (fallaEn?.(url)) return new Response('', { status: 403 });
    const { searchParams } = new URL(url);
    const ruta = searchParams.get('fq').replace(/^C:\//, '').replace(/\/$/, '');
    const desde = Number(searchParams.get('_from'));
    const hasta = Number(searchParams.get('_to'));
    const todos = catalogo[ruta] ?? [];
    return Response.json(todos.slice(desde, hasta + 1), {
      status: 206,
      headers: { resources: `${desde}-${hasta}/${todos.length}` },
    });
  });
}

function fuentePrueba(cambios = {}) {
  return crearFuenteVtex({
    id: 'prueba',
    nombre: 'Farmacia de Prueba',
    base: BASE,
    categorias: [{ ruta: '6/1' }, { ruta: '6/2', exigeClaseTerapeutica: true }],
    estado: 'activa',
    ...cambios,
  });
}

async function conCarpeta(prueba) {
  const dirSalida = await mkdtemp(join(tmpdir(), 'precios-'));
  try {
    await prueba(dirSalida);
  } finally {
    await rm(dirSalida, { recursive: true, force: true });
  }
}

function correr({ fuentes, hacerFetch, dirSalida, ...resto }) {
  const reloj = relojFalso();
  const cliente = new ClienteHttp({ fetch: hacerFetch, esperar: reloj.esperar, ahora: reloj.ahora });
  return correrRecoleccion({ fuentes, cliente, dirSalida, reloj: () => AHORA, ...resto });
}

test('VTEX: nombre, concentración, presentación, disponibilidad, vendedor y precio salen de la fixture', async () => {
  const productos = JSON.parse(await leerFixture('vtex-productos.json'));
  const contexto = { farmacia: 'F', fuente: 'prueba', base: BASE, moneda: 'USD', visto_en: '2026-11-06T10:00:00-04:00' };
  const [uno, dos, tres, cuatro] = productos.map((p) => filasDeProducto(p, contexto));

  assert.equal(uno.filas[0].nombre, 'PRUEBAMOL TAB 500MG X20 LAB');
  assert.equal(uno.filas[0].precio, 1.22, 'el precio de venta, no el de lista');
  assert.equal(uno.filas[0].presentacion, 'Caja - 20 TAB');
  assert.equal(uno.filas[0].laboratorio, 'LABORATORIO DE PRUEBA');
  assert.equal(uno.filas[0].disponible, 'si');

  assert.equal(dos.filas[0].nombre, 'JARABINA SOL ORAL X120ML 15 MG/5 ML', 'la concentración va al final');
  assert.equal(dos.filas[0].disponible, 'no');

  assert.equal(tres.filas.length, 0, 'un producto sin precio no entra');
  assert.equal(tres.sinPrecio, 1);

  assert.equal(cuatro.filas[0].precio, 7.25, 'el del vendedor predeterminado');
  assert.equal(cuatro.filas[0].disponible, '', 'si la fuente no lo dice, vacío');
  assert.equal(cuatro.filas[0].url, BASE, 'sin enlace https, el de la fuente');
});

test('recolección completa: pagina, filtra lo que no es medicamento y escribe el CSV', async () => {
  await conCarpeta(async (dirSalida) => {
    const catalogo = {
      '6/1': Array.from({ length: 120 }, (_, i) => producto(i)),
      '6/2': [producto(200), producto(201, { 'Clase terapéutica': undefined })],
    };
    const hacerFetch = tiendaFalsa(catalogo);
    const resumen = await correr({ fuentes: [fuentePrueba()], hacerFetch, dirSalida });

    assert.equal(resumen.archivo, join(dirSalida, 'precios-20261106.csv'));
    assert.equal(resumen.filas, 121);
    assert.deepEqual(resumen.por_farmacia, { 'Farmacia de Prueba': 121 });
    assert.deepEqual(resumen.por_moneda, { USD: 121 });
    assert.equal(resumen.fuentes.prueba.estado, 'completa');
    assert.equal(resumen.fuentes.prueba.descartes.no_medicamento, 1);

    const contenido = await readFile(resumen.archivo, 'utf8');
    assert.equal(contenido.split('\n')[0], COLUMNAS.join(','));
    const filas = leerCsv(contenido);
    assert.equal(filas.length, 121);
    assert.equal(filas[0].visto_en, '2026-11-06T10:00:00-04:00');
    assert.equal(filas[0].fuente, 'prueba');
  });
});

test('--limite da una muestra con nombre aparte y reanudar no repite lo ya leído', async () => {
  await conCarpeta(async (dirSalida) => {
    const catalogo = { '6/1': Array.from({ length: 120 }, (_, i) => producto(i)), '6/2': [producto(200)] };
    const primera = tiendaFalsa(catalogo);
    const muestra = await correr({ fuentes: [fuentePrueba()], hacerFetch: primera, dirSalida, limite: 10 });

    assert.equal(muestra.filas, 10);
    assert.equal(muestra.archivo, join(dirSalida, 'precios-20261106-parcial.csv'));
    assert.equal(muestra.fuentes.prueba.estado, 'limite');
    const paginasPrimera = primera.llamadas.filter((l) => l.url.includes('products/search'));
    assert.equal(paginasPrimera.length, 1, 'con la primera página ya alcanza');

    const segunda = tiendaFalsa(catalogo);
    const final = await correr({ fuentes: [fuentePrueba()], hacerFetch: segunda, dirSalida });
    const leidas = segunda.llamadas.map((l) => l.url).filter((u) => u.includes('products/search'));
    assert.equal(leidas.some((u) => u.includes('fq=C:/6/1/') && u.includes('_from=0&')), false, 'no relee la página ya guardada');
    assert.equal(final.filas, 121);
    assert.equal(final.duplicadas, 0);
    assert.equal(final.archivo, join(dirSalida, 'precios-20261106.csv'));

    const tercera = tiendaFalsa(catalogo);
    await correr({ fuentes: [fuentePrueba()], hacerFetch: tercera, dirSalida });
    assert.equal(tercera.llamadas.filter((l) => l.url.includes('products/search')).length, 0, 'ya estaba todo leído');

    const cuarta = tiendaFalsa(catalogo);
    const deNuevo = await correr({ fuentes: [fuentePrueba()], hacerFetch: cuarta, dirSalida, desdeCero: true });
    assert.equal(deNuevo.filas, 121);
    assert.ok(cuarta.llamadas.some((l) => l.url.includes('_from=0&')), '--desde-cero vuelve a leer');
  });
});

test('una fuente bloqueada se detiene, sus filas quedan como parciales y las demás siguen', async () => {
  await conCarpeta(async (dirSalida) => {
    const catalogo = { '6/1': Array.from({ length: 60 }, (_, i) => producto(i)), '6/2': [] };
    const hacerFetch = tiendaFalsa(catalogo, { fallaEn: (url) => url.includes('_from=50') });
    const otra = {
      id: 'otra',
      nombre: 'Otra',
      estado: 'activa',
      segmentos: async () => [{ clave: 'unico' }],
      leerPagina: async (_cliente, _segmento, _desde, visto_en) => ({
        filas: [{ farmacia: 'Otra', nombre: 'X 10MG', precio: 2, moneda: 'VES', url: `${BASE}/x`, visto_en, fuente: 'otra' }],
        leidos: 1,
        total: 1,
        siguiente: null,
      }),
    };
    const resumen = await correr({ fuentes: [fuentePrueba(), otra], hacerFetch, dirSalida });
    assert.equal(resumen.fuentes.prueba.estado, 'bloqueada');
    assert.equal(resumen.fuentes.otra.estado, 'completa');
    assert.equal(resumen.hay_fallas, true);
    assert.deepEqual(resumen.por_moneda, { USD: 50, VES: 1 });
    assert.equal(resumen.archivo, join(dirSalida, 'precios-20261106-parcial.csv'));
    assert.equal(hacerFetch.llamadas.filter((l) => l.url.includes('_from=50')).length, 1, 'no insiste tras el 403');
  });
});

test('una fuente en pausa no recibe ni una petición y sin filas no se escribe CSV', async () => {
  await conCarpeta(async (dirSalida) => {
    const hacerFetch = fetchFalso(() => {
      throw new Error('no debía pedirse nada');
    });
    const resumen = await correr({ fuentes: FUENTES, hacerFetch, dirSalida });
    assert.equal(hacerFetch.llamadas.length, 0);
    assert.equal(resumen.archivo, null);
    assert.equal(resumen.filas, 0);
    assert.equal(resumen.fuentes.keiti.estado, 'pausada');
    assert.deepEqual(await readdir(dirSalida), []);
  });
});

test('registro: hoy ninguna fuente está activa y cada pausa dice por qué', () => {
  for (const fuente of FUENTES) {
    assert.equal(fuente.estado, 'pausada', `${fuente.id}: activarla exige el sí de Javier (FUENTES.md)`);
    assert.ok(fuente.motivo, fuente.id);
  }
});

test('una moneda desconocida detiene la fuente en lugar de inventarla', async () => {
  await conCarpeta(async (dirSalida) => {
    const hacerFetch = tiendaFalsa({}, { codigoMoneda: 'EUR' });
    const resumen = await correr({ fuentes: [fuentePrueba()], hacerFetch, dirSalida });
    assert.equal(resumen.fuentes.prueba.estado, 'fallo');
    assert.match(resumen.fuentes.prueba.motivo, /moneda no reconocida/);
  });
});

test('verificar lee el precio y la moneda del JSON-LD de la ficha', async () => {
  assert.deepEqual(precioDeFicha(await leerFixture('ficha.html')), { precio: 1.22, moneda: 'USD' });
  assert.equal(precioDeFicha('<html></html>'), null);
});
