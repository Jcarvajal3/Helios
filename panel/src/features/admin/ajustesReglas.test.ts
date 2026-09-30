/**
 * Pruebas de las cuentas pequeñas de Ajustes y de cómo se leen los parámetros.
 *
 *   npx tsx src/features/admin/ajustesReglas.test.ts
 */
import {
  enumerar,
  esCuentaDeRelleno,
  formatTasa,
  formatVariacion,
  variacionPct,
} from './ajustesReglas'
import type { Parametro } from './parametros'
import {
  QUE_DECIDE,
  agruparParametros,
  formatValorParametro,
  leerValorParametro,
} from './parametrosPantalla'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

console.log('── La cuenta de relleno ──────────────────────────────────────')
// El fallo que lo motivó: `rif.replace(/D/g, '')` quitaba la letra D y no los
// guiones, así que «J-000000000» nunca se reconocía como relleno.
comprueba(esCuentaDeRelleno('J-000000000'), '«J-000000000» es relleno')
comprueba(esCuentaDeRelleno('000000000'), '«000000000» es relleno')
comprueba(esCuentaDeRelleno('V-00.000.000'), 'con puntos y guiones, también')
comprueba(!esCuentaDeRelleno('J-412345678'), 'un RIF de verdad no lo es')
comprueba(!esCuentaDeRelleno('D-100000000'), 'una D delante no confunde', 'era el fallo de /D/g')
comprueba(!esCuentaDeRelleno(''), 'vacío no es relleno: es que falta')

console.log('\n── La tasa ───────────────────────────────────────────────────')
comprueba(formatTasa(954.0244) === '954,0244 Bs./$', 'cuatro decimales y la unidad', formatTasa(954.0244))
comprueba(formatTasa(950) === '950,00 Bs./$', 'al menos dos decimales', formatTasa(950))
const sube = variacionPct(954, 1003.7)
comprueba(sube !== null && Math.abs(sube - 5.2096) < 0.001, 'la variación en %', String(sube))
comprueba(variacionPct(null, 954) === null, 'sin tasa vigente no hay variación')
comprueba(variacionPct(0, 954) === null, 'contra cero tampoco')
comprueba(formatVariacion(2.345) === '+2,35 %', 'sube con signo', formatVariacion(2.345))
comprueba(formatVariacion(-0.4) === '−0,40 %', 'baja con signo', formatVariacion(-0.4))
comprueba(formatVariacion(0.001) === '0,00 %', 'cero sin signo', formatVariacion(0.001))
comprueba(formatVariacion(null) === '—', 'sin dato, raya')

comprueba(enumerar(['a']) === 'a', 'enumerar uno')
comprueba(enumerar(['a', 'b', 'c']) === 'a, b y c', 'enumerar tres', enumerar(['a', 'b', 'c']))

console.log('\n── Los parámetros ────────────────────────────────────────────')
comprueba(formatValorParametro(null, '$') === 'Sin definir', 'sin valor: «Sin definir», nunca cero')
comprueba(formatValorParametro(2.5, '$') === '$2,50', 'euros', formatValorParametro(2.5, '$'))
comprueba(formatValorParametro(2.125, '%') === '2,125 %', 'porcentaje con sus decimales', formatValorParametro(2.125, '%'))
comprueba(formatValorParametro(1, 'días') === '1 día', 'singular', formatValorParametro(1, 'días'))
comprueba(formatValorParametro(60, 'días') === '60 días', 'plural', formatValorParametro(60, 'días'))
comprueba(formatValorParametro(3, null) === '3', 'sin unidad')

const leido = leerValorParametro('2,5', '$')
comprueba(leido.ok && leido.valor === 2.5, 'lee la coma decimal', JSON.stringify(leido))
comprueba(!leerValorParametro('', '%').ok, 'vacío no vale')
comprueba(!leerValorParametro('doce', '%').ok, 'un texto no vale')
comprueba(!leerValorParametro('-1', '$').ok, 'negativo no vale')
comprueba(!leerValorParametro('101', '%').ok, 'un porcentaje de más de 100 no vale')
comprueba(!leerValorParametro('2,5', 'días').ok, 'días con decimales no valen')
const miles = leerValorParametro('10.000', '$')
comprueba(miles.ok && miles.valor === 10000, '«10.000» es diez mil, no diez', JSON.stringify(miles))

function fila(key: string, grupo: Parametro['grupo']): Parametro {
  return {
    key,
    value: null,
    effectiveFrom: null,
    note: null,
    nextValue: null,
    nextFrom: null,
    history: [],
    label: key,
    unit: null,
    grupo,
  }
}
const grupos = agruparParametros([
  fila('meta_mora_pct', 'meta'),
  fila('late_fee_usd', 'producto'),
  fila('umbral_mora_alerta_pct', 'umbral'),
  fila('rara', null),
])
comprueba(
  grupos.map((g) => g.titulo).join(',') === 'Reglas del crédito,Umbrales de color,Metas,Otros',
  'los grupos en su orden y sin los vacíos',
  grupos.map((g) => g.titulo).join(','),
)

// Las explicaciones no escriben cifras del negocio: cambian sin tocar esto.
const conCifra = Object.entries(QUE_DECIDE).filter(([, t]) =>
  /\b\d+ (d[ií]as|minutos|consumos)\b|€\s?\d|\d\s?%/.test(t ?? ''),
)
comprueba(conCifra.length === 0, 'ninguna explicación escribe cifras', conCifra.map(([k]) => k).join(', '))

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
