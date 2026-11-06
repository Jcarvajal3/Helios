import assert from 'node:assert/strict'
import { test } from 'node:test'

import { aFilas, enLotes, leerCsv, leerPrecio } from './lector-precios.mjs'

test('lee comas, punto y coma, comillas, BOM y saltos de Windows', () => {
  assert.deepEqual(leerCsv('a,b\r\n1,2\r\n'), [['a', 'b'], ['1', '2']])
  assert.deepEqual(leerCsv('﻿a;b\n1,5;2\n'), [['a', 'b'], ['1,5', '2']])
  assert.deepEqual(leerCsv('a,b\n"x, y","di ""no"""\n'), [['a', 'b'], ['x, y', 'di "no"']])
  assert.deepEqual(leerCsv('a\n"dos\nlíneas"'), [['a'], ['dos\nlíneas']])
})

test('unas comillas sin cerrar no se interpretan', () => {
  assert.throws(() => leerCsv('a\n"sin cerrar'), /comillas/)
})

test('el precio no se adivina', () => {
  assert.equal(leerPrecio('12.50'), '12.50')
  assert.equal(leerPrecio('12,50'), '12.50')
  assert.equal(leerPrecio(12.5), '12.5')
  assert.equal(leerPrecio('1234'), '1234')
  assert.equal(leerPrecio('1.234,50'), null)
  assert.equal(leerPrecio('1.234'), null)
  assert.equal(leerPrecio('1,234'), null)
  assert.equal(leerPrecio('12.500'), null)
  assert.equal(leerPrecio('1,234.50'), null)
  assert.equal(leerPrecio('Bs 12'), null)
  assert.equal(leerPrecio(''), null)
  assert.equal(leerPrecio(0), null)
  assert.equal(leerPrecio(-1), null)
})

test('sin una columna obligatoria no se sigue', () => {
  assert.throws(() => aFilas([['farmacia', 'nombre', 'precio']]), /moneda/)
  assert.throws(() => aFilas([]), /vacío/)
})

test('cada fila se acepta o se rechaza con su número en el archivo', () => {
  const { filas, rechazos } = aFilas([
    ['Farmacia', 'NOMBRE', 'precio', 'moneda', 'columna rara'],
    ['Uno', 'AMOXICILINA 500MG', '12,50', 'VES', 'x'],
    ['', '', '', '', ''],
    ['Uno', 'IBUPROFENO 400MG', '1.234,50', 'VES', 'x'],
    ['Dos', 'LOSARTAN 50MG', 5, 'USD', 'x'],
  ])
  assert.equal(filas.length, 2)
  assert.equal(filas[0].precio, '12.50')
  assert.equal(filas[0].fila_archivo, 2)
  assert.equal(filas[1].precio, '5')
  assert.equal(filas[1].fila_archivo, 5)
  assert.equal(filas[0].url, '')
  assert.equal('columna rara' in filas[0], false)
  assert.deepEqual(rechazos.map((r) => r.fila), [4])
})

test('un archivo mal codificado se rechaza, no se carga roto', () => {
  const { filas, rechazos } = aFilas([
    ['farmacia', 'nombre', 'precio', 'moneda'],
    ['Uno', 'ACETAMINOF�N 500MG', '1', 'USD'],
    ['Uno', 'X\u00001 5MG', '1', 'USD'],
  ])
  assert.equal(filas.length, 1)
  assert.equal(filas[0].nombre, 'X1 5MG')
  assert.deepEqual(rechazos.map((r) => r.fila), [2])
})

test('una fecha de Excel se vuelve ISO', () => {
  const { filas } = aFilas([
    ['farmacia', 'nombre', 'precio', 'moneda', 'visto_en'],
    ['Uno', 'X 1MG', '1', 'USD', new Date('2026-11-06T12:00:00Z')],
  ])
  assert.equal(filas[0].visto_en, '2026-11-06T12:00:00.000Z')
})

test('los lotes no pierden filas', () => {
  assert.deepEqual(enLotes([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]])
  assert.deepEqual(enLotes([], 2), [])
})
