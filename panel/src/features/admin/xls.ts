/**
 * Lector mínimo de .xls (BIFF8).
 *
 * El BNC —y casi todos los bancos venezolanos— exportan el estado de cuenta
 * en el .xls de toda la vida: un documento compuesto OLE con dentro un flujo
 * de registros BIFF8. No es XML ni un CSV disfrazado, así que no hay forma de
 * leerlo con `TextDecoder` y una expresión regular.
 *
 * Se implementa aquí en vez de traer SheetJS por dos razones: el panel no
 * tiene ninguna dependencia de este tamaño y la versión de `xlsx` que hay en
 * npm lleva sin publicarse desde 2022 con CVEs abiertos. Lo que necesitamos
 * es una porción pequeña del formato —texto, números y dónde caen— y eso
 * cabe en un archivo.
 *
 * Lo que NO hace, a propósito:
 *   * fórmulas (el estado de cuenta no trae ninguna),
 *   * formatos de número (el valor crudo es justo lo que queremos: sin
 *     separador de miles y sin el `+` del formato contable),
 *   * archivos protegidos con contraseña,
 *   * .xlsx, que es un ZIP con XML y no tiene nada que ver.
 *
 * Devuelve la hoja como una rejilla de texto. Interpretar qué columna es cuál
 * es trabajo de `csv.ts`, que hace lo mismo para CSV y para TXT.
 */

/** D0 CF 11 E0 A1 B1 1A E1 — la firma del documento compuesto. */
const OLE_SIGNATURE = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]

const ENDOFCHAIN = 0xfffffffe
const FREESECT = 0xffffffff

export function looksLikeXls(bytes: Uint8Array): boolean {
  return bytes.length > 512 && OLE_SIGNATURE.every((b, i) => bytes[i] === b)
}

/** El .xlsx y el .ods son ZIP: empiezan por "PK". */
export function looksLikeZip(bytes: Uint8Array): boolean {
  return bytes[0] === 0x50 && bytes[1] === 0x4b
}

export function looksLikePdf(bytes: Uint8Array): boolean {
  return bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46
}

// ── El envoltorio: documento compuesto OLE ──────────────────────────────────

type Compound = {
  read: (entryName: string) => Uint8Array | null
}

