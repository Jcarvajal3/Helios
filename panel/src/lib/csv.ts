// ═══════════════════════════════════════════════════════════════════════════
// Escribir un CSV que Excel abra bien a la primera.
//
// Estaba copiado en dos pantallas del super admin y las dos hacían lo mismo
// mal: para que un punto y coma dentro de un texto no partiera la fila, lo
// SUSTITUÍAN por un espacio. Eso no es escapar, es borrar — y en un libro de
// ventas significa que un producto llamado «Ron; 12 años» sale del sistema
// llamándose otra cosa. Aquí se entrecomilla, que es lo que dice el formato.
//
// Las tres decisiones que hacen que se abra bien en Venezuela:
//
//   · SEPARADOR `;` — un Excel con configuración regional es-VE usa la coma
//     como separador DECIMAL, así que un CSV separado por comas le llega
//     como una sola columna de texto.
//   · DECIMAL `,` — por lo mismo: con punto, «1234.56» entra como texto y la
//     columna no se puede sumar.
//   · BOM al principio — sin él Excel lee el archivo en la codificación del
//     sistema y las tildes y las eñes salen rotas.
//
// Y los saltos de línea van en CRLF, que es lo que espera el formato y lo que
// evita que algunas versiones de Excel metan toda la tabla en una fila.
// ═══════════════════════════════════════════════════════════════════════════

export type CsvColumn<T> = {
  header: string
  /** Ya formateado. Null y undefined salen como celda vacía, que en una hoja
   *  de cálculo es «no hay dato» — y no un cero, que es un dato. */
  value: (row: T) => string | null | undefined
}

/**
 * Un texto que una hoja de cálculo no debe leer como fórmula.
 *
 * Lo que empieza por `=`, `+`, `-` o `@` (o por un tabulador o un retorno,
 * que Excel se salta) se abre en Excel como una fórmula y se ejecuta. Y a
 * estos archivos llegan textos que escribió alguien de fuera: el nombre y la
 * dirección de la portada pública, los datos de un paciente. Con un
 * apóstrofo delante queda como texto.
 *
 * Se salva la cifra negativa que escriben `csvDinero`, `csvEntero` o
 * `formatoMontoEditable` («-5,00», «-12»): no es una fórmula, y con el
 * apóstrofo la columna dejaría de sumar. Un `+` delante, en cambio, sí se
 * neutraliza aunque lo siga una cifra: ningún formato de aquí lo escribe, y
 * un teléfono como «+584141234567» saldría en notación científica.
 */
export function neutralizarFormula(valor: string): string {
  if (!/^[=+\-@\t\r]/.test(valor)) return valor
  if (/^-\d+(,\d+)?$/.test(valor)) return valor
  return `'${valor}`
}

/**
 * Un valor dentro de una celda.
 *
 * Se entrecomilla solo cuando hace falta: un archivo con todo entrecomillado
 * se abre igual, pero es el doble de grande y no se puede leer en crudo
 * cuando algo va mal.
 */
function celda(raw: string | null | undefined): string {
  if (raw === null || raw === undefined) return ''
  const value = neutralizarFormula(String(raw))
  if (!/[";\r\n]/.test(value)) return value
  // La comilla se escapa doblándola. Es lo que dice el RFC 4180 y lo que
  // entienden Excel, Sheets y cualquier lector.
  return `"${value.replace(/"/g, '""')}"`
}

/**
 * La marca de orden de bytes, escrita como escape y no como el carácter.
 *
 * Es un carácter invisible: puesto tal cual dentro del literal, no se ve en el
 * editor, se pierde en un copiar y pegar y el linter lo marca como espacio
 * raro. Con nombre, además, se lee para qué está.
 */
const BOM = '﻿'

export function construirCsv<T>(columnas: Array<CsvColumn<T>>, filas: Array<T>): string {
  const lineas = [
    columnas.map((c) => celda(c.header)).join(';'),
    ...filas.map((fila) => columnas.map((c) => celda(c.value(fila))).join(';')),
  ]

  return `${BOM}${lineas.join('\r\n')}\r\n`
}

/** Lanza la descarga. El nombre llega sin extensión. */
export function descargarCsv(nombre: string, contenido: string): void {
  const blob = new Blob([contenido], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)

  const a = document.createElement('a')
  a.href = url
  a.download = `${nombre}.csv`
  a.click()

  URL.revokeObjectURL(url)
}

// ── Formatos de celda ─────────────────────────────────────────────────────

/**
 * Un importe, con coma decimal y sin separador de miles.
 *
 * Sin el separador de miles a propósito: el punto que Venezuela usa para los
 * miles es el mismo que otras configuraciones usan para los decimales, y basta
 * que la hoja se abra en un Excel en inglés para que «1.234,56» se convierta
 * en mil doscientos treinta y cuatro coma cincuenta y seis… o en 1,23456.
 */
export function csvDinero(value: number | null | undefined, decimales = 2): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return ''
  return value.toFixed(decimales).replace('.', ',')
}

export function csvEntero(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return ''
  return String(Math.round(value))
}

/**
 * Un instante, en la hora de Caracas y en formato de hoja de cálculo.
 *
 * La hora LOCAL del negocio, no la UTC. Es la diferencia entre que una venta
 * de la una de la madrugada figure a esa hora o cinco horas más tarde —ya en
 * el día siguiente— y con eso se descuadra el cierre de caja de la noche.
 *
 * `en-CA` da `YYYY-MM-DD`, que es lo que Excel reconoce como fecha sin
 * preguntar y lo que ordena bien aunque entre como texto.
 */
export function csvInstante(iso: string | null | undefined): string {
  if (!iso) return ''

  const at = new Date(iso)
  if (Number.isNaN(at.getTime())) return ''

  const partes = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Caracas',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  }).formatToParts(at)

  const p = (tipo: Intl.DateTimeFormatPartTypes) =>
    partes.find((x) => x.type === tipo)?.value ?? ''

  return `${p('year')}-${p('month')}-${p('day')} ${p('hour')}:${p('minute')}:${p('second')}`
}
