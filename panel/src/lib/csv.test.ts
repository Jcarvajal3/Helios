/**
 * Pruebas del CSV que abre Excel.
 *
 *   npx tsx src/lib/csv.test.ts
 *
 * Lo que se vigila: que un texto que empieza como fórmula (`=`, `+`, `-`,
 * `@`) llegue a la hoja como texto en TODAS las exportaciones, sin que las
 * cifras negativas que escriben `csvDinero` y compañía dejen de ser números.
 */
import { construirCsv, csvDinero, csvEntero, neutralizarFormula } from './csv'
import type { CsvColumn } from './csv'
import { formatoMontoEditable } from './montos'

/** La marca de orden de bytes con que empieza el CSV. */
const BOM = String.fromCharCode(0xfeff)

let fallos = 0
function igual(nombre: string, obtenido: unknown, esperado: unknown) {
  const ok = JSON.stringify(obtenido) === JSON.stringify(esperado)
  if (!ok) {
    fallos++
    console.error(`✗ ${nombre}\n  esperado: ${JSON.stringify(esperado)}\n  obtenido: ${JSON.stringify(obtenido)}`)
  } else {
    console.log(`✓ ${nombre}`)
  }
}

// ── Textos con fórmula ────────────────────────────────────────────────────

igual('un = queda como texto', neutralizarFormula('=1+1'), `'=1+1`)
igual('un + también', neutralizarFormula('+1+1'), `'+1+1`)
igual('un - con algo detrás de la cifra también', neutralizarFormula('-2+3+cmd|"/C calc"!A0'), `'-2+3+cmd|"/C calc"!A0`)
igual('un @ también', neutralizarFormula('@SUM(A1:A9)'), `'@SUM(A1:A9)`)
igual('un tabulador delante también', neutralizarFormula('\t=1+1'), `'\t=1+1`)
igual('un retorno delante también', neutralizarFormula('\r=1+1'), `'\r=1+1`)
igual('un teléfono con + también (si no, notación científica)', neutralizarFormula('+584141234567'), `'+584141234567`)
igual('un guion solo también', neutralizarFormula('-'), `'-`)
igual('un texto normal no se toca', neutralizarFormula('Ana María Pérez'), 'Ana María Pérez')
igual('un = en medio no se toca', neutralizarFormula('Torre A = piso 3'), 'Torre A = piso 3')
igual('un texto vacío no se toca', neutralizarFormula(''), '')

// ── Cifras negativas ──────────────────────────────────────────────────────

igual('un importe negativo sigue siendo número', neutralizarFormula(csvDinero(-5)), '-5,00')
igual('con cuatro decimales también', neutralizarFormula(csvDinero(-1234.5678, 4)), '-1234,5678')
igual('un entero negativo también', neutralizarFormula(csvEntero(-12)), '-12')
igual('el formato de la tabla (DataTable) también', neutralizarFormula(formatoMontoEditable(-5.5)), '-5,5')
igual('una cifra con punto decimal no es de aquí: se neutraliza', neutralizarFormula('-5.00'), `'-5.00`)

// ── En el archivo entero ──────────────────────────────────────────────────

type Fila = { nombre: string; direccion: string | null; saldo: number }
const columnas: Array<CsvColumn<Fila>> = [
  { header: 'Nombre', value: (f) => f.nombre },
  { header: 'Dirección', value: (f) => f.direccion },
  { header: 'Saldo ($)', value: (f) => csvDinero(f.saldo) },
]
const csv = construirCsv(columnas, [
  { nombre: '=HYPERLINK("https://example.com";"ver")', direccion: '@calle 1', saldo: -5 },
  { nombre: 'Ana', direccion: null, saldo: 12.3 },
])
const lineas = csv.replace(new RegExp(`^${BOM}`), '').split('\r\n')

igual('la cabecera no cambia', lineas[0], 'Nombre;Dirección;Saldo ($)')
igual(
  'la fórmula sale con apóstrofo y entrecomillada, el saldo negativo como número',
  lineas[1],
  `"'=HYPERLINK(""https://example.com"";""ver"")";'@calle 1;-5,00`,
)
igual('la fila normal no cambia y lo que falta sale vacío', lineas[2], 'Ana;;12,30')

if (fallos > 0) {
  console.error(`\n${fallos} ${fallos === 1 ? 'prueba falló' : 'pruebas fallaron'}`)
  process.exit(1)
}
console.log('\nTodo bien.')
