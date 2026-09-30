/**
 * Pruebas del CSV de «Semana a semana».
 *
 *   npx tsx src/features/admin/metricas/semana/csv.test.ts
 *
 * Lo que se vigila: una columna por semana más la anterior y el cambio; los
 * sumandos de lo que se paga en cuotas también en el CSV; coma decimal y sin
 * miles; y celdas vacías —no ceros— en lo que no se parte por local.
 */
import { csvDeSemanas, nombreDelCsv } from './csv'
import { FILAS } from './filas'
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

/** Las líneas del CSV, sin la marca de orden de bytes y partidas en celdas. */
function celdas(texto: string): string[][] {
  return texto
    .replace(new RegExp(`^${String.fromCharCode(0xfeff)}`), '')
    .split('\r\n')
    .filter((l) => l !== '')
    .map((l) => l.split(';'))
}

const r = leerRespuestaSemanas(respuestaCruda({ n: 3 }))
const tabla = celdas(csvDeSemanas(r, null))
const linea = (cifra: string) => tabla.find((l) => l[1] === cifra)

console.log('── Cabecera ──────────────────────────────────────────────────')
igual(
  tabla[0],
  [
    'Grupo',
    'Cifra',
    'Unidad',
    '2026-09-07 a 2026-09-13',
    '2026-09-14 a 2026-09-20',
    '2026-09-21 a 2026-09-27 (en curso, hasta 2026-09-26)',
    'Anterior a la misma altura (2026-09-14 a 2026-09-19)',
    'Frente a la anterior',
  ],
  'una columna por semana, la anterior y el cambio',
)

console.log('── Filas ─────────────────────────────────────────────────────')
igual(linea('Total financiado'), ['Financiamiento', 'Total financiado', '$ sin fee', '100,00', '200,00', '912,40', '815,00', '12 % más'], 'el financiamiento, con coma decimal')
igual(linea('Cuotas que vencían')?.slice(5, 7), ['1062,97', '862,40'], 'lo que vencía, sin separador de miles')
igual(linea('  de ello, financiado (sin fee)')?.[0], 'Cobro', 'y sus sumandos, también en el CSV')
igual(linea('  de ello, service fee + IVA')?.slice(5, 8), ['200,17', '162,40', ''], 'el sumando sin cambio propio')
igual(linea('Mora')?.slice(2, 8), ['%', '5,10', '5,20', '9,39', '7,41', '2,0 puntos más'], 'una tasa en puntos')
igual(tabla.length, 1 + FILAS.length, 'una línea por fila de la tabla')

console.log('── Con una clínica ──────────────────────────────────────────────')
const conLocal = celdas(
  csvDeSemanas(
    leerRespuestaSemanas(
      respuestaCruda({ n: 2, local: 'b6a4f1d2-0000-4000-8000-000000000001', ultima: { registros: null, verificados: null, solicitaron: null, caja: null } }),
    ),
    'b6a4f1d2-0000-4000-8000-000000000001',
  ),
)
igual(
  conLocal.find((l) => l[1] === 'Registros'),
  ['Gente', 'Registros', 'no se parte por clínica', '', '', '', ''],
  'lo que no se parte por clínica va vacío, no en cero',
)
igual(
  conLocal.find((l) => l[1] === 'Solicitaron el código'),
  ['Gente', 'Solicitaron el código', 'no se parte por clínica', '', '', '', ''],
  'quien pidió el código tampoco se parte por clínica',
)

console.log('── Nombre ────────────────────────────────────────────────────')
igual(nombreDelCsv(r), 'semanas-2026-09-07-a-2026-09-27', 'de la primera a la última semana')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} ${fallos === 1 ? 'fallo' : 'fallos'}.`)
if (fallos > 0) process.exit(1)
