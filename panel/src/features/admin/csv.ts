import type { StatementLine } from '@/features/admin/api'
import { looksLikePdf, looksLikeXls, looksLikeZip, parseXlsGrid } from '@/features/admin/xls'

/**
 * Parseo del estado de cuenta.
 *
 * Cada banco venezolano exporta a su manera: cambian los nombres de columna,
 * el separador (coma o punto y coma), el formato de fecha y —lo peor— el
 * significado de la coma y el punto en los importes. Aquí se normaliza todo
 * eso en el cliente, para que el servidor reciba filas limpias y no tenga que
 * saber de bancos.
 *
 * Y lo que exporta un banco no es una tabla: es un informe. El del BNC trae
 * quince filas de membrete —cliente, usuario, número de cuenta, rango de
 * fechas— antes de la cabecera, columnas huecas entre medias porque las
 * celdas van combinadas, saltos de línea dentro del título de una columna y
 * una fila de totales al final. Todo eso se sortea aquí.
 *
 * El formato de archivo se resuelve antes: `.xls`, CSV y TXT acaban los tres
 * en la misma rejilla de texto, y de ahí en adelante el código es el mismo.
 */

// ── De archivo a rejilla ───────────────────────────────────────────────────

/**
 * El separador es el que más aparece en todo el archivo, no solo en la
 * primera línea: en un informe con membrete, la primera línea son quince
 * celdas vacías y no dice nada. Contar sobre el archivo entero también
 * distingue bien el `;` de un archivo con decimales en coma, porque el
 * separador aparece una vez por columna y la coma decimal solo una o dos.
 */
function detectSeparator(text: string): string {
  const sample = text.slice(0, 20000)
  const counts = [';', ',', '\t'].map((sep) => ({
    sep,
    n: sample.split(sep).length - 1,
  }))
  counts.sort((a, b) => b.n - a.n)
  return counts[0].n > 0 ? counts[0].sep : ','
}

/**
 * Texto delimitado a rejilla.
 *
 * Se recorre carácter a carácter en vez de partir por saltos de línea,
 * porque un campo entrecomillado puede llevar un salto dentro. El BNC lo
 * hace en la propia cabecera —"Código\nTransacción"— y partir por líneas
 * antes de mirar las comillas rompe justo la fila que hay que reconocer.
 */
export function gridFromDelimited(text: string, separator?: string): Array<Array<string>> {
  const sep = separator ?? detectSeparator(text)
  const rows: Array<Array<string>> = []
  let row: Array<string> = []
  let cell = ''
  let inQuotes = false

  const endCell = () => {
    row.push(cell.trim())
    cell = ''
  }
  const endRow = () => {
    endCell()
    rows.push(row)
    row = []
  }

  for (let i = 0; i < text.length; i++) {
    const char = text[i]

    if (char === '"') {
      if (inQuotes && text[i + 1] === '"') {
        cell += '"'
        i++
      } else {
        inQuotes = !inQuotes
      }
    } else if (char === sep && !inQuotes) {
      endCell()
    } else if ((char === '\n' || char === '\r') && !inQuotes) {
      if (char === '\r' && text[i + 1] === '\n') i++
      endRow()
    } else {
      cell += char
    }
  }

  if (cell !== '' || row.length > 0) endRow()
  return rows
}

// ── Valores ────────────────────────────────────────────────────────────────

/** Minúsculas, sin tildes y en una sola línea, para que "Descripción",
 *  "DESCRIPCION" y "Código\n Transacción" casen con lo que buscamos. */
function normalize(text: string): string {
  return text
    .toLowerCase()
    .normalize('NFD')
    // Marcas diacríticas combinantes. Escrito con escapes y no con los
    // caracteres literales, que son invisibles en un editor.
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
}

/** Busca la primera columna cuyo nombre contenga alguno de los alias. */
function findColumn(headers: string[], aliases: string[]): number {
  const normalized = headers.map(normalize)

  for (const alias of aliases) {
    const index = normalized.findIndex((h) => h.includes(alias))
    if (index !== -1) return index
  }

  return -1
}

/**
 * Importe venezolano a número.
 *
 * `1.234,56` (formato local) y `1,234.56` (formato inglés) significan lo
 * mismo. Se decide por cuál separador aparece más a la derecha: ese es el
 * decimal. Confundirlos convierte 1.234,56 Bs en 1,23 Bs — un error de tres
 * órdenes de magnitud que además pasaría el cotejo por monto sin avisar.
 *
 * El `+` de `+30.012,11` es el formato contable del banco para marcar el
 * abono, y se va con el resto de lo que no es cifra.
 */
