/**
 * Prueba del lector de .xls contra un archivo de verdad.
 *
 *   npx tsx src/features/admin/xls.test.ts
 *
 * El del banco no se puede guardar aquí: trae cédulas y teléfonos de gente
 * real. `__fixtures__/estado-de-cuenta-bnc.xls` es un Excel generado con la
 * misma forma —membrete de quince filas, columnas huecas, salto de línea en
 * el título de una columna, Debe y Haber, totales al final— y datos
 * inventados.
 *
 * Tiene 300 movimientos a propósito. Con menos, la tabla de cadenas del .xls
 * cabe en un registro y la prueba no toca el caso que de verdad rompe un
 * lector: una cadena partida entre dos registros CONTINUE. Este archivo trae
 * tres, así que las descripciones del final solo salen bien si el corte está
 * bien resuelto.
 */
import { readFileSync } from 'node:fs'
import { parseStatementFile } from './csv'
import { looksLikePdf, looksLikeXls, looksLikeZip, parseXlsGrid } from './xls'

let failures = 0

function check(ok: boolean, label: string, detail: string) {
  if (!ok) failures++
  console.log(`${ok ? 'OK  ' : 'FALLA'} ${label.padEnd(32)} ${detail}`)
}

const bytes = new Uint8Array(
  readFileSync(new URL('./__fixtures__/estado-de-cuenta-bnc.xls', import.meta.url)),
)

// ── Reconocer el formato ───────────────────────────────────────────────────
check(looksLikeXls(bytes), 'reconoce el .xls', 'por la firma OLE')
check(!looksLikeZip(bytes), 'no lo confunde con .xlsx', 'no empieza por PK')
check(!looksLikePdf(bytes), 'no lo confunde con PDF', 'no empieza por %PDF')

// ── La rejilla ─────────────────────────────────────────────────────────────
const grid = parseXlsGrid(bytes)

check(grid.length === 317, 'filas de la hoja', `${grid.length} (16 + 300 + totales)`)
check(
  grid[15][1] === 'Fecha' && grid[15][15] === 'Haber',
  'cabecera en la fila 16',
  `${grid[15][1]} … ${grid[15][15]}`,
)
check(
  grid[15][2].includes('\n'),
  'salto de línea dentro del título',
  JSON.stringify(grid[15][2]),
)
check(grid[15][4] === '' && grid[15][5] === '', 'conserva las columnas huecas', 'E y F vacías')
check(
  grid[16][12] === '1000000000',
  'referencia sin notación científica',
  grid[16][12],
)
check(grid[16][15] === '0', 'el cargo deja Haber en cero', grid[16][15])
check(grid[17][15] === '1001.5', 'importe con decimales', grid[17][15])
check(grid[316][1] === 'Totales', 'fila de totales al final', grid[316][1])

// ── De archivo a movimientos ───────────────────────────────────────────────
const parsed = parseStatementFile(bytes)

check(parsed.headerRow === 16, 'encuentra la cabecera', `fila ${parsed.headerRow}`)
check(parsed.lines.length === 200, 'abonos', `${parsed.lines.length} (esperaba 200)`)
check(parsed.debits === 100, 'cargos aparte', `${parsed.debits} (esperaba 100)`)
check(parsed.skipped.length === 0, 'nada descartado', `${parsed.skipped.length}`)
check(
  parsed.detectedColumns.amount === 'Haber',
  'coge Haber y no Debe',
  parsed.detectedColumns.amount,
)

const primero = parsed.lines[0]
check(
  primero.moved_on === '2026-09-02' &&
    primero.reference === '1000007919' &&
    primero.amount_ves === 1001.5,
  'primer abono',
  `${primero.moved_on} · ${primero.reference} · ${primero.amount_ves}`,
)

// La última descripción vive más allá del primer corte de la tabla de
// cadenas: si el CONTINUE se leyera mal, saldría en blanco o en chino.
const ultimo = parsed.lines[parsed.lines.length - 1]
check(
  ultimo.description === 'TELF.:5841200000299 BANCO:0134 CED.:V3000000299 PMPC pago numero 299',
  'cadena después del CONTINUE',
  String(ultimo.description),
)
check(
  ultimo.reference === '1002367781' && ultimo.amount_ves === 1299.5,
  'último abono',
  `${ultimo.reference} · ${ultimo.amount_ves}`,
)

// Ningún abono puede venir con importe cero o sin referencia: eso es lo que
// el servidor rechazaría en silencio.
check(
  parsed.lines.every((l) => l.amount_ves > 0 && l.reference !== ''),
  'todos los abonos son válidos',
  `${parsed.lines.length} revisados`,
)

console.log(failures === 0 ? '\n=== TODO OK ===' : `\n=== ${failures} FALLOS ===`)
process.exit(failures === 0 ? 0 : 1)
