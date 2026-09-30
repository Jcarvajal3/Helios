/**
 * Pruebas de las filas de «Semana a semana», sus etiquetas y la búsqueda.
 *
 *   npx tsx src/features/admin/metricas/semana/filas.test.ts
 *
 * Lo que se vigila: que cada fila lea su cifra con la clase de dinero que
 * dice su nombre; que lo que se paga en cuotas vaya SIEMPRE seguido de sus
 * dos sumandos y que cuadren; que el cambio frente a la anterior salga en %
 * o en puntos y con el color de si subir es bueno; que una raya sustituya a
 * un dato que no hay; que cada fila lleve a su pestaña con la misma semana y
 * local; y cómo se nombra una semana.
 */
import { columnasDe, validarSemana } from './busqueda'
import { etiquetaDeSemana, tramoDeDias } from './etiquetas'
import {
  FILAS,
  GRUPOS_DE_FILAS,
  busquedaDeDestino,
  cambioDeFila,
  escribir,
  nombreDelDestino,
  sinMovimiento,
} from './filas'
import { leerRespuestaSemanas } from './lectura'
import { respuestaCruda } from './__fixtures__/respuestaSemanas'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

function fila(id: string) {
  const f = FILAS.find((x) => x.id === id)
  if (!f) throw new Error(`No hay fila ${id}`)
  return f
}

const r = leerRespuestaSemanas(respuestaCruda({ n: 3 }))
const elegida = r.semanas[2].cifras
const anterior = r.comparacion.cifras

console.log('── El catálogo ───────────────────────────────────────────────')
igual(
  GRUPOS_DE_FILAS.map((g) => g.titulo),
  ['Financiamiento', 'Ingreso de Helios', 'Cobro', 'Riesgo', 'Pacientes', 'Caja'],
  'los seis grupos de la maqueta, en su orden',
)
igual(new Set(FILAS.map((f) => f.id)).size, FILAS.length, 'ningún id repetido')
igual(
  FILAS.filter((f) => f.soloSinLocal).map((f) => f.id),
  ['registros', 'en-caja'],
  'no se parten por clínica: los registros y la caja',
)

console.log('── La regla del fee ──────────────────────────────────────────')
// Toda fila que es un importe que se paga en cuotas va seguida de sus dos sumandos.
for (const [total, consumo, servicio] of [
  ['vencian', 'vencian-consumo', 'vencian-servicio'],
  ['vencido', 'vencido-consumo', 'vencido-servicio'],
] as const) {
  const i = FILAS.findIndex((f) => f.id === total)
  igual(
    [FILAS[i + 1]?.id, FILAS[i + 2]?.id, FILAS[i + 1]?.sumando, FILAS[i + 2]?.sumando],
    [consumo, servicio, true, true],
    `«${fila(total).nombre}» va seguida de sus dos sumandos`,
  )
  const suma = (fila(consumo).valor(elegida) ?? 0) + (fila(servicio).valor(elegida) ?? 0)
  igual(
    Math.abs(suma - (fila(total).valor(elegida) ?? 0)) < 0.005,
    true,
    `y financiamiento + service fee = ${fila(total).nombre.toLowerCase()}`,
  )
}
igual(fila('consumo').valor(elegida), 912.4, 'el financiamiento es financed, sin fee')
igual(fila('servicio').valor(elegida), 182.48, 'el service fee va en su fila, sin IVA')
igual(fila('perdido').valor(elegida), 0, 'lo perdido se cuenta en financiamiento')
igual(fila('perdido').unidad, 'sin fee', 'y lo dice')

console.log('── Escribir ──────────────────────────────────────────────────')
igual(escribir(912.4, 'eur'), '$912,40', 'un importe con céntimos')
igual(escribir(1234, 'numero'), '1.234', 'un número con miles')
igual(escribir(81.25, 'pct'), '81,3 %', 'una tasa con un decimal')
igual(escribir(100, 'pct'), '100 %', 'el cien, sin decimales')
igual(escribir(null, 'pct'), '—', 'sin dato, una raya')
igual(escribir(0, 'eur'), '$0,00', 'un cero se escribe')

