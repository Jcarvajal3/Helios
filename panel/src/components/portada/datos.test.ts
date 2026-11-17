/**
 * Pruebas de las cifras de la portada y de las páginas para buscadores.
 *
 *   npx tsx src/components/portada/datos.test.ts
 *
 * Lo que se vigila: que `desglose` reparta el total como la base (docs/07
 * «Cuentas»: inicial del 50% y dos cuotas, la segunda con el céntimo que
 * sobra), que la inicial, las cuotas y el total cuadren al céntimo, que las
 * preguntas lleven las cifras de hoy y que ningún texto público diga «sin
 * inicial», «0% de inicial» ni use el vocabulario prohibido.
 */
import { PREGUNTAS, PREGUNTA_COSTO, desglose, dinero } from './datos'
import { CALENDARIO_DE_COBRO, GUIAS, TABLA_DE_CUOTAS, cadaCuota } from './guias'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle: unknown = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${JSON.stringify(detalle)}`}`)
}

console.log('── La cuenta de la inicial ───────────────────────────────────')

const cien = desglose(100)
comprueba(
  cien.total === 113.92 && cien.inicial === 56.96 && cien.cuota === 28.48 && cien.cuota2 === 28.48,
  '$100 → $113,92: inicial $56,96 y dos cuotas de $28,48',
  cien,
)

const treinta = desglose(30)
comprueba(
  treinta.total === 34.18 && treinta.inicial === 17.09 && treinta.cuota === 8.55 && treinta.cuota2 === 8.54,
  '$30 → $34,18: inicial $17,09, cuotas de $8,55 y $8,54',
  treinta,
)

let descuadres: number[] = []
for (let centimos = 100; centimos <= 15000; centimos += 37) {
  const d = desglose(centimos / 100)
  const suma = Math.round((d.inicial + d.cuota + d.cuota2) * 100)
  if (suma !== Math.round(d.total * 100) || d.cuota2 > d.cuota || d.cuota - d.cuota2 > 0.011) {
    descuadres.push(centimos / 100)
  }
}
comprueba(descuadres.length === 0, 'inicial + cuota 1 + cuota 2 = total, al céntimo', descuadres.slice(0, 5))

descuadres = []
for (let centimos = 100; centimos <= 15000; centimos += 37) {
  const d = desglose(centimos / 100)
  // Con un total de céntimos impares, medio céntimo arriba (`round` de la base).
  const mitad = Math.round(d.total * 100) / 2
  if (Math.round(d.inicial * 100) !== Math.round(mitad)) descuadres.push(centimos / 100)
}
comprueba(descuadres.length === 0, 'la inicial es la mitad del total, redondeada', descuadres.slice(0, 5))

comprueba(
  cadaCuota({ cuota: 8.55, cuota2: 8.54 }) === '$8,55 y $8,54' && cadaCuota(cien) === '$28,48',
  'la tabla dice las dos cuotas si no salen iguales',
)
comprueba(
  TABLA_DE_CUOTAS.every((f) => f.inicial > 0),
  'la tabla de cuotas trae la inicial',
)

console.log('── Los textos ────────────────────────────────────────────────')

comprueba(
  PREGUNTA_COSTO.respuesta.includes(dinero(cien.inicial)) &&
    PREGUNTA_COSTO.respuesta.includes(dinero(cien.cuota)) &&
    PREGUNTA_COSTO.respuesta.includes(dinero(cien.total)),
  '«¿Cuánto cuesta?» dice el total, la inicial y la cuota',
  PREGUNTA_COSTO.respuesta,
)

const inicial = GUIAS['/pacientes'].preguntas.find((p) => p.pregunta === '¿Tengo que pagar una inicial?')
comprueba(!!inicial && inicial.respuesta.startsWith('Sí'), '«¿Tengo que pagar una inicial?» → sí', inicial)

const textos = JSON.stringify([GUIAS, PREGUNTAS, CALENDARIO_DE_COBRO])
for (const viejo of [/sin inicial/i, /0% de inicial/i, /hoy no pagas/i, /no pagas nada/i, /no paga nada/i]) {
  comprueba(!viejo.test(textos), `ningún texto dice ${viejo}`, textos.match(viejo)?.[0])
}
comprueba(!/pr[ée]stamo|financia|cr[ée]dito|\bfee\b/i.test(textos), 'sin vocabulario prohibido')

// El médico no ve montos con la Comisión Helios (CLAUDE.md).
const delMedico = JSON.stringify([GUIAS['/medicos'], CALENDARIO_DE_COBRO])
comprueba(
  ![cien.total, cien.inicial, cien.cuota].some((n) => delMedico.includes(dinero(n))),
  'lo que lee el médico no trae montos con la comisión',
)

console.log(fallos ? `\n${fallos} fallo(s).` : '\nTodo bien.')
if (fallos) process.exit(1)