function openCompound(bytes: Uint8Array): Compound {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const sectorSize = 1 << view.getUint16(30, true)
  const miniSectorSize = 1 << view.getUint16(32, true)
  const fatSectorCount = view.getUint32(44, true)
  const dirStart = view.getUint32(48, true)
  const miniCutoff = view.getUint32(56, true)
  const miniFatStart = view.getUint32(60, true)
  const difatStart = view.getUint32(68, true)

  const at = (sector: number) => (sector + 1) * sectorSize

  // La FAT vive repartida en sectores. Los 109 primeros se listan en la
  // cabecera; si hay más, siguen encadenados desde el DIFAT.
  const fatSectors: number[] = []
  for (let i = 0; i < 109; i++) {
    const sector = view.getUint32(76 + i * 4, true)
    if (sector === FREESECT || sector === ENDOFCHAIN) break
    fatSectors.push(sector)
  }
  let nextDifat = difatStart
  while (
    nextDifat !== ENDOFCHAIN &&
    nextDifat !== FREESECT &&
    fatSectors.length < fatSectorCount
  ) {
    const base = at(nextDifat)
    for (let i = 0; i < sectorSize / 4 - 1; i++) {
      const sector = view.getUint32(base + i * 4, true)
      if (sector !== FREESECT && sector !== ENDOFCHAIN) fatSectors.push(sector)
    }
    nextDifat = view.getUint32(base + sectorSize - 4, true)
  }

  const fat: number[] = []
  for (const sector of fatSectors) {
    const base = at(sector)
    for (let i = 0; i < sectorSize / 4; i++) fat.push(view.getUint32(base + i * 4, true))
  }

  /** Recorre la cadena de sectores de un flujo. El tope evita colgarse con
   *  una FAT corrupta que se apunte a sí misma. */
  function chain(start: number, table: number[]): number[] {
    const out: number[] = []
    let sector = start
    while (sector !== ENDOFCHAIN && sector !== FREESECT && out.length <= table.length) {
      out.push(sector)
      sector = table[sector]
    }
    return out
  }

  function readSectors(start: number, size: number): Uint8Array {
    const out = new Uint8Array(chain(start, fat).length * sectorSize)
    let written = 0
    for (const sector of chain(start, fat)) {
      out.set(bytes.subarray(at(sector), at(sector) + sectorSize), written)
      written += sectorSize
    }
    return out.subarray(0, size)
  }

  // El directorio dice qué flujos hay y dónde empiezan.
  const dirBytes = readSectors(dirStart, chain(dirStart, fat).length * sectorSize)
  const dirView = new DataView(dirBytes.buffer, dirBytes.byteOffset, dirBytes.byteLength)
  const entries: Array<{ name: string; start: number; size: number }> = []
  for (let i = 0; (i + 1) * 128 <= dirBytes.length; i++) {
    const base = i * 128
    const nameLength = dirView.getUint16(base + 64, true)
    if (nameLength < 2) continue
    // El nombre es UTF-16 e incluye el terminador en la longitud.
    let name = ''
    for (let c = 0; c < nameLength / 2 - 1; c++) {
      name += String.fromCharCode(dirView.getUint16(base + c * 2, true))
    }
    entries.push({
      name,
      start: dirView.getUint32(base + 116, true),
      size: dirView.getUint32(base + 120, true),
    })
  }

  // Los flujos pequeños no ocupan un sector entero: van dentro del "mini
  // stream", que cuelga de la raíz y se recorre con su propia tabla.
  let miniStream: Uint8Array | null = null
  let miniFat: number[] | null = null
  function readMini(start: number, size: number): Uint8Array {
    if (miniStream === null) {
      const root = entries[0]
      miniStream = readSectors(root.start, root.size)
      const fatBytes = readSectors(
        miniFatStart,
        chain(miniFatStart, fat).length * sectorSize,
      )
      const fatView = new DataView(
        fatBytes.buffer,
        fatBytes.byteOffset,
        fatBytes.byteLength,
      )
      miniFat = []
      for (let i = 0; i < fatBytes.length / 4; i++) {
        miniFat.push(fatView.getUint32(i * 4, true))
      }
    }
    const out = new Uint8Array(size)
    let written = 0
    for (const sector of chain(start, miniFat!)) {
      const from = sector * miniSectorSize
      const slice = miniStream.subarray(from, from + miniSectorSize)
      out.set(slice.subarray(0, Math.min(slice.length, size - written)), written)
      written += miniSectorSize
      if (written >= size) break
    }
    return out
  }

  return {
    read(entryName) {
      const entry = entries.find((e) => e.name === entryName)
      if (!entry) return null
      return entry.size < miniCutoff
        ? readMini(entry.start, entry.size)
        : readSectors(entry.start, entry.size)
    },
  }
}

// ── El contenido: registros BIFF8 ───────────────────────────────────────────

const RECORD = {
  BOF: 0x0809,
  EOF: 0x000a,
  BOUNDSHEET: 0x0085,
  SST: 0x00fc,
  CONTINUE: 0x003c,
  LABELSST: 0x00fd,
  LABEL: 0x0204,
  RSTRING: 0x00d6,
  RK: 0x027e,
  MULRK: 0x00bd,
  NUMBER: 0x0203,
  FORMULA: 0x0006,
  STRING: 0x0207,
} as const

type Record = { id: number; start: number; length: number }

function readRecord(view: DataView, position: number): Record | null {
  if (position + 4 > view.byteLength) return null
  const id = view.getUint16(position, true)
  const length = view.getUint16(position + 2, true)
  if (position + 4 + length > view.byteLength) return null
  return { id, start: position + 4, length }
}

/**
 * Un RK es un double comprimido en 4 bytes: los dos bits bajos dicen cómo.
 * El bit 1 marca "es entero", el bit 0 marca "divídelo entre 100".
 */