console.log('── Frente a la anterior ──────────────────────────────────────')
igual(cambioDeFila(fila('consumo'), elegida, anterior)?.corto, '▲ 12 %', 'el financiamiento sube un 12 %')
igual(cambioDeFila(fila('consumo'), elegida, anterior)?.tono, 'bueno', 'y es buena noticia')
igual(cambioDeFila(fila('mora'), elegida, anterior)?.corto, '▲ 2,0 pts', 'la mora cambia en puntos')
igual(cambioDeFila(fila('mora'), elegida, anterior)?.tono, 'malo', 'y subir es malo')
igual(cambioDeFila(fila('a-tiempo'), elegida, anterior)?.tono, 'malo', 'cobrar menos a tiempo es malo')
igual(cambioDeFila(fila('vencian'), elegida, anterior)?.tono, 'neutro', 'lo que vencía no es bueno ni malo')
igual(cambioDeFila(fila('vencian-consumo'), elegida, anterior), null, 'un sumando no lleva cambio propio')
igual(cambioDeFila(fila('perdido'), elegida, anterior), null, 'de cero a cero no hay cambio que contar')

console.log('── Adónde lleva ──────────────────────────────────────────────')
const comun = { semana: '2026-09-14', local: 'b6a4f1d2-0000-4000-8000-000000000001' }
igual(
  busquedaDeDestino(fila('cuota-1').destino, comun),
  { vista: 'cobros', sub: 'impago-por-cuota', semana: '2026-09-14', local: 'b6a4f1d2-0000-4000-8000-000000000001' },
  'la cuota 1 lleva a Cobros › Impago por cuota, con la misma semana y clínica',
)
igual(busquedaDeDestino(fila('consumo').destino, {}), { vista: 'locales' }, 'el financiamiento, a Clínicas')
igual(busquedaDeDestino(fila('en-caja').destino, {}), { vista: 'caja' }, 'la caja, a Caja › Balance (la primera, sin escribirla)')
igual(busquedaDeDestino(fila('mora').destino, {}), { vista: 'mora' }, 'la mora, a Riesgo › Resumen')
igual(busquedaDeDestino(fila('cuota-2').destino, {}), { vista: 'cobros', sub: 'impago-por-cuota' }, 'la cuota 2, a Cobros › Impago por cuota, como la 1')
igual(nombreDelDestino(fila('mora').destino), 'Riesgo › Resumen', 'el nombre del sitio, del registro')
igual(nombreDelDestino(fila('consumo').destino), 'Clínicas', 'una pestaña sin sub-pestañas, solo su nombre')

console.log('── Sin movimiento ────────────────────────────────────────────')
igual(sinMovimiento(r), false, 'con financiamientos hay movimiento')
igual(sinMovimiento(leerRespuestaSemanas(respuestaCruda({ n: 1, ultima: {} }))), true, 'una semana en blanco no')

console.log('── Etiquetas ─────────────────────────────────────────────────')
igual(etiquetaDeSemana('2026-08-03', '2026-08-09'), '3–9 ago', 'dentro de un mes')
igual(etiquetaDeSemana('2026-08-31', '2026-09-06'), '31 ago–6 sep', 'cruzando de mes')
igual(etiquetaDeSemana('2026-12-28', '2027-01-03'), '28 dic–3 ene', 'cruzando de año')
igual(tramoDeDias('2026-09-14', '2026-09-19'), 'del 14 sep al 19 sep', 'un tramo de días')
igual(tramoDeDias('2026-09-14', '2026-09-14'), 'el 14 sep', 'un solo día')

console.log('── La búsqueda ───────────────────────────────────────────────')
igual(validarSemana({ semanas: '12' }), { semanas: '12' }, '12 columnas')
igual(validarSemana({ semanas: '9' }), { semanas: undefined }, 'un número que no se ofrece se ignora')
igual(validarSemana({ semana: '2026-09-14', vista: 'semana' }), { semanas: undefined }, 'las claves del marco no son suyas')
igual(columnasDe({}), 8, 'por defecto, ocho')
igual(columnasDe({ semanas: '26' }), 26, 'o las pedidas')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} ${fallos === 1 ? 'fallo' : 'fallos'}.`)
if (fallos > 0) process.exit(1)
