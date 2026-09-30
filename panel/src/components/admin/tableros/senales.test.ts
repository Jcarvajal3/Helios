/**
 * Pruebas de las pastillas y las marcas de los tableros.
 *
 *   npx tsx src/components/admin/tableros/senales.test.ts
 *
 * Lo que se vigila: que el impago sea crítico al llegar al empate aunque sus
 * umbrales digan otra cosa, que el tope de un medidor deje ver todas sus
 * marcas, y que los cortes del capital sean los del semáforo (rojo por debajo
 * de un ciclo, ámbar por debajo de dos).
 */
import {
  marcasDeUmbral,
  marcasDelCapital,
  pctDeUmbral,
  senalDelCapital,
  senalDelImpago,
  topeDelMedidor,
} from './senales'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const impago = { alerta: 5, critico: 8 }

console.log('── El umbral escrito ─────────────────────────────────────────')
comprueba(pctDeUmbral(7) === '7 %', 'un entero va sin decimales', pctDeUmbral(7))
comprueba(pctDeUmbral(15.6) === '15,6 %', 'con decimal, la coma de aquí', pctDeUmbral(15.6))

console.log('── El impago ─────────────────────────────────────────────────')
comprueba(senalDelImpago(null, 15, impago) === undefined, 'sin tasa no hay pastilla')
comprueba(senalDelImpago(2, 15, impago) === undefined, 'por debajo de la alerta no hay pastilla')
comprueba(senalDelImpago(6, 15, impago)?.tone === 'warning', 'entre alerta y crítico, alerta')
comprueba(senalDelImpago(9, 15, impago)?.tone === 'error', 'pasado el crítico, crítico')
{
  const s = senalDelImpago(4, 3.5, impago)
  comprueba(
    s?.tone === 'error' && s.texto === 'Crítico · empate 3,5 %',
    'al llegar al empate es crítico aunque el umbral diga que no',
    JSON.stringify(s),
  )
}
comprueba(senalDelImpago(4, 3.5, null)?.tone === 'error', 'el empate manda también sin umbrales')
comprueba(senalDelImpago(4, null, null) === undefined, 'sin empate ni umbrales, nada')

console.log('── Las marcas de un umbral ───────────────────────────────────')
{
  const m = marcasDeUmbral({ alerta: 7, critico: 15 })
  comprueba(m.length === 2 && m[0].rotulo === '7 %' && m[1].valor === 15, 'dos marcas rotuladas', JSON.stringify(m))
  comprueba(marcasDeUmbral(null).length === 0, 'sin umbral, sin marcas')
}

console.log('── El tope del medidor ───────────────────────────────────────')
comprueba(topeDelMedidor([7.8, 7, 15]) === 18.75, 'la mayor marca, con un cuarto de aire', String(topeDelMedidor([7.8, 7, 15])))
comprueba(topeDelMedidor([40, 10]) === 50, 'si la cifra pasa las marcas, manda la cifra')
comprueba(topeDelMedidor([0, null, undefined]) === 1, 'todo a cero: un medidor vacío, no NaN')
comprueba(topeDelMedidor([Number.NaN, 4]) === 5, 'un NaN no rompe la cuenta')

console.log('── El capital ────────────────────────────────────────────────')
comprueba(senalDelCapital({ tono: 'success', queda: 100 }) === undefined, 'en verde no hay pastilla')
comprueba(senalDelCapital({ tono: 'warning', queda: 100 })?.tone === 'warning', 'ámbar con pastilla')
comprueba(senalDelCapital({ tono: 'error', queda: 0 })?.texto === 'Sin capital libre', 'sin capital libre lo dice')
comprueba(senalDelCapital({ tono: 'error', queda: 10 })?.texto === 'No cubre un ciclo', 'rojo con capital: no cubre un ciclo')
{
  // 1.000 de capital, 50 por semana y ciclos de 2 semanas: un ciclo son 100.
  const m = marcasDelCapital({ capital: 1000, ritmo: 50, semanasDeCiclo: 2 })
  comprueba(
    m.length === 2 && m[0].valor === 80 && m[1].valor === 90,
    'ámbar al 80 % y rojo al 90 %',
    JSON.stringify(m),
  )
  const fuera = marcasDelCapital({ capital: 150, ritmo: 50, semanasDeCiclo: 2 })
  comprueba(
    fuera.length === 1 && fuera[0].rotulo === '1 ciclo',
    'la marca que cae fuera de la pista no se pinta',
    JSON.stringify(fuera),
  )
  comprueba(marcasDelCapital({ capital: 1000, ritmo: null, semanasDeCiclo: 2 }).length === 0, 'sin ritmo no hay cortes')
  comprueba(marcasDelCapital({ capital: 1000, ritmo: 50, semanasDeCiclo: null }).length === 0, 'sin ciclo no hay cortes')
  comprueba(marcasDelCapital({ capital: 0, ritmo: 50, semanasDeCiclo: 2 }).length === 0, 'sin capital no hay cortes')
}

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} ${fallos === 1 ? 'fallo' : 'fallos'}.`)
if (fallos > 0) process.exit(1)
