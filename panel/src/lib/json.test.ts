/**
 * Pruebas del lector de JSON de las RPC.
 *
 *   npx tsx src/lib/json.test.ts
 *
 * Había cinco copias y no coincidían en los casos límite: una escribía
 * «null» en un texto que faltaba, otra dejaba pasar `NaN` a una suma y otra
 * leía `''` como cero. Estas pruebas fijan la regla que quedó.
 */
import {
  booleano,
  comoFila,
  comoLista,
  filaONula,
  filas,
  numero,
  numeroONulo,
  numeros,
  texto,
  textoONulo,
  textos,
} from './json'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle: string) {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function igual<T>(dio: T, esperado: T, titulo: string) {
  comprueba(JSON.stringify(dio) === JSON.stringify(esperado), titulo, `dio ${JSON.stringify(dio)}`)
}

function exacto<T>(dio: T, esperado: T, titulo: string) {
  comprueba(Object.is(dio, esperado), titulo, `dio ${String(dio)}`)
}

console.log('── comoFila / filaONula ──────────────────────────────────────')
igual(comoFila({ a: 1 }), { a: 1 }, 'un objeto pasa')
igual(comoFila(null), {}, 'null es {}')
igual(comoFila('x'), {}, 'un texto es {}')
igual(comoFila(3), {}, 'un número es {}')
const original = { a: 1 }
comprueba(comoFila(original) !== original, 'devuelve una copia', 'devolvió el mismo objeto')
exacto(filaONula(null), null, 'filaONula: null es null')
exacto(filaONula(undefined), null, 'filaONula: undefined es null')
igual(filaONula({ b: 2 }), { b: 2 }, 'filaONula: un objeto pasa')

console.log('\n── comoLista / filas ─────────────────────────────────────────')
igual(comoLista([1, 'a']), [1, 'a'], 'una lista pasa')
igual(comoLista(null), [], 'null es []')
igual(comoLista({ 0: 'a' }), [], 'un objeto no es una lista')
igual(filas([{ a: 1 }, null, 'x']), [{ a: 1 }, {}, {}], 'filas: cada elemento, como fila')
igual(filas(undefined), [], 'filas: undefined es []')

console.log('\n── numeroONulo ───────────────────────────────────────────────')
exacto(numeroONulo(0), 0, 'el 0 es un dato')
exacto(numeroONulo(12.5), 12.5, 'un número pasa')
exacto(numeroONulo('12.5'), 12.5, 'un numeric de PostgREST llega como texto y se lee')
exacto(numeroONulo(null), null, 'null es null')
exacto(numeroONulo(undefined), null, 'undefined es null')
exacto(numeroONulo(''), null, 'vacío es null, no 0 (una copia lo leía como 0)')
exacto(numeroONulo('abc'), null, 'un texto que no es número es null, no NaN')
exacto(numeroONulo(Number.POSITIVE_INFINITY), null, 'infinito es null')
exacto(numeroONulo(true), null, 'un booleano no es un número')
exacto(numeroONulo({}), null, 'un objeto no es un número')

console.log('\n── numero ────────────────────────────────────────────────────')
exacto(numero(7), 7, 'un número pasa')
exacto(numero('7'), 7, 'un número como texto')
exacto(numero(null), 0, 'null vale 0')
exacto(numero(undefined), 0, 'undefined vale 0, no NaN (una copia daba NaN)')
exacto(numero('abc'), 0, 'basura vale 0, no NaN')

console.log('\n── textoONulo ────────────────────────────────────────────────')
exacto(textoONulo('hola'), 'hola', 'un texto pasa')
exacto(textoONulo(''), null, 'vacío es null (dos copias lo dejaban pasar)')
exacto(textoONulo(null), null, 'null es null')
exacto(textoONulo(undefined), null, 'undefined es null, no «undefined»')
exacto(textoONulo(1043), '1043', 'un número se lee como su texto')
exacto(textoONulo(Number.NaN), null, 'NaN no es un texto')
exacto(textoONulo(true), null, 'un booleano no es un texto (una copia escribía «true»)')
exacto(textoONulo({ a: 1 }), null, 'un objeto no es un texto')

console.log('\n── texto ─────────────────────────────────────────────────────')
exacto(texto('abc'), 'abc', 'un texto pasa')
exacto(texto(''), '', 'vacío se queda vacío')
exacto(texto(null), '', 'null es vacío, no «null» (una copia lo escribía)')
exacto(texto(undefined, '—'), '—', 'con respaldo')
exacto(texto(42), '42', 'un número se lee como su texto')
exacto(texto({}), '', 'un objeto es el respaldo')

console.log('\n── booleano ──────────────────────────────────────────────────')
exacto(booleano(true), true, 'true')
exacto(booleano(false), false, 'false')
exacto(booleano('true'), false, "'true' no es verdad")
exacto(booleano(1), false, '1 no es verdad')
exacto(booleano(null), false, 'null es falso')

console.log('\n── textos / numeros ──────────────────────────────────────────')
igual(textos(['a', 1, null, 'b']), ['a', 'b'], 'textos: descarta lo que no es texto')
igual(textos(null), [], 'textos: null es []')
igual(numeros([1, '2', null, 'x', '', 3]), [1, 2, 3], 'numeros: descarta lo que no se lee')
igual(numeros('1,2'), [], 'numeros: un texto no es una lista')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