export function parseAmount(raw: string): number {
  const cleaned = raw.replace(/[^\d.,-]/g, '').trim()
  if (!cleaned) return NaN

  const lastComma = cleaned.lastIndexOf(',')
  const lastDot = cleaned.lastIndexOf('.')

  let normalized: string

  if (lastComma === -1 && lastDot === -1) {
    normalized = cleaned
  } else if (lastComma > lastDot) {
    // La coma manda: es el decimal, los puntos son de miles.
    normalized = cleaned.replace(/\./g, '').replace(',', '.')
  } else {
    normalized = cleaned.replace(/,/g, '')
  }

  return Number(normalized)
}

/**
 * Fecha a ISO.
 *
 * Se acepta `DD/MM/AAAA` (lo normal en Venezuela) y `AAAA-MM-DD`. Un
 * `MM/DD/AAAA` sería indistinguible del primero, así que **no se adivina**:
 * se asume día primero, que es la convención local.
 *
 * El número suelto es el serial de Excel: hay bancos que exportan la fecha
 * como número y la hoja solo la enseña con formato. Se acota a un rango
 * plausible —de 2000 en adelante— para no convertir por error un número de
 * cinco cifras que se haya colado en la columna.
 */
export function parseDate(raw: string): string | null {
  const text = raw.trim()

  const iso = /^(\d{4})-(\d{2})-(\d{2})/.exec(text)
  if (iso) return `${iso[1]}-${iso[2]}-${iso[3]}`

  const local = /^(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{2,4})/.exec(text)
  if (local) {
    const day = local[1].padStart(2, '0')
    const month = local[2].padStart(2, '0')
    let year = local[3]
    if (year.length === 2) year = `20${year}`
    return `${year}-${month}-${day}`
  }

  const serial = /^(\d{5})(?:[.,]\d+)?$/.exec(text)
  if (serial) {
    const days = Number(serial[1])
    // 36526 = 2000-01-01, 73050 = 2100-01-01. El día 0 de Excel es el
    // 1899-12-30 por el año bisiesto de 1900 que nunca existió.
    if (days >= 36526 && days < 73050) {
      const date = new Date(Date.UTC(1899, 11, 30) + days * 86400000)
      return date.toISOString().slice(0, 10)
    }
  }

  return null
}

// ── De rejilla a movimientos ───────────────────────────────────────────────

export type ParseResult = {
  lines: StatementLine[]
  /** Cargos: dinero que sale. No son un problema, pero un estado de cuenta
   *  de un mes trae cientos y contarlos aparte es lo que deja ver que el
   *  archivo se leyó entero. */
  debits: number
  /** Filas que no se pudieron leer, con el motivo. Se muestran al operador
   *  en vez de descartarlas en silencio. */
  skipped: Array<{ row: number; reason: string }>
  detectedColumns: { date: string; reference: string; amount: string }
  /** En qué fila del archivo estaba la cabecera. El informe del banco la
   *  esconde detrás del membrete y saberlo ayuda a explicar un fallo. */
  headerRow: number
}

const DATE_ALIASES = ['fecha', 'date']
const REFERENCE_ALIASES = [
  'referencia',
  'reference',
  'nro. operacion',
  'operacion',
  'documento',
  'comprobante',
]
// Primero los nombres que solo puede tener la columna de entradas, y después
// los genéricos. Un estado de cuenta con "Debe" y "Haber" tiene que coger
// "Haber"; uno con una sola columna de importes, la que haya.
const AMOUNT_ALIASES = [
  'credito',
  'abono',
  'haber',
  'deposito',
  'monto',
  'importe',
  'amount',
]
const DESCRIPTION_ALIASES = ['descripcion', 'concepto', 'detalle', 'description']

/** Filas de cierre del informe. No son movimientos y no son un error. */
const FOOTER_LABELS = ['total', 'totales', 'saldo final', 'saldo anterior', 'saldo inicial']

type Columns = { date: number; reference: number; amount: number; description: number }

/** ¿Esta fila es la cabecera de la tabla? Lo es si trae las tres columnas
 *  que hacen falta. Con una sola no basta: "Fecha / Hora:" del membrete
 *  también dice "fecha". */
function readHeader(row: Array<string>): Columns | null {
  const date = findColumn(row, DATE_ALIASES)
  const reference = findColumn(row, REFERENCE_ALIASES)
  const amount = findColumn(row, AMOUNT_ALIASES)

  if (date === -1 || reference === -1 || amount === -1) return null
  return { date, reference, amount, description: findColumn(row, DESCRIPTION_ALIASES) }
}

