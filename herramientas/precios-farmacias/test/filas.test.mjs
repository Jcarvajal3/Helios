import assert from 'node:assert/strict';
import { test } from 'node:test';

import { filaBase, leerFixture } from './ayudas.mjs';
import {
  aCsv,
  COLUMNAS,
  esFarmaciaExcluida,
  fechaCompacta,
  formatearPrecio,
  horaCaracas,
  leerCsv,
  prepararFilas,
  unirConcentracion,
  validarFila,
} from '../src/filas.mjs';
import { filasDeBuscar } from '../src/fuentes/keiti.mjs';

test('Farmadon y Farmapaz se excluyen sin importar mayúsculas, acentos ni espacios', () => {
  for (const nombre of ['Farmadon', 'FARMADON', 'farmadón', 'FARMADÓN C.A.', 'Farma Don', 'Farmapaz', 'FARMAPAZ', 'farmapáz', 'Farma-Paz', 'Farmacia Farmapaz']) {
    assert.equal(esFarmaciaExcluida(nombre), true, nombre);
  }
  for (const nombre of ['Farmatodo', 'Farmacia SAAS', 'Locatel', 'FarmaBien', 'Farmacia La Paz', 'Don Farma']) {
    assert.equal(esFarmaciaExcluida(nombre), false, nombre);
  }
});

test('ninguna fila de Farmadon o Farmapaz llega al CSV, venga de donde venga', async () => {
  const respuesta = JSON.parse(await leerFixture('keiti-buscar.json'));
  const leidas = filasDeBuscar(respuesta, { visto_en: '2026-11-06T10:00:00-04:00' });
  assert.equal(leidas.length, 5, 'la región Oriente ya no entra');

  const { filas, excluidas } = prepararFilas(leidas);
  assert.equal(excluidas, 4);
  assert.deepEqual(filas.map((fila) => fila.farmacia), ['Farmacia Permitida']);
  assert.doesNotMatch(aCsv(filas).normalize('NFD').replace(/\p{Diacritic}/gu, ''), /farma\s?don|farma\s?paz/i);
});

test('keiti: se toma el precio en bolívares y solo regiones que cubren Caracas', async () => {
  const respuesta = JSON.parse(await leerFixture('keiti-buscar.json'));
  const [fila] = filasDeBuscar(respuesta, { visto_en: '2026-11-06T10:00:00-04:00' });
  assert.equal(fila.precio, 2976);
  assert.equal(fila.moneda, 'VES');
  assert.equal(fila.sku, '7590000000017');
  assert.equal(fila.fuente, 'keiti');
  assert.equal(fila.url, 'https://keiti.io/');
  assert.equal(fila.disponible, '');
});

test('el CSV lleva la cabecera exacta, en orden, y sobrevive a comas, comillas y acentos', () => {
  const nombre = 'JARABE "NIÑOS", SOL 15 MG';
  const csv = aCsv([filaBase({ nombre, sku: '' })]);
  assert.equal(csv.split('\n')[0], 'farmacia,nombre,precio,moneda,laboratorio,presentacion,sku,url,disponible,visto_en,fuente');
  assert.deepEqual(COLUMNAS, csv.split('\n')[0].split(','));
  assert.ok(csv.endsWith('\n'));

  const [leida] = leerCsv(csv);
  assert.equal(leida.nombre, nombre);
  assert.equal(leida.sku, '');
  assert.equal(leida.precio, '1.22');
});

test('precio: punto decimal, sin separador de miles y mayor que 0', () => {
  assert.equal(formatearPrecio(1.22), '1.22');
  assert.equal(formatearPrecio('1093.27'), '1093.27');
  assert.equal(formatearPrecio(2976), '2976');
  for (const invalido of [0, -1, '0', '0.00', '1.234,56', '1,22', '1,234.56', 'Ref. 1', '', null, undefined, NaN, Infinity, 1e21, 1e-7]) {
    assert.equal(formatearPrecio(invalido), null, String(invalido));
  }
});

test('una fila sin los campos obligatorios no entra y se cuenta el motivo', () => {
  const casos = [
    [{ farmacia: '' }, 'sin_farmacia'],
    [{ nombre: ' ' }, 'sin_nombre'],
    [{ precio: 0 }, 'precio_invalido'],
    [{ moneda: 'EUR' }, 'moneda_invalida'],
    [{ url: 'http://farmacia.test/1' }, 'url_no_https'],
    [{ disponible: 'tal vez' }, 'disponible_invalido'],
    [{ visto_en: '2026-11-06 10:00' }, 'visto_en_invalido'],
    [{ fuente: '' }, 'sin_fuente'],
  ];
  for (const [cambios, motivo] of casos) {
    assert.equal(validarFila(filaBase(cambios)).motivo, motivo);
  }
  const { filas, rechazos } = prepararFilas([filaBase({ precio: 0 }), filaBase({ precio: '1,22', sku: 'b' }), filaBase({ sku: 'c' })]);
  assert.equal(filas.length, 1);
  assert.deepEqual(rechazos, { precio_invalido: 2 });
});

test('dedup: farmacia más sku, o farmacia más nombre si no hay sku; queda la lectura más reciente', () => {
  const temprano = '2026-11-06T09:00:00-04:00';
  const tarde = '2026-11-06T11:00:00-04:00';
  const { filas, duplicadas } = prepararFilas([
    filaBase({ precio: 1, visto_en: tarde }),
    filaBase({ precio: 2, visto_en: temprano }),
    filaBase({ farmacia: 'FARMACIA PERMITIDA', precio: 3, visto_en: temprano }),
    filaBase({ farmacia: 'Otra', precio: 4 }),
    filaBase({ sku: '', nombre: 'SIN SKU 10MG', precio: 5, visto_en: temprano }),
    filaBase({ sku: '', nombre: 'sin sku 10mg', precio: 6, visto_en: tarde }),
    filaBase({ sku: '', nombre: 'SIN SKU 20MG', precio: 7 }),
  ]);
  assert.equal(duplicadas, 3);
  assert.deepEqual(filas.map((fila) => fila.precio), ['1', '4', '6', '7']);
});

test('la concentración se une al final solo si el nombre no la trae', () => {
  assert.equal(unirConcentracion('PRUEBAMOL TAB 500MG X20', '500 MG'), 'PRUEBAMOL TAB 500MG X20');
  assert.equal(unirConcentracion('JARABINA SOL ORAL X120ML', '15 MG/5 ML'), 'JARABINA SOL ORAL X120ML 15 MG/5 ML');
  assert.equal(unirConcentracion('SIN DOSIS', ''), 'SIN DOSIS');
});

test('visto_en y la fecha del archivo van en hora de Caracas, con zona', () => {
  const fecha = new Date('2026-11-07T02:30:00Z');
  assert.equal(horaCaracas(fecha), '2026-11-06T22:30:00-04:00');
  assert.equal(fechaCompacta(fecha), '20261106');
});