function decodeRk(view: DataView, offset: number): number {
  const raw = view.getInt32(offset, true)
  let value: number
  if (raw & 0x02) {
    value = raw >> 2
  } else {
    const bytes = new Uint8Array(8)
    const doubleView = new DataView(bytes.buffer)
    doubleView.setInt32(4, raw & ~0x03, true)
    value = doubleView.getFloat64(0, true)
  }
  return raw & 0x01 ? value / 100 : value
}

/**
 * Texto de la tabla de cadenas (SST).
 *
 * Es la parte delicada del formato. La SST no cabe en un registro —el tope
 * son 8224 bytes— así que se parte en registros CONTINUE, y una cadena puede
 * quedar cortada por la mitad. Al reanudar, el primer byte del bloque vuelve
 * a decir si lo que queda es de un byte o de dos por carácter: ignorarlo
 * convierte un estado de cuenta grande en basura a partir de cierta fila.
 */
function readSharedStrings(blocks: Array<Uint8Array>): Array<string> {
  const total = blocks.reduce((n, b) => n + b.length, 0)
  const joined = new Uint8Array(total)
  const boundaries = new Set<number>()
  let written = 0
  for (const block of blocks) {
    if (written > 0) boundaries.add(written)
    joined.set(block, written)
    written += block.length
  }

  const view = new DataView(joined.buffer, joined.byteOffset, joined.byteLength)
  let position = 8 // cstTotal (4) + cstUnique (4)
  const count = view.getUint32(4, true)
  const strings: Array<string> = []

  for (let i = 0; i < count && position + 3 <= joined.length; i++) {
    const characters = view.getUint16(position, true)
    let flags = view.getUint8(position + 2)
    position += 3

    const rich = (flags & 0x08) !== 0
    const extended = (flags & 0x04) !== 0
    const runs = rich ? view.getUint16((position += 2) - 2, true) : 0
    const extendedSize = extended ? view.getUint32((position += 4) - 4, true) : 0

    let text = ''
    for (let c = 0; c < characters; c++) {
      if (boundaries.has(position)) {
        flags = view.getUint8(position)
        position += 1
      }
      if (flags & 0x01) {
        text += String.fromCharCode(view.getUint16(position, true))
        position += 2
      } else {
        text += String.fromCharCode(view.getUint8(position))
        position += 1
      }
    }
    position += runs * 4 + extendedSize
    strings.push(text)
  }

  return strings
}

/** Cadena corta con longitud de 16 bits, como la usan LABEL y BOUNDSHEET. */
function readInlineString(view: DataView, offset: number, characters: number): string {
  const flags = view.getUint8(offset)
  let text = ''
  for (let c = 0; c < characters; c++) {
    if (flags & 0x01) {
      text += String.fromCharCode(view.getUint16(offset + 1 + c * 2, true))
    } else {
      text += String.fromCharCode(view.getUint8(offset + 1 + c))
    }
  }
  return text
}

/**
 * Un número a texto tal como lo escribiría el banco en un CSV.
 *
 * Sin separador de miles y sin notación científica: la referencia
 * `62635900861` tiene que salir entera y no como `6.26359e+10`. El redondeo
 * a seis decimales quita la basura del binario (15006.050000000001) sin
 * tocar ningún importe real.
 */
function numberToText(value: number): string {
  if (!Number.isFinite(value)) return ''
  const rounded = Math.round(value * 1e6) / 1e6
  return Number.isInteger(rounded) ? String(rounded) : rounded.toFixed(6).replace(/0+$/, '')
}

/**
 * Devuelve la primera hoja del libro como una rejilla de texto.
 *
 * Las celdas vacías quedan como cadena vacía, y las filas se rellenan hasta
 * la columna más a la derecha que tenga algo: el exportador del BNC deja
 * columnas huecas entre medias por las celdas combinadas, y la rejilla tiene
 * que conservar esa posición para que la cabecera cuadre con sus datos.
 */
