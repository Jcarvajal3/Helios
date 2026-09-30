/**
 * Pruebas de las pastillas de umbral.
 *
 *   npx tsx src/features/admin/umbrales.test.ts
 *
 * Lo que se vigila: que la pastilla salga solo al cruzar un umbral, que el
 * corte sea inclusivo (7 % ya es alerta si la alerta es 7 %), que sin valor o
 * sin umbral no haya color, y que los textos digan el umbral con el formato
 * que se les pasa.
 */
import { senalPorUmbral, senalPorUmbralAlto } from './umbrales'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

/** '7 %', con la coma de aquí: el formato lo pone quien llama. */
const pct = (n: number) => `${n.toLocaleString('es-VE')} %`

function espera(
  sale: { tone: string; texto: string } | undefined,
  tone: string | undefined,
  texto: string | undefined,
  titulo: string,
) {
  const ok = sale?.tone === tone && sale?.texto === texto
  comprueba(ok, titulo, JSON.stringify(sale))
}

const mora = { alerta: 7, critico: 15 }

console.log('── Peor cuanto más alto (mora, impago) ───────────────────────')
espera(senalPorUmbral(3, mora, pct), undefined, undefined, 'por debajo de la alerta, sin pastilla')
espera(senalPorUmbral(0, mora, pct), undefined, undefined, 'cero, sin pastilla')
espera(senalPorUmbral(7, mora, pct), 'warning', 'Alerta · desde 7 %', 'justo en la alerta ya es alerta')
espera(senalPorUmbral(7.8, mora, pct), 'warning', 'Alerta · desde 7 %', '7,8 % es alerta')
espera(senalPorUmbral(15, mora, pct), 'error', 'Crítico · desde 15 %', 'justo en el crítico ya es crítico')
espera(senalPorUmbral(100, mora, pct), 'error', 'Crítico · desde 15 %', '100 % es crítico')
espera(
  senalPorUmbral(8, { alerta: 5, critico: 7.5 }, pct),
  'error',
  'Crítico · desde 7,5 %',
  'el umbral sale con el formato de quien llama',
)

console.log('── Mejor cuanto más alto (cobro a tiempo) ────────────────────')
const meta = { bueno: 90, alerta: 70 }
espera(senalPorUmbralAlto(95, meta, pct), 'success', 'En meta', 'por encima de la meta')
espera(senalPorUmbralAlto(90, meta, pct), 'success', 'En meta', 'justo en la meta ya está en meta')
espera(senalPorUmbralAlto(80, meta, pct), 'warning', 'Bajo · meta 90 %', 'entre la alerta y la meta, ámbar')
espera(senalPorUmbralAlto(70, meta, pct), 'warning', 'Bajo · meta 90 %', 'justo en la alerta, ámbar')
espera(senalPorUmbralAlto(0, meta, pct), 'error', 'Bajo · meta 90 %', 'cero, rojo')

console.log('── Sin datos no hay color ────────────────────────────────────')
espera(senalPorUmbral(null, mora, pct), undefined, undefined, 'sin valor')
espera(senalPorUmbral(20, null, pct), undefined, undefined, 'sin umbral')
espera(senalPorUmbral(Number.NaN, mora, pct), undefined, undefined, 'NaN no es un valor')
espera(senalPorUmbralAlto(null, meta, pct), undefined, undefined, 'alto, sin valor')
espera(senalPorUmbralAlto(50, null, pct), undefined, undefined, 'alto, sin umbral')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