export function parseStatementGrid(rows: Array<Array<string>>): ParseResult {
  const headerRow = rows.findIndex((row) => readHeader(row) !== null)

  if (headerRow === -1) {
    // Para el mensaje, la fila con más texto: casi siempre es la cabecera
    // que no supimos reconocer, y enseñarla es lo que deja añadir el alias
    // que falta sin tener que pedir el archivo.
    const candidates = rows
      .map((row) => row.filter((c) => c !== ''))
      .sort((a, b) => b.length - a.length)
    const candidate = candidates.length > 0 ? candidates[0] : []

    throw new Error(
      'No encontramos la cabecera con las columnas de fecha, referencia y monto. ' +
        (candidate.length > 0
          ? `La fila con más columnas del archivo trae: ${candidate.join(', ')}.`
          : 'El archivo no parece traer una tabla de movimientos.'),
    )
  }

  let columns = readHeader(rows[headerRow])!
  const headers = rows[headerRow]

  const lines: StatementLine[] = []
  const skipped: Array<{ row: number; reason: string }> = []
  let debits = 0

  for (let i = headerRow + 1; i < rows.length; i++) {
    const cells = rows[i]

    // Fila vacía: el informe las usa para separar bloques.
    if (cells.every((c) => c === '')) continue

    // Un informe con varias cuentas repite la tabla, cabecera incluida, y
    // las columnas pueden no caer en el mismo sitio.
    const again = readHeader(cells)
    if (again) {
      columns = again
      continue
    }

    const dateCell = cells[columns.date] ?? ''
    if (FOOTER_LABELS.includes(normalize(dateCell))) continue

    const movedOn = parseDate(dateCell)
    const reference = (cells[columns.reference] ?? '').replace(/\s/g, '')
    const amountCell = cells[columns.amount] ?? ''
    const amount = parseAmount(amountCell)

    if (!movedOn) {
      skipped.push({ row: i + 1, reason: 'fecha ilegible' })
      continue
    }
    // Los cargos (dinero que sale) van en cero, en negativo o en otra
    // columna. Aquí solo interesan los abonos: los pagos que ENTRAN.
    if (amountCell.trim() === '' || (Number.isFinite(amount) && amount <= 0)) {
      debits++
      continue
    }
    if (!Number.isFinite(amount)) {
      skipped.push({ row: i + 1, reason: `monto ilegible ("${amountCell}")` })
      continue
    }
    if (!reference) {
      skipped.push({ row: i + 1, reason: 'sin referencia' })
      continue
    }

    lines.push({
      moved_on: movedOn,
      reference,
      amount_ves: amount,
      description:
        columns.description === -1 ? undefined : cells[columns.description]?.trim(),
    })
  }

  return {
    lines,
    debits,
    skipped,
    detectedColumns: {
      date: headers[columns.date],
      reference: headers[columns.reference],
      amount: headers[columns.amount],
    },
    headerRow: headerRow + 1,
  }
}

export function parseStatementCsv(text: string): ParseResult {
  const rows = gridFromDelimited(text)

  if (rows.length < 2) {
    throw new Error('El archivo no tiene cabecera y al menos una fila.')
  }

  return parseStatementGrid(rows)
}

/**
 * Una tabla HTML guardada con extensión .xls.
 *
 * Hay bancos que llaman «Excel» a una página web. Se reconoce porque el
 * archivo empieza por una etiqueta y no por la firma de un documento OLE.
 */
function gridFromHtml(text: string): Array<Array<string>> {
  const doc = new DOMParser().parseFromString(text, 'text/html')
  const table = doc.querySelector('table')
  if (!table) throw new Error('El archivo es una página web sin ninguna tabla dentro.')

  return Array.from(table.querySelectorAll('tr')).map((tr) =>
    Array.from(tr.querySelectorAll('td, th')).map((cell) =>
      cell.textContent.replace(/\u00a0/g, ' ').trim(),
    ),
  )
}

/**
 * Punto de entrada único: se le da el archivo y él decide cómo leerlo.
 *
 * Se mira la firma y no la extensión, porque la extensión miente — el mismo
 * banco que exporta un .xls de verdad exporta también un .txt que en realidad
 * es un CSV con punto y coma.
 */
export function parseStatementFile(bytes: Uint8Array): ParseResult {
  if (looksLikePdf(bytes)) {
    throw new Error(
      'Es un PDF. Del PDF no se pueden sacar las columnas con seguridad: ' +
        'descarga el mismo movimiento en Excel (.xls) o en TXT.',
    )
  }

  if (looksLikeZip(bytes)) {
    throw new Error(
      'Es un .xlsx (Excel moderno) y de momento solo leemos el .xls clásico. ' +
        'Ábrelo y usa «Guardar como» → CSV.',
    )
  }

  if (looksLikeXls(bytes)) {
    return parseStatementGrid(parseXlsGrid(bytes))
  }

  // El CSV de un banco venezolano suele venir en Latin-1. Se prueba UTF-8 y,
  // si aparece el carácter de reemplazo, se reintenta — si no, las cabeceras
  // con tilde ("Descripción") no se reconocen.
  let text = new TextDecoder('utf-8').decode(bytes)
  if (text.includes('\ufffd')) {
    text = new TextDecoder('windows-1252').decode(bytes)
  }

  if (/^\s*<(!doctype|html|table|meta)/i.test(text.slice(0, 200))) {
    return parseStatementGrid(gridFromHtml(text))
  }

  return parseStatementCsv(text)
}
