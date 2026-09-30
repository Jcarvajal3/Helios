/**
 * Pruebas de las cinco cifras de Semana › Resumen.
 *
 *   npx tsx src/features/admin/metricas/semana/resumen/cifras.test.ts
 *
 * Lo que se vigila: las palabras de Javier en su orden (facturado + fee =
 * total a cobrar, consumos, usuarios), que el total a cobrar lleve SIEMPRE sus
 * dos partes (las tarjetas de al lado y el globo de la chispa), que ningún rótulo llame
 * «servicio» al fee, que lo que es consumo diga si lleva el fee, y que el
 * cambio se mida contra la anterior hasta el mismo momento.
 */
import { formatUsd } from '@/components/ui'
import {
  AYUDAS_DEL_RESUMEN,
  CIFRAS_DEL_DESGLOSE,
  CIFRAS_QUE_CUENTAN,
  TITULOS_DEL_RESUMEN,
  cifrasDelResumen,
  etiquetaConDesglose,
  lineaDeLaComparacion,
  nuevosEnElLocal,
  partesDelFee,
  pieDeConsumos,
  repartoDeLaSemana,
} from './cifras'
import { leerResumen } from './lectura'
import { respuestaCruda } from './__fixtures__/respuestaResumen'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

function cierto(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const r = leerResumen(respuestaCruda())
const cifras = cifrasDelResumen(r)
const de = (id: string) => cifras.find((c) => c.id === id)

console.log('── Las cinco, en su orden ────────────────────────────────────')
igual(
  cifras.map((c) => c.id),
  [...CIFRAS_DEL_DESGLOSE, ...CIFRAS_QUE_CUENTAN],
  'financiado, fee, total, financiamientos, pacientes',
)
igual(
  cifras.map((c) => c.titulo),
  [
    'Total financiado (sin fee)',
    'Service fee + IVA',
    'Total a cobrar',
    'Financiamientos',
    'Pacientes que se financiaron',
  ],
  'con las palabras de Javier',
)
igual(
  cifras.map((c) => c.valor),
  [formatUsd(1129), formatUsd(261.92), formatUsd(1390.92), '43', '61'],
  'los valores, escritos',
)

console.log('── La regla del fee ──────────────────────────────────────────')
igual(de('total')?.pie, undefined, 'el total a cobrar no repite en el pie sus dos sumandos: son las tarjetas de al lado')
cierto(
  (de('total')?.chispa.etiquetas ?? []).every((e) => e.includes('financiamiento $') && e.includes('service fee $')),
  'y en el globo de cada barra de su chispa',
  JSON.stringify(de('total')?.chispa.etiquetas),
)
igual(de('fee')?.pie, partesDelFee({ servicioUsd: 225.8, ivaUsd: 36.12 }), 'el fee, partido en sin IVA + IVA')
igual(partesDelFee({ servicioUsd: 225.8, ivaUsd: 36.12 }), `${formatUsd(225.8)} sin IVA + ${formatUsd(36.12)} de IVA`, 'con sus palabras')
{
  const leido = [
    ...Object.values(TITULOS_DEL_RESUMEN),
    ...Object.values(AYUDAS_DEL_RESUMEN),
    ...cifras.map((c) => c.pie),
    ...cifras.flatMap((c) => c.chispa.etiquetas),
  ].join(' ')
  cierto(!/servicio/i.test(leido), 'nada de lo que se lee dice «servicio»', leido.match(/.{20}servicio.{20}/i)?.[0] ?? '')
  cierto(!/comisi[oó]n/i.test(leido), 'ni «comisión»')
}
cierto(TITULOS_DEL_RESUMEN.facturado.includes('sin fee'), 'el financiado dice que va sin fee')
cierto(
  TITULOS_DEL_RESUMEN.total === 'Total a cobrar' && CIFRAS_DEL_DESGLOSE.at(-1) === 'total',
  'el total a cobrar se llama como dice Javier y va detrás de sus dos sumandos',
)
cierto(AYUDAS_DEL_RESUMEN.facturado.startsWith('Sin el service fee'), 'la ayuda del financiado empieza por «Sin el service fee»')
cierto(pieDeConsumos({ ticketMedioUsd: 26.26 }).includes('(sin fee)'), 'el ticket medio dice que va sin fee')

console.log('── Frente a la anterior ──────────────────────────────────────')
igual(de('facturado')?.delta?.texto, '11 % más', 'financiado: 1.129 frente a 1.015,50')
igual(de('consumos')?.delta?.texto, '4 % menos', 'financiamientos: 43 frente a 45')
igual(de('consumos')?.delta?.tono, 'malo', 'menos financiamientos es mala noticia')
igual(de('usuarios')?.delta?.tono, 'bueno', 'más pacientes es buena noticia')
igual(
  cifrasDelResumen(leerResumen({ ...respuestaCruda(), comparacion: { ...(respuestaCruda().comparacion as object), consumos: 0 } }))
    .find((c) => c.id === 'consumos')?.delta?.direccion,
  'nuevo',
  'sin financiamientos antes, «nuevo» (sin porcentaje)',
)

console.log('── La chispa ─────────────────────────────────────────────────')
igual(de('facturado')?.chispa.valores.length, 8, 'ocho barras')
igual(de('facturado')?.chispa.valores.at(-1), 1129, 'la última es la semana elegida')
igual(de('facturado')?.chispa.etiquetas.at(-1), '21–27 sep', 'nombrada por su semana')
igual(de('usuarios')?.chispa.serie, 'Pacientes que se financiaron', 'el globo dice qué cifra es')
igual(de('facturado')?.chispa.rotulo, 'Total financiado (sin fee), de las últimas 8 semanas', 'el rótulo accesible')
igual(
  etiquetaConDesglose({ ...r.semanas[7], financedUsd: 10, feeUsd: 2.46 }),
  `21–27 sep (financiamiento ${formatUsd(10)} + service fee ${formatUsd(2.46)})`,
  'la etiqueta con desglose',
)

console.log('── Los pies ──────────────────────────────────────────────────')
igual(repartoDeLaSemana(r), '2 días · 2 clínicas', 'en cuántas días y clínicas')
igual(repartoDeLaSemana({ ...r, local: 'x' }), '2 días', 'con una clínica, solo los días')
igual(repartoDeLaSemana({ ...r, noches: [] }), 'Ningún financiamiento todavía', 'sin días')
igual(nuevosEnElLocal(30, false), '30 nuevos en algún clínica', 'nuevos sin clínica')
igual(nuevosEnElLocal(1, true), '1 nuevo en la clínica', 'nuevos con clínica')
igual(nuevosEnElLocal(0, true), 'Ningún paciente nuevo en la clínica', 'ninguno nuevo')
igual(pieDeConsumos({ ticketMedioUsd: null }), 'Sin financiamientos, sin ticket medio', 'sin ticket')

console.log('── Con qué se compara ────────────────────────────────────────')
igual(
  lineaDeLaComparacion(r),
  'Semana en curso: cada cifra se compara con la anterior hasta el mismo momento, del 14 sep al sábado 19 sep a las 15:00.',
  'la semana en curso, hasta el mismo momento (en hora de Caracas)',
)
igual(
  lineaDeLaComparacion({
    ...r,
    anterior: { ...r.anterior, hasta: '2026-09-19', corte: '2026-09-20T07:15:00+00:00' },
  }),
  'Semana en curso: cada cifra se compara con la anterior hasta el mismo momento, del 14 sep al domingo 20 sep a las 03:15.',
  'de madrugada, el corte dice su día del calendario (el día del sábado acaba el domingo)',
)
igual(
  lineaDeLaComparacion({
    semana: { desde: '2026-09-14', hasta: '2026-09-20', enCurso: false },
    dias: 7,
    anterior: { desde: '2026-09-07', hasta: '2026-09-13', dias: 7, mismaAltura: false, corte: null },
  }),
  'Cada cifra se compara con la semana anterior entera, del 7 sep al 13 sep.',
  'una semana cerrada, con la anterior entera',
)
igual(
  lineaDeLaComparacion({ ...r, dias: 1, anterior: { ...r.anterior, hasta: '2026-09-14', corte: null } }),
  'Semana en curso (1 día de 7): cada cifra se compara con los mismos días de la anterior, el 14 sep.',
  'sin corte (una base vieja), los mismos días',
)

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
