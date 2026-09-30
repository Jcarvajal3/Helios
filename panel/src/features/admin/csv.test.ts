/**
 * Pruebas del parseo del estado de cuenta.
 *
 *   npx tsx src/features/admin/csv.test.ts
 *
 * Sin framework a propósito: es un módulo puro, sin red ni base de datos, y
 * el proyecto todavía no tiene runner de tests. Cuando lo tenga, esto se
 * convierte en un `describe` sin tocar los casos.
 *
 * El caso que más importa es el de los importes: confundir `1.234,56` con
 * `1,234.56` convierte 1.234,56 Bs en 1,23 Bs. Y como el cotejo compara por
 * monto, un error así no rebota — simplemente deja de encontrar el pago, o
 * peor, encuentra otro.
 *
 * El segundo es la forma del archivo. Lo que da el banco no es una tabla: es
 * un informe con membrete, columnas huecas y una fila de totales. Los casos
 * de abajo reproducen el del BNC tal cual, porque es el que se sube cada día.
 */
import {
  parseAmount,
  parseDate,
  parseStatementCsv,
  parseStatementGrid,
} from './csv'

let failures = 0

function check(ok: boolean, label: string, detail: string) {
  if (!ok) failures++
  console.log(`${ok ? 'OK  ' : 'FALLA'} ${label.padEnd(30)} ${detail}`)
}

// ── Importes ───────────────────────────────────────────────────────────────
const amounts: Array<[string, number, string]> = [
  ['1.234,56', 1234.56, 'formato venezolano'],
  ['1,234.56', 1234.56, 'formato inglés'],
  ['1234,56', 1234.56, 'solo coma decimal'],
  ['1234.56', 1234.56, 'solo punto decimal'],
  ['1.234.567,89', 1234567.89, 'millones con puntos'],
  ['960,00', 960, 'el importe de una cuota real'],
  ['Bs. 1.500,00', 1500, 'con símbolo de moneda'],
  ['1234', 1234, 'entero sin decimales'],
  ['+30.012,11', 30012.11, 'el abono del BNC en PDF'],
  ['30012.11', 30012.11, 'el abono del BNC en .xls'],
]

for (const [input, expected, label] of amounts) {
  const got = parseAmount(input)
  check(Math.abs(got - expected) < 0.001, label, `"${input}" → ${got}`)
}

// ── Fechas ─────────────────────────────────────────────────────────────────
const dates: Array<[string, string]> = [
  ['22/08/2026', '2026-08-22'],
  ['2026-08-22', '2026-08-22'],
  ['5/3/26', '2026-03-05'],
  ['22-08-2026', '2026-08-22'],
  ['20/09/2026', '2026-09-20'],
  // Serial de Excel: hay bancos que exportan la fecha como número.
  ['46285', '2026-09-20'],
]

for (const [input, expected] of dates) {
  const got = parseDate(input)
  check(got === expected, 'fecha', `"${input}" → ${got}`)
}

check(parseDate('1097006484') === null, 'referencia no es fecha', 'no la convierte')

// ── CSV completo ───────────────────────────────────────────────────────────
const csv = [
  'Fecha;Referencia;Descripción;Crédito',
  '22/08/2026;000123447781;PAGO MOVIL RECIBIDO;"1.200,00"',
  '22/08/2026;000999888777;COMPRA;"0,00"',
  'sin-fecha;111;X;"50,00"',
  '23/08/2026;000123999999;OTRO PAGO;"350,50"',
].join('\n')

const result = parseStatementCsv(csv)

check(result.lines.length === 2, 'filas válidas', `${result.lines.length} (esperaba 2)`)
check(result.skipped.length === 1, 'filas descartadas', `${result.skipped.length} (esperaba 1)`)
check(result.debits === 1, 'cargos aparte', `${result.debits} (esperaba 1)`)
check(
  result.detectedColumns.amount === 'Crédito',
  'detecta columna con tilde',
  result.detectedColumns.amount,
)
check(
  result.lines[0]?.amount_ves === 1200,
  'importe entrecomillado',
  String(result.lines[0]?.amount_ves),
)

// Un campo entrecomillado puede llevar un salto de línea dentro, y partir el
// archivo por líneas antes de mirar las comillas rompe la fila entera.
const conSalto = [
  'Fecha;Referencia;"Monto',
  'en Bs"',
  '22/08/2026;000111222333;"1.000,00"',
].join('\n')
const saltos = parseStatementCsv(conSalto)
check(
  saltos.lines.length === 1 && saltos.lines[0].amount_ves === 1000,
  'salto dentro de comillas',
  `${saltos.lines.length} fila(s)`,
)