export function parseXlsGrid(bytes: Uint8Array): Array<Array<string>> {
  if (!looksLikeXls(bytes)) {
    throw new Error('El archivo no es un .xls de Excel.')
  }

  const compound = openCompound(bytes)
  const workbook = compound.read('Workbook') ?? compound.read('Book')
  if (!workbook) {
    throw new Error('El .xls no trae ninguna hoja de cálculo dentro.')
  }

  const view = new DataView(workbook.buffer, workbook.byteOffset, workbook.byteLength)

  // Primera pasada: la tabla de cadenas y dónde empieza cada hoja.
  let strings: Array<string> = []
  const sheets: Array<{ offset: number; name: string }> = []
  let position = 0
  for (;;) {
    const record = readRecord(view, position)
    if (!record) break

    if (record.id === RECORD.SST) {
      const blocks = [workbook.subarray(record.start, record.start + record.length)]
      let next = readRecord(view, record.start + record.length)
      let cursor = record.start + record.length
      while (next && next.id === RECORD.CONTINUE) {
        blocks.push(workbook.subarray(next.start, next.start + next.length))
        cursor = next.start + next.length
        next = readRecord(view, cursor)
      }
      strings = readSharedStrings(blocks)
      position = cursor
      continue
    }

    if (record.id === RECORD.BOUNDSHEET) {
      // Tipo de hoja: 0 = de cálculo. Las de macros y gráficos no interesan.
      if (view.getUint8(record.start + 5) === 0) {
        sheets.push({
          offset: view.getUint32(record.start, true),
          name: readInlineString(
            view,
            record.start + 7,
            view.getUint8(record.start + 6),
          ),
        })
      }
    }

    // El primer EOF cierra la parte global: a partir de ahí van las hojas.
    if (record.id === RECORD.EOF) {
      position = record.start + record.length
      break
    }

    position = record.start + record.length
  }

  const grid: Array<Array<string>> = []
  function put(row: number, column: number, text: string) {
    if (text === '') return
    while (grid.length <= row) grid.push([])
    const line = grid[row]
    while (line.length <= column) line.push('')
    line[column] = text
  }

  // Segunda pasada: las celdas de la primera hoja.
  position = sheets.length > 0 ? sheets[0].offset : position
  let insideSheet = false
  let lastStringCell: { row: number; column: number } | null = null

  for (;;) {
    const record = readRecord(view, position)
    if (!record) break
    position = record.start + record.length

    if (record.id === RECORD.BOF) {
      insideSheet = true
      continue
    }
    if (record.id === RECORD.EOF) {
      if (insideSheet) break
      continue
    }

    const row = record.length >= 4 ? view.getUint16(record.start, true) : 0
    const column = record.length >= 4 ? view.getUint16(record.start + 2, true) : 0

    switch (record.id) {
      case RECORD.LABELSST: {
        const index = view.getUint32(record.start + 6, true)
        put(row, column, strings[index] ?? '')
        break
      }
      case RECORD.LABEL:
      case RECORD.RSTRING: {
        const characters = view.getUint16(record.start + 6, true)
        put(row, column, readInlineString(view, record.start + 8, characters))
        break
      }
      case RECORD.NUMBER: {
        put(row, column, numberToText(view.getFloat64(record.start + 6, true)))
        break
      }
      case RECORD.RK: {
        put(row, column, numberToText(decodeRk(view, record.start + 6)))
        break
      }
      case RECORD.MULRK: {
        // Una ristra de celdas contiguas: row, col inicial, n×(xf + rk), col final.
        const cells = (record.length - 6) / 6
        for (let i = 0; i < cells; i++) {
          const value = decodeRk(view, record.start + 4 + i * 6 + 2)
          put(row, column + i, numberToText(value))
        }
        break
      }
      case RECORD.FORMULA: {
        // Los dos bytes altos a 0xFFFF marcan que el resultado no es número:
        // si es texto, viene en el STRING que sigue.
        if (view.getUint16(record.start + 12, true) === 0xffff) {
          lastStringCell = { row, column }
        } else {
          put(row, column, numberToText(view.getFloat64(record.start + 6, true)))
        }
        break
      }
      case RECORD.STRING: {
        if (lastStringCell) {
          const characters = view.getUint16(record.start, true)
          const text = readInlineString(view, record.start + 2, characters)
          put(lastStringCell.row, lastStringCell.column, text)
          lastStringCell = null
        }
        break
      }
    }
  }

  return grid
}
