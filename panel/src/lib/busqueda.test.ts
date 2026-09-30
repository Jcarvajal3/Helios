/**
 * Pruebas de los validadores de la URL.
 *
 *   npx tsx src/lib/busqueda.test.ts
 *
 * El caso que lo motivó: `?tramo=foo` en Cobranza se casteaba sin mirar y la
 * pantalla reventaba al buscar la etiqueta de un tramo que no existe.
 */
import { comoBooleano, comoDia, comoEntero, comoId, comoTexto, unoDe } from './busqueda'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle: string) {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function igual<T>(dio: T, esperado: T, titulo: string) {
  comprueba(Object.is(dio, esperado), titulo, `dio ${JSON.stringify(dio)}`)
}

console.log('── unoDe ─────────────────────────────────────────────────────')
const TRAMOS = ['por_vencer', 'vence_hoy', 'todos'] as const
igual(unoDe(TRAMOS, 'vence_hoy'), 'vence_hoy', 'un valor de la lista pasa')
igual(unoDe(TRAMOS, 'foo'), undefined, '«foo» no pasa (el caso de Cobranza)')
igual(unoDe(TRAMOS, ''), undefined, 'vacío no pasa')
igual(unoDe(TRAMOS, undefined), undefined, 'undefined no pasa')
igual(unoDe(TRAMOS, null), undefined, 'null no pasa')
igual(unoDe(TRAMOS, 'VENCE_HOY'), undefined, 'distingue mayúsculas')
igual(unoDe(TRAMOS, ['vence_hoy']), undefined, 'un array no pasa')
const DIAS = ['7', '30', '90'] as const
igual(unoDe(DIAS, 30), '30', 'el número 30 (así lo lee el router) vale como «30»')
igual(unoDe(DIAS, '30'), '30', 'el texto «30» también')
igual(unoDe(DIAS, 31), undefined, 'un número que no está no pasa')
igual(unoDe(DIAS, NaN), undefined, 'NaN no pasa')

console.log('\n── comoDia ───────────────────────────────────────────────────')
igual(comoDia('2026-09-25'), '2026-09-25', 'un día normal')
igual(comoDia('2028-02-29'), '2028-02-29', '29 de febrero bisiesto')
igual(comoDia('2026-02-29'), undefined, '29 de febrero no bisiesto')
igual(comoDia('2026-02-30'), undefined, '30 de febrero')
igual(comoDia('2026-13-01'), undefined, 'mes 13')
igual(comoDia('2026-00-10'), undefined, 'mes 0')
igual(comoDia('2026-09-00'), undefined, 'día 0')
igual(comoDia('2026-9-5'), undefined, 'sin ceros delante')
igual(comoDia('25/09/2026'), undefined, 'formato clínica')
igual(comoDia('2026-09-25T10:00'), undefined, 'con hora')
igual(comoDia(' 2026-09-25'), undefined, 'con espacio')
igual(comoDia(20260925), undefined, 'un número')
igual(comoDia(undefined), undefined, 'undefined')

console.log('\n── comoTexto ─────────────────────────────────────────────────')
igual(comoTexto('  hola  '), 'hola', 'recorta espacios')
igual(comoTexto(''), undefined, 'vacío es undefined')
igual(comoTexto('   '), undefined, 'solo espacios es undefined')
igual(comoTexto(1043), '1043', 'un número llega como texto')
igual(comoTexto('x'.repeat(200))?.length, 120, 'se recorta a 120 por defecto')
igual(comoTexto('abcdef', 3), 'abc', 'con otro tope')
igual(comoTexto('ab   cdef', 4), 'ab', 'sin espacio colgando tras recortar')
igual(comoTexto(true), undefined, 'un booleano no es texto')
igual(comoTexto({ q: 'x' }), undefined, 'un objeto no es texto')

console.log('\n── comoEntero ────────────────────────────────────────────────')
igual(comoEntero(30), 30, 'un número')
igual(comoEntero('30'), 30, 'su texto')
igual(comoEntero(' 30 '), 30, 'con espacios')
igual(comoEntero('-5'), -5, 'negativo sin rango')
igual(comoEntero(2.5), undefined, 'con decimales no')
igual(comoEntero('2.5'), undefined, 'texto con decimales no')
igual(comoEntero('1e3'), undefined, 'notación científica no')
igual(comoEntero('30dias'), undefined, 'con letras no')
igual(comoEntero(''), undefined, 'vacío no')
igual(comoEntero(NaN), undefined, 'NaN no')
igual(comoEntero(Infinity), undefined, 'infinito no')
igual(comoEntero(9999, { min: 1, max: 366 }), undefined, 'por encima del tope no')
igual(comoEntero(0, { min: 1, max: 366 }), undefined, 'por debajo del mínimo no')
igual(comoEntero(366, { min: 1, max: 366 }), 366, 'el tope entra')
igual(comoEntero('1', { min: 1 }), 1, 'el mínimo entra')
igual(comoEntero('-0'), 0, '«-0» es 0')
igual(comoEntero('99999999999999999999'), undefined, 'fuera de lo seguro no')

console.log('\n── comoBooleano ──────────────────────────────────────────────')
igual(comoBooleano(true), true, 'true')
igual(comoBooleano('true'), true, "'true'")
igual(comoBooleano('1'), true, "'1'")
igual(comoBooleano(1), true, '1 (así llega ?x=1)')
igual(comoBooleano(false), undefined, 'false es ausente')
igual(comoBooleano('false'), undefined, "'false' es ausente")
igual(comoBooleano('0'), undefined, "'0' es ausente")
igual(comoBooleano('yes'), undefined, "'yes' no")
igual(comoBooleano(undefined), undefined, 'undefined')

console.log('\n── comoId ────────────────────────────────────────────────────')
const ID = '3f2b8c1e-9a4d-4e7b-8c2a-1d5e6f7a8b9c'
igual(comoId(ID), ID, 'un uuid')
igual(comoId(ID.toUpperCase()), ID, 'en mayúsculas vuelve en minúsculas')
igual(comoId(` ${ID} `), ID, 'con espacios')
igual(comoId('3f2b8c1e9a4d4e7b8c2a1d5e6f7a8b9c'), undefined, 'sin guiones no')
igual(comoId('3f2b8c1e-9a4d-4e7b-8c2a-1d5e6f7a8b9'), undefined, 'un carácter de menos')
igual(comoId('zzzzzzzz-9a4d-4e7b-8c2a-1d5e6f7a8b9c'), undefined, 'letras que no son hex')
igual(comoId('1043'), undefined, 'un número de orden no es un id')
igual(comoId(1043), undefined, 'ni como número')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