// ── El informe del BNC ─────────────────────────────────────────────────────
// La cabecera en la fila 16, columnas huecas por las celdas combinadas, salto
// de línea dentro del título, "Debe" antes que "Haber" y totales al final.
const bnc: Array<Array<string>> = [
  [],
  ['', '', '', '', '', '', '', '', '', 'Fecha / Hora:', '', '21/9/2026 1:30:23'],
  [],
  ['', '', '', '', '', '', '', '', '', 'Paciente:', '', 'QUARTO LATAM ,C.A'],
  ['', '', '', '', '', 'MOVIMIENTOS ENTRE FECHAS DEL 20/9/2026 AL 20/9/2026'],
  [],
  ['', 'Nro. Cuenta', '', '', '', '', '', '', 'Titular'],
  ['', 'CUENTA CORRIENTE ***7215', '', '', '', '', '', '', 'QUARTO LATAM ,C.A'],
  [],
  [
    '',
    'Fecha',
    'Código\n Transacción',
    'Tipo \nTransacción',
    '',
    '',
    'Tipo \nOperación',
    'Descripción',
    '',
    '',
    '',
    '',
    'Referencia',
    'Debe',
    '',
    'Haber',
    'Saldo',
  ],
  [
    '',
    '20/09/2026',
    '388',
    'P2COTR',
    '',
    '',
    'Abono Pago Movil BNC',
    'TELF.:584240000000 BANCO:0102 CED.:V30000000 PMPC pago',
    '',
    '',
    '',
    '',
    '1097006484',
    '0',
    '',
    '30012.11',
    '64202.69',
  ],
  [
    '',
    '20/09/2026',
    '388',
    'P2COTR',
    '',
    '',
    'Abono Pago Movil BNC',
    'TELF.:584120000000 BANCO:0134 CED.:V31000000 PMPC pago',
    '',
    '',
    '',
    '',
    '62635900861',
    '0',
    '',
    '15006.05',
    '78758.56',
  ],
  // Un cargo: el dinero que sale va en Debe y Haber queda en cero.
  [
    '',
    '20/09/2026',
    '112',
    'TRFSAL',
    '',
    '',
    'Transferencia enviada',
    'PAGO A PROVEEDOR',
    '',
    '',
    '',
    '',
    '9988776655',
    '5000.00',
    '',
    '0',
    '73758.56',
  ],
  ['', 'Totales', '', '', '', '', '', '', '', '', '', '', '', '0', '', '45018.16', ''],
]

const informe = parseStatementGrid(bnc)

check(informe.headerRow === 10, 'cabecera tras el membrete', `fila ${informe.headerRow}`)
check(informe.lines.length === 2, 'abonos del informe', `${informe.lines.length} (esperaba 2)`)
check(informe.debits === 1, 'el cargo no es un error', `${informe.debits} cargo(s)`)
check(informe.skipped.length === 0, 'totales no es un fallo', `${informe.skipped.length} descartadas`)
check(
  informe.detectedColumns.amount === 'Haber',
  'coge Haber y no Debe',
  informe.detectedColumns.amount,
)
check(
  informe.detectedColumns.reference === 'Referencia',
  'coge Referencia y no Tipo Operación',
  informe.detectedColumns.reference,
)
check(
  informe.lines[0]?.moved_on === '2026-09-20' && informe.lines[0]?.amount_ves === 30012.11,
  'primer abono del BNC',
  `${informe.lines[0]?.moved_on} · ${informe.lines[0]?.amount_ves}`,
)
check(
  informe.lines[0]?.reference === '1097006484',
  'referencia completa',
  String(informe.lines[0]?.reference),
)
check(
  (informe.lines[0]?.description ?? '').includes('CED.:V30000000'),
  'guarda la descripción entera',
  String(informe.lines[0]?.description),
)

// Un informe de dos cuentas repite la tabla con su cabecera.
const dosCuentas = [
  ...bnc,
  [],
  ['', 'Nro. Cuenta', '', 'CUENTA CORRIENTE ***9001'],
  ['', 'Fecha', '', '', 'Referencia', 'Debe', 'Haber'],
  ['', '21/09/2026', '', '', '5544332211', '0', '2500.00'],
]
const segunda = parseStatementGrid(dosCuentas)
check(
  segunda.lines.length === 3 && segunda.lines[2]?.amount_ves === 2500,
  'segunda cuenta del informe',
  `${segunda.lines.length} abonos`,
)

// Un archivo sin las columnas necesarias tiene que decir qué falta, no
// devolver cero filas en silencio.
try {
  parseStatementCsv('Columna A;Columna B\n1;2')
  check(false, 'archivo sin columnas', 'no lanzó error')
} catch (error) {
  check(
    error instanceof Error && error.message.includes('referencia'),
    'archivo sin columnas',
    'explica qué falta',
  )
}

console.log(failures === 0 ? '\n=== TODO OK ===' : `\n=== ${failures} FALLOS ===`)
process.exit(failures === 0 ? 0 : 1)
