import assert from 'node:assert/strict'
import { test } from 'node:test'

import { enlaceSeguro, fechaDeCaracas, textoDePrecio, tokenDelHash } from './precios.ts'

test('los precios van al estilo venezolano', () => {
  assert.equal(textoDePrecio('VES', 55432.1), 'Bs 55.432,10')
  assert.equal(textoDePrecio('VES', 958.2), 'Bs 958,20')
  assert.equal(textoDePrecio('USD', 12.5), '$12,50')
  assert.equal(textoDePrecio('USD', 100), '$100')
  assert.equal(textoDePrecio('USD', 1250.5), '$1.250,50')
})

test('la fecha es la de Caracas, no la del navegador', () => {
  assert.equal(fechaDeCaracas('2026-11-06T02:00:00Z'), '05/11/2026')
  assert.equal(fechaDeCaracas('2026-11-06T12:00:00Z'), '06/11/2026')
  assert.equal(fechaDeCaracas('no es fecha'), '')
})

test('solo se abren enlaces https', () => {
  assert.equal(enlaceSeguro('https://farmacia.example/a'), 'https://farmacia.example/a')
  assert.equal(enlaceSeguro('http://farmacia.example/a'), null)
  assert.equal(enlaceSeguro('javascript:alert(1)'), null)
  assert.equal(enlaceSeguro(''), null)
})

test('el token sale del hash exacto', () => {
  assert.equal(tokenDelHash('#/medicinas/abc123'), 'abc123')
  assert.equal(tokenDelHash('#/medicinas/'), null)
  assert.equal(tokenDelHash('#/nuevo'), null)
  assert.equal(tokenDelHash('#/medicinas/abc/otra'), null)
  assert.equal(tokenDelHash(''), null)
})
