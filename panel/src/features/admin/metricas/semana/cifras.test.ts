/**
 * Pruebas de las cinco cifras de arriba y de las metas.
 *
 *   npx tsx src/features/admin/metricas/semana/cifras.test.ts
 *
 * Lo que se vigila: que cada tarjeta diga lo mismo que su fila de la tabla;
 * que la chispa sean las ocho últimas semanas aunque la tabla enseñe más;
 * que la meta del consumo solo salga sin local; que las pastillas salgan de
 * los umbrales y solo al cruzarlos; que lo vencido se enseñe con sus dos
 * partes; y el veredicto de cada meta.
 */
import { cifrasDeLaSemana } from './cifras'
import { leerRespuestaSemanas } from './lectura'
import { metasDeLaSemana, veredictoDeMeta } from './metas'
import { METAS } from '@/components/admin/resumen/medirMetas'
import { textoDeDesglose } from '@/features/admin/metricas/formato'
import { parametrosDePrueba, respuestaCruda } from './__fixtures__/respuestaSemanas'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const parametros = parametrosDePrueba()
const r12 = leerRespuestaSemanas(respuestaCruda({ n: 12 }))
const cifras = cifrasDeLaSemana({ respuesta: r12, local: null, parametros })
const de = (id: string) => cifras.find((c) => c.id === id)

console.log('── Las cinco ─────────────────────────────────────────────────')
igual(
  cifras.map((c) => c.titulo),
  ['Total financiado (sin comisión)', 'Comisión Helios sin IVA', 'Pacientes que se financiaron', 'Cobrado a tiempo', 'Mora'],
  'las cinco de la maqueta, en su orden, con la comisión por su nombre y el financiamiento sin él',
)
igual(
  cifras.map((c) => c.valor),
  ['$912,40', '$182,48', '44', '80,0 %', '9,4 %'],
  'con los valores de la tabla',
)
igual(
  cifras.map((c) => c.tono),
  ['gerencia', 'gerencia', 'gerencia', 'cobranza', 'cobranza'],
  'cada una en el tono de su área, como en la maqueta',
)
igual(de('consumo')?.delta?.texto, '12 % más', 'el financiamiento frente a la anterior a la misma altura')
igual(de('mora')?.delta?.tono, 'malo', 'la mora sube: mala noticia')

console.log('── La chispa ─────────────────────────────────────────────────')
igual(de('consumo')?.chispa.valores.length, 8, 'ocho semanas aunque la tabla tenga doce')
igual(de('consumo')?.chispa.valores.at(-1), 912.4, 'la última es la elegida')
igual(de('consumo')?.chispa.etiquetas.at(-1), '21–27 sep', 'con su nombre')
igual(de('consumo')?.chispa.formato(1234.5), '$1.234,50', 'y sus números escritos como en la tabla')
igual(de('consumo')?.chispa.serie, 'Total financiado (sin comisión)', 'el globo de cada barra dice que el financiamiento va sin comisión')

console.log('── Metas y umbrales ──────────────────────────────────────────')
igual(de('consumo')?.pie, 'Meta semanal $1.000,00 · va al 91 %', 'el financiamiento frente a su meta semanal')
igual(de('a-tiempo')?.senal, { tone: 'warning', texto: 'Bajo · meta 90 %' }, 'el cobro a tiempo por debajo del umbral bueno')
igual(de('a-tiempo')?.pie, 'De 40 cuotas con el plazo cerrado · meta 90 %', 'sobre cuántas cuotas y su meta')
igual(de('mora')?.senal, { tone: 'warning', texto: 'Alerta · desde 7 %' }, 'la mora cruza la alerta')
igual(
  de('mora')?.pie,
  `${textoDeDesglose({ financedUsd: 146.72, feeUsd: 34.04 })} vencidos`,
  'lo vencido con sus dos partes, nunca sumado',
)
igual(de('personas')?.pie, '18 nuevos en Helios', 'quién se financió por primera vez')
igual(de('servicio')?.senal, undefined, 'sin umbral no hay pastilla')

const conLocal = cifrasDeLaSemana({ respuesta: r12, local: 'b6a4f1d2-0000-4000-8000-000000000001', parametros })
igual(conLocal[0]?.pie, '30 financiamientos', 'con una clínica, sin la meta de todo Helios')
igual(conLocal[3]?.pie, 'De 40 cuotas con el plazo cerrado', 'ni la del cobro a tiempo')
igual(conLocal[4]?.senal?.tone, 'warning', 'los umbrales de la mora valen también para una clínica')

const sinParametros = cifrasDeLaSemana({ respuesta: r12, local: null, parametros: undefined })
igual(sinParametros[4]?.senal, undefined, 'sin parámetros, ni pastillas inventadas')
igual(sinParametros[0]?.pie, '30 financiamientos', 'ni metas')

const r1 = leerRespuestaSemanas(respuestaCruda({ n: 1, ultima: {} }))
const vacias = cifrasDeLaSemana({ respuesta: r1, local: null, parametros })
igual(
  vacias.map((c) => c.valor),
  ['$0,00', '$0,00', '0', '—', '—'],
  'una semana en blanco: ceros de verdad y rayas donde no hay tasa',
)
igual(vacias[3]?.pie, 'Ninguna cuota con el plazo cerrado todavía', 'por qué no hay cobro a tiempo')
igual(vacias[4]?.pie, 'Nada por cobrar al cierre', 'por qué no hay mora')

console.log('── Las metas ─────────────────────────────────────────────────')
const elegida = r12.semanas.at(-1)!
const metas = metasDeLaSemana(elegida.cifras, true, parametros)
igual(
  metas.map((m) => m.clave),
  ['financiado', 'mora', 'cobroATiempo', 'personas', 'locales'],
  'las cinco metas del Resumen',
)
igual(metas[0]?.rotulo, 'Total financiado (sin comisión)', 'con el nombre de la fila que mide, y sin la comisión')
igual(metas[1]?.rotulo.includes('fee'), false, 'la aclaración solo va en la meta del financiamiento')
igual(metas[0]?.valor, 912.4, 'la meta de financiamiento mide la fila de financiamiento')
igual(metas[0]?.veredicto, { tono: 'neutral', texto: 'Faltan $87,60' }, 'en curso, lo que falta no es un aviso')
igual(metas[1]?.veredicto, { tono: 'warning', texto: '1,4 % por encima' }, 'la mora por encima de su meta')
igual(metas[3]?.veredicto, { tono: 'neutral', texto: 'Faltan 6 pacientes' }, 'los pacientes')
igual(metas[4]?.veredicto, { tono: 'neutral', texto: 'Sin meta' }, 'una meta sin valor')
igual(
  veredictoDeMeta(METAS.financiado, 1000, { pct: 91, cumplida: false, distancia: 87.6 }, false),
  { tono: 'warning', texto: 'Faltan $87,60' },
  'cerrada la semana, lo que falta sí es un aviso',
)
igual(
  veredictoDeMeta(METAS.mora, 8, { pct: 50, cumplida: true, distancia: 0 }, true),
  { tono: 'success', texto: 'Por debajo de la meta' },
  'una mora bajo su meta',
)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} ${fallos === 1 ? 'fallo' : 'fallos'}.`)
if (fallos > 0) process.exit(1)
