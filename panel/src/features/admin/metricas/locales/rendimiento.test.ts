/**
 * Pruebas de las cuentas de pintar de los locales en la semana.
 *
 *   npx tsx src/features/admin/metricas/locales/rendimiento.test.ts
 *
 * Vienen de las de Directorio › Locales › Rendimiento. Lo que se vigila: que
 * ninguna cuenta divida entre cero, que «de nada a algo» no sea un porcentaje,
 * que un empate arriba no corone a nadie y que la comparación diga contra qué
 * se compara.
 */
import { RESPUESTA_SEMANA } from './__fixtures__/semana'
import { leerFilaLocal, leerLocalesDeLaSemana } from './lectura'
import {
  conVentas,
  elQueMasConsumio,
  elQueMasCrecio,
  frenteALaAnterior,
  pctEnGrupo,
  recurrentes,
  referenciaDeLaAnterior,
  ticketAnterior,
  variacion,
} from './rendimiento'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const d = leerLocalesDeLaSemana(RESPUESTA_SEMANA)
const [lq, em, nl, sv] = d.locales

console.log('── Quién vendió ──────────────────────────────────────────────')
igual(conVentas(d.locales).map((l) => l.merchantId), ['lq', 'em', 'nl'], 'los que vendieron, sin el que no')
igual(elQueMasConsumio(d.locales)?.merchantId, 'lq', 'el que más se financió')
const empate = [leerFilaLocal({ merchant_id: 'a', nombre: 'A', consumo_usd: 10 }), leerFilaLocal({ merchant_id: 'b', nombre: 'B', consumo_usd: 10 })]
igual(elQueMasConsumio(empate), null, 'con un empate arriba no se corona a nadie')
igual(elQueMasConsumio([]), null, 'sin clínicas, nadie')

console.log('── Frente a la anterior ──────────────────────────────────────')
igual(frenteALaAnterior(em)?.corto, '▲ 20 %', 'El Marchante sube un 20 %')
igual(frenteALaAnterior(nl)?.direccion, 'nuevo', 'de nada a algo es «nuevo», no un porcentaje')
igual(frenteALaAnterior(sv), null, 'sin financiamientos ni antes ni ahora, no hay flecha')
igual(variacion(10, 0), null, 'la variación desde cero es nula')
igual(Math.round(variacion(364, 303) ?? 0), 20, 'la variación en porcentaje')
igual(elQueMasCrecio(d.locales)?.local.merchantId, 'em', 'el que más crece, entre los que ya vendían')
igual(ticketAnterior(sv), null, 'sin financiamientos antes no hay ticket anterior')
igual(ticketAnterior(lq), 32, 'el ticket de la anterior')
igual(referenciaDeLaAnterior(d), 'la semana pasada a la misma altura', 'en curso, a la misma altura')
igual(
  referenciaDeLaAnterior({ anterior: { desde: '', hasta: '', mismaAltura: false } }),
  'la semana anterior',
  'cerrada, la anterior entera',
)

console.log('── Su gente ──────────────────────────────────────────────────')
igual(recurrentes(lq), 18, 'las que ya habían venido')
igual(recurrentes(leerFilaLocal({ personas: 2, nuevas: 5 })), 0, 'nunca negativo')
igual(Math.round(pctEnGrupo(lq) ?? 0), 35, 'la parte en grupo')
igual(pctEnGrupo(sv), null, 'sin financiamientos, no hay parte en grupo')

if (fallos > 0) {
  console.error(`\n${fallos} prueba(s) fallaron`)
  process.exit(1)
}
console.log('\nTodo bien.')
