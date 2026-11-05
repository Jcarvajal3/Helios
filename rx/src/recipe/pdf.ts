// ═══════════════════════════════════════════════════════════════════════════
// El PDF del récipe: media carta vertical, una hoja «Récipe» para la farmacia y
// una hoja «Indicaciones» para el paciente, cada una con su membrete, el
// paciente, la firma y los datos del consultorio.
//
// Solo usa pdf-lib, sin APIs del DOM: corre igual en el navegador y en Node.
// El encabezado, la franja del paciente y el pie miden lo mismo en todas las
// hojas, porque dependen solo de los datos: se miden una vez y el cuerpo fluye
// en lo que queda.
// ═══════════════════════════════════════════════════════════════════════════
import {
  PDFDocument,
  StandardFonts,
  rgb,
  type Color,
  type PDFFont,
  type PDFImage,
  type PDFPage,
} from 'pdf-lib'
import type { DatosRecipe, ImagenesRecipe } from '../modelo.ts'

const ANCHO_HOJA = 396
const ALTO_HOJA = 612
const MARGEN = 28
const ANCHO_UTIL = ANCHO_HOJA - MARGEN * 2

function colorHex(hex: number): Color {
  return rgb(((hex >> 16) & 255) / 255, ((hex >> 8) & 255) / 255, (hex & 255) / 255)
}

const AZUL = colorHex(0x0040b8)
const TINTA = colorHex(0x0f1a2e)
const GRIS = colorHex(0x44506a)
const GRIS_SUAVE = colorHex(0x8a94a8)
const FILETE_SUAVE = colorHex(0xd9dee8)

const LOGO_MAX = 52
const FIRMA_ANCHO_MAX = 120
const FIRMA_ALTO_MAX = 48
/** Ancho de la línea de la firma, y del nombre y el MPPS que van debajo. */
const ANCHO_LINEA_FIRMA = 150
/** Lo que la firma baja de su línea: una firma de verdad siempre la cruza un poco. */
const FIRMA_CRUZA_LINEA = 6

// ── Texto ───────────────────────────────────────────────────────────────────

/** Lo que Windows-1252 añade entre 0x80 y 0x9F: lo único de ese tramo que entra. */
const WIN_ANSI_EXTRA = new Set(
  Array.from('€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ', (c) => c.codePointAt(0) as number),
)

const EQUIVALENCIAS: Record<string, string> = {
  '≥': '>=',
  '≤': '<=',
  '≠': '!=',
  '≈': '~',
  '∼': '~',
  '→': '->',
  '←': '<-',
  '⇒': '=>',
  '−': '-',
  '‐': '-',
  '‑': '-',
  '‒': '-',
  '–': '-',
  '—': '-',
  '―': '-',
  '“': '"',
  '”': '"',
  '„': '"',
  '‟': '"',
  '‘': "'",
  '’': "'",
  '‚': "'",
  '‛': "'",
  '…': '...',
  'μ': 'µ',
  '∙': '·',
  '⁄': '/',
  '№': 'N.º',
}

function entraEnWinAnsi(cp: number): boolean {
  if (cp >= 0x20 && cp <= 0x7e) return true
  if (cp >= 0xa1 && cp <= 0xff) return cp !== 0xad
  return WIN_ANSI_EXTRA.has(cp)
}

function textoEntraEnWinAnsi(texto: string): boolean {
  for (const c of texto) if (!entraEnWinAnsi(c.codePointAt(0) as number)) return false
  return true
}

/**
 * Deja el texto dentro de lo que dibujan las fuentes estándar (WinAnsi): las
 * equivalencias comunes se reemplazan, lo demás se quita. Acentos, ñ, ¿¡, º y ª
 * sobreviven. Conserva los saltos de línea; nunca lanza.
 */
export function sanearTexto(texto: unknown): string {
  if (texto === null || texto === undefined) return ''
  const fuente = String(texto).normalize('NFC').replace(/\r\n?/g, '\n')
  let salida = ''
  for (const c of fuente) {
    if (c === '\n') {
      salida += c
      continue
    }
    const equivalente = EQUIVALENCIAS[c]
    if (equivalente !== undefined) {
      salida += equivalente
      continue
    }
    if (/\s/.test(c)) {
      salida += ' '
      continue
    }
    if (entraEnWinAnsi(c.codePointAt(0) as number)) {
      salida += c
      continue
    }
    // «ć» → «c», «㎎» → «mg». Lo que no tenga forma (emoji, chino…) se va.
    const base = c.normalize('NFKD').replace(/\p{M}/gu, '')
    if (base && textoEntraEnWinAnsi(base)) salida += base
  }
  return salida
    .split('\n')
    .map((linea) => linea.replace(/ {2,}/g, ' ').trim())
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

/** Igual que `sanearTexto`, para los datos que van en una sola línea. */
function sanearLinea(texto: unknown): string {
  return sanearTexto(texto).replace(/\n+/g, ' ')
}

const anchosPorFuente = new WeakMap<PDFFont, Map<string, number>>()

/**
 * El ancho tal como se dibuja. `widthOfTextAtSize` descuenta el kerning, pero
 * `drawText` no lo aplica: sumando letra por letra la medida coincide, y además
 * no se mide dos veces la misma letra.
 */
function anchoDe(texto: string, fuente: PDFFont, tam: number): number {
  let anchos = anchosPorFuente.get(fuente)
  if (!anchos) {
    anchos = new Map()
    anchosPorFuente.set(fuente, anchos)
  }
  let total = 0
  for (const c of texto) {
    let ancho = anchos.get(c)
    if (ancho === undefined) {
      ancho = fuente.widthOfTextAtSize(c, 1)
      anchos.set(c, ancho)
    }
    total += ancho
  }
  return total * tam
}

/** Ajusta por palabras y respeta los saltos de línea. Una palabra que no cabe se parte. */
function envolver(texto: string, fuente: PDFFont, tam: number, ancho: number): string[] {
  if (!texto) return []
  const lineas: string[] = []
  for (const parrafo of texto.split('\n')) {
    if (!parrafo) {
      lineas.push('')
      continue
    }
    let actual = ''
    for (const palabra of parrafo.split(' ')) {
      const prueba = actual ? `${actual} ${palabra}` : palabra
      if (anchoDe(prueba, fuente, tam) <= ancho) {
        actual = prueba
        continue
      }
      if (actual) lineas.push(actual)
      actual = ''
      if (anchoDe(palabra, fuente, tam) <= ancho) {
        actual = palabra
        continue
      }
      let acumulado = 0
      for (const c of palabra) {
        const anchoLetra = anchoDe(c, fuente, tam)
        if (actual && acumulado + anchoLetra > ancho) {
          lineas.push(actual)
          actual = ''
          acumulado = 0
        }
        actual += c
        acumulado += anchoLetra
      }
    }
    if (actual) lineas.push(actual)
  }
  return lineas
}

/**
 * Une con « · » y salta de línea entre pieza y pieza, así ninguna línea empieza
 * ni termina en un separador. Una pieza que no cabe sola se ajusta por palabras.
 */
function envolverPiezas(piezas: string[], fuente: PDFFont, tam: number, ancho: number): string[] {
  const lineas: string[] = []
  let actual = ''
  for (const pieza of piezas) {
    const prueba = actual ? `${actual} · ${pieza}` : pieza
    if (anchoDe(prueba, fuente, tam) <= ancho) {
      actual = prueba
      continue
    }
    if (actual) lineas.push(actual)
    const partes = envolver(pieza, fuente, tam, ancho)
    actual = partes.pop() ?? ''
    lineas.push(...partes)
  }
  if (actual) lineas.push(actual)
  return lineas
}

/** Tope de líneas para los datos del membrete: el cuerpo siempre tiene que tener sitio. */
function recortar(lineas: string[], maximo: number, fuente: PDFFont, tam: number, ancho: number) {
  if (lineas.length <= maximo) return lineas
  const quedan = lineas.slice(0, maximo)
  let ultima = quedan[maximo - 1]
  while (ultima && anchoDe(`${ultima}...`, fuente, tam) > ancho) ultima = ultima.slice(0, -1)
  quedan[maximo - 1] = `${ultima.trimEnd()}...`
  return quedan
}

/** Línea de base para que el texto quede centrado en una línea de ese alto. */
function lineaBase(arriba: number, alto: number, tam: number): number {
  return arriba - (alto + tam * 0.72) / 2
}

// ── Imágenes ────────────────────────────────────────────────────────────────

interface Colocada {
  imagen: PDFImage
  ancho: number
  alto: number
}

function esPng(b: Uint8Array): boolean {
  const firma = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
  return b.length > 8 && firma.every((valor, i) => b[i] === valor)
}

function esJpeg(b: Uint8Array): boolean {
  return b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff
}

/** Una imagen corrupta o de otro tipo se omite: el récipe sale igual. */
async function incrustar(
  doc: PDFDocument,
  bytes: Uint8Array | null | undefined,
  anchoMax: number,
  altoMax: number,
): Promise<Colocada | null> {
  if (!bytes) return null
  try {
    let imagen: PDFImage
    if (esPng(bytes)) imagen = await doc.embedPng(bytes)
    else if (esJpeg(bytes)) imagen = await doc.embedJpg(bytes)
    else return null
    // pdf-lib la dejaría para el `save()`: aquí todavía se puede omitir.
    await imagen.embed()
    if (!(imagen.width > 0 && imagen.height > 0)) return null
    const escala = Math.min(anchoMax / imagen.width, altoMax / imagen.height)
    return { imagen, ancho: imagen.width * escala, alto: imagen.height * escala }
  } catch {
    return null
  }
}

// ── Fuentes y renglones ─────────────────────────────────────────────────────

interface Fuentes {
  normal: PDFFont
  negrita: PDFFont
  cursiva: PDFFont
}

interface Renglon {
  texto: string
  fuente: PDFFont
  tam: number
  color: Color
  /** Sangría desde el margen. */
  x: number
  /** Lo que ocupa en vertical. */
  alto: number
  /** El número de la lista, colgando a la izquierda del texto. */
  marca?: string
}

function renglones(
  texto: string,
  fuente: PDFFont,
  tam: number,
  color: Color,
  alto: number,
  x = 0,
): Renglon[] {
  return envolver(texto, fuente, tam, ANCHO_UTIL - x).map((linea) => ({
    texto: linea,
    fuente,
    tam,
    color,
    x,
    // Una línea en blanco separa, pero no pesa como una línea de texto.
    alto: linea ? alto : alto * 0.6,
  }))
}

function dibujarRenglon(pagina: PDFPage, r: Renglon, arriba: number): void {
  if (!r.texto && !r.marca) return
  const y = lineaBase(arriba, r.alto, r.tam)
  if (r.marca) {
    pagina.drawText(r.marca, { x: MARGEN, y, size: r.tam, font: r.fuente, color: r.color })
  }
  if (r.texto) {
    pagina.drawText(r.texto, { x: MARGEN + r.x, y, size: r.tam, font: r.fuente, color: r.color })
  }
}

// ── Membrete: encabezado, paciente y pie ────────────────────────────────────

interface Plantilla {
  /** Dónde empieza y dónde termina el cuerpo de cada hoja. */
  arribaCuerpo: number
  abajoCuerpo: number
  dibujar(pagina: PDFPage): void
  numerar(pagina: PDFPage, hoja: number, total: number): void
}

function prepararPlantilla(
  datos: DatosRecipe,
  fuentes: Fuentes,
  logo: Colocada | null,
  firma: Colocada | null,
): Plantilla {
  const { normal, negrita } = fuentes
  const doctor = datos.doctor ?? ({} as DatosRecipe['doctor'])
  const paciente = datos.paciente ?? ({} as DatosRecipe['paciente'])

  // Encabezado
  const nombreMedico = sanearLinea(doctor.nombre)
  const mpps = sanearLinea(doctor.mpps)
  const xTexto = logo ? MARGEN + logo.ancho + 12 : MARGEN
  const anchoTexto = ANCHO_HOJA - MARGEN - xTexto
  const credenciales = [
    ['C.I.', sanearLinea(doctor.cedula)],
    ['MPPS', mpps],
    ['C.M.', sanearLinea(doctor.colegio)],
  ]
    .filter(([, valor]) => valor)
    .map(([etiqueta, valor]) => `${etiqueta} ${valor}`)

  const textoEncabezado: Renglon[] = [
    ...recortar(envolver(nombreMedico, negrita, 13, anchoTexto), 2, negrita, 13, anchoTexto).map(
      (texto) => ({ texto, fuente: negrita, tam: 13, color: TINTA, x: 0, alto: 16 }),
    ),
    ...recortar(
      envolver(sanearLinea(doctor.especialidad), normal, 9, anchoTexto),
      2,
      normal,
      9,
      anchoTexto,
    ).map((texto) => ({ texto, fuente: normal, tam: 9, color: GRIS, x: 0, alto: 12 })),
    ...recortar(
      envolverPiezas(credenciales, normal, 7.5, anchoTexto),
      2,
      normal,
      7.5,
      anchoTexto,
    ).map((texto) => ({ texto, fuente: normal, tam: 7.5, color: GRIS, x: 0, alto: 10.5 })),
  ]
  const altoTexto = textoEncabezado.reduce((suma, r) => suma + r.alto, 0)
  const altoCaja = Math.max(logo ? LOGO_MAX : 0, altoTexto)

  const arribaHoja = ALTO_HOJA - MARGEN
  const yFilete = arribaHoja - altoCaja - 9

  // Franja del paciente
  const TAM_PACIENTE = 9
  const ALTO_PACIENTE = 12.5
  const nombrePaciente = sanearLinea(paciente.nombre)
  const documento = sanearLinea(paciente.documento)
  const edad = sanearLinea(paciente.edad)
  const fecha = fechaLatina(sanearLinea(datos.fecha))
  const numero = numeroConCeros(datos.numero)

  const derecha: { etiqueta: string; valor: string }[] = []
  if (fecha) derecha.push({ etiqueta: 'Fecha: ', valor: fecha })
  if (numero) derecha.push({ etiqueta: 'N.º ', valor: numero })
  const anchoDerecha = Math.max(
    0,
    ...derecha.map(
      (c) =>
        anchoDe(c.etiqueta, normal, TAM_PACIENTE) + anchoDe(c.valor, negrita, TAM_PACIENTE),
    ),
  )
  const anchoIzquierda = ANCHO_UTIL - (anchoDerecha ? anchoDerecha + 16 : 0)

  interface CampoPaciente {
    etiqueta: string
    lineas: string[]
    fuente: PDFFont
    x: number
    fila: number
  }
  const campos: CampoPaciente[] = []
  let fila = 0
  const anadirCampo = (etiqueta: string, valor: string, fuente: PDFFont, maximo: number) => {
    if (!valor) return
    const anchoEtiqueta = anchoDe(etiqueta, normal, TAM_PACIENTE)
    const anchoValor = Math.max(anchoIzquierda - anchoEtiqueta, 40)
    const lineas = recortar(
      envolver(valor, fuente, TAM_PACIENTE, anchoValor),
      maximo,
      fuente,
      TAM_PACIENTE,
      anchoValor,
    )
    campos.push({ etiqueta, lineas, fuente, x: 0, fila })
    fila += lineas.length
  }
  anadirCampo('Paciente: ', nombrePaciente, negrita, 3)
  const ETIQUETA_CI = 'C.I.: '
  const ETIQUETA_EDAD = 'Edad: '
  const anchoCi = anchoDe(ETIQUETA_CI, normal, TAM_PACIENTE) + anchoDe(documento, normal, TAM_PACIENTE)
  const anchoEdad =
    anchoDe(ETIQUETA_EDAD, normal, TAM_PACIENTE) + anchoDe(edad, normal, TAM_PACIENTE)
  if (documento && edad && anchoCi + 16 + anchoEdad <= anchoIzquierda) {
    campos.push({ etiqueta: ETIQUETA_CI, lineas: [documento], fuente: normal, x: 0, fila })
    campos.push({
      etiqueta: ETIQUETA_EDAD,
      lineas: [edad],
      fuente: normal,
      x: anchoCi + 16,
      fila,
    })
    fila += 1
  } else {
    anadirCampo(ETIQUETA_CI, documento, normal, 2)
    anadirCampo(ETIQUETA_EDAD, edad, normal, 2)
  }
  const filasPaciente = Math.max(fila, derecha.length)
  const hayFranja = filasPaciente > 0
  const arribaPaciente = yFilete - 8
  const yFinPaciente = hayFranja ? arribaPaciente - filasPaciente * ALTO_PACIENTE - 7 : yFilete

  // Pie, de abajo hacia arriba
  const ALTO_HOJA_N = 8.5
  const ALTO_CONTACTO = 8.5
  const piezasContacto = [
    doctor.consultorio,
    doctor.direccion,
    doctor.ciudad,
    doctor.telefono,
    doctor.correo,
  ]
    .map(sanearLinea)
    .filter(Boolean)
  const contacto = recortar(
    envolverPiezas(piezasContacto, normal, 6.5, ANCHO_UTIL),
    3,
    normal,
    6.5,
    ANCHO_UTIL,
  )
  const arribaHojaN = MARGEN + ALTO_HOJA_N
  const arribaContacto = arribaHojaN + contacto.length * ALTO_CONTACTO

  const xLinea = ANCHO_HOJA - MARGEN - ANCHO_LINEA_FIRMA
  const firmante = recortar(
    envolver(nombreMedico, negrita, 8.5, ANCHO_LINEA_FIRMA),
    2,
    negrita,
    8.5,
    ANCHO_LINEA_FIRMA,
  )
  const lineaMpps = mpps ? `MPPS ${mpps}` : ''
  const mppsAjustado = recortar(
    envolver(lineaMpps, normal, 7.5, ANCHO_LINEA_FIRMA),
    1,
    normal,
    7.5,
    ANCHO_LINEA_FIRMA,
  )
  const altoFirmante = firmante.length * 11 + mppsAjustado.length * 10
  const arribaFirmante = arribaContacto + (contacto.length ? 9 : 4) + altoFirmante
  const yLineaFirma = arribaFirmante + 4
  const abajoCuerpo = yLineaFirma + FIRMA_ALTO_MAX - FIRMA_CRUZA_LINEA + 8

  return {
    arribaCuerpo: yFinPaciente - 13,
    abajoCuerpo,
    dibujar(pagina) {
      // Encabezado
      if (logo) {
        pagina.drawImage(logo.imagen, {
          x: MARGEN,
          y: arribaHoja - altoCaja / 2 - logo.alto / 2,
          width: logo.ancho,
          height: logo.alto,
        })
      }
      let arriba = arribaHoja - (altoCaja - altoTexto) / 2
      for (const r of textoEncabezado) {
        pagina.drawText(r.texto, {
          x: xTexto,
          y: lineaBase(arriba, r.alto, r.tam),
          size: r.tam,
          font: r.fuente,
          color: r.color,
        })
        arriba -= r.alto
      }
      pagina.drawLine({
        start: { x: MARGEN, y: yFilete },
        end: { x: ANCHO_HOJA - MARGEN, y: yFilete },
        thickness: 0.8,
        color: AZUL,
      })

      // Paciente
      if (hayFranja) {
        for (const campo of campos) {
          const x = MARGEN + campo.x
          const anchoEtiqueta = anchoDe(campo.etiqueta, normal, TAM_PACIENTE)
          campo.lineas.forEach((linea, i) => {
            const y = lineaBase(
              arribaPaciente - (campo.fila + i) * ALTO_PACIENTE,
              ALTO_PACIENTE,
              TAM_PACIENTE,
            )
            if (i === 0) {
              pagina.drawText(campo.etiqueta, {
                x,
                y,
                size: TAM_PACIENTE,
                font: normal,
                color: GRIS,
              })
            }
            pagina.drawText(linea, {
              x: x + anchoEtiqueta,
              y,
              size: TAM_PACIENTE,
              font: campo.fuente,
              color: TINTA,
            })
          })
        }
        derecha.forEach((campo, i) => {
          const y = lineaBase(arribaPaciente - i * ALTO_PACIENTE, ALTO_PACIENTE, TAM_PACIENTE)
          const anchoValor = anchoDe(campo.valor, negrita, TAM_PACIENTE)
          const xValor = ANCHO_HOJA - MARGEN - anchoValor
          pagina.drawText(campo.valor, {
            x: xValor,
            y,
            size: TAM_PACIENTE,
            font: negrita,
            color: TINTA,
          })
          pagina.drawText(campo.etiqueta, {
            x: xValor - anchoDe(campo.etiqueta, normal, TAM_PACIENTE),
            y,
            size: TAM_PACIENTE,
            font: normal,
            color: GRIS,
          })
        })
        pagina.drawLine({
          start: { x: MARGEN, y: yFinPaciente },
          end: { x: ANCHO_HOJA - MARGEN, y: yFinPaciente },
          thickness: 0.4,
          color: FILETE_SUAVE,
        })
      }

      // Pie: la firma cruza su línea, y sin firma la línea queda vacía
      if (firma) {
        pagina.drawImage(firma.imagen, {
          x: xLinea + (ANCHO_LINEA_FIRMA - firma.ancho) / 2,
          y: yLineaFirma - FIRMA_CRUZA_LINEA,
          width: firma.ancho,
          height: firma.alto,
        })
      }
      pagina.drawLine({
        start: { x: xLinea, y: yLineaFirma },
        end: { x: xLinea + ANCHO_LINEA_FIRMA, y: yLineaFirma },
        thickness: 0.6,
        color: TINTA,
      })
      let arribaPie = arribaFirmante
      for (const linea of firmante) {
        pagina.drawText(linea, {
          x: xLinea + (ANCHO_LINEA_FIRMA - anchoDe(linea, negrita, 8.5)) / 2,
          y: lineaBase(arribaPie, 11, 8.5),
          size: 8.5,
          font: negrita,
          color: TINTA,
        })
        arribaPie -= 11
      }
      for (const linea of mppsAjustado) {
        pagina.drawText(linea, {
          x: xLinea + (ANCHO_LINEA_FIRMA - anchoDe(linea, normal, 7.5)) / 2,
          y: lineaBase(arribaPie, 10, 7.5),
          size: 7.5,
          font: normal,
          color: GRIS,
        })
        arribaPie -= 10
      }
      contacto.forEach((linea, i) => {
        pagina.drawText(linea, {
          x: (ANCHO_HOJA - anchoDe(linea, normal, 6.5)) / 2,
          y: lineaBase(arribaContacto - i * ALTO_CONTACTO, ALTO_CONTACTO, 6.5),
          size: 6.5,
          font: normal,
          color: GRIS,
        })
      })
    },
    numerar(pagina, hoja, total) {
      const texto = `Hoja ${hoja} de ${total}`
      pagina.drawText(texto, {
        x: (ANCHO_HOJA - anchoDe(texto, normal, 6)) / 2,
        y: lineaBase(arribaHojaN, ALTO_HOJA_N, 6),
        size: 6,
        font: normal,
        color: GRIS_SUAVE,
      })
    },
  }
}

// ── El cuerpo que fluye ─────────────────────────────────────────────────────

/** Dibuja el título de la hoja y devuelve dónde empieza la lista. */
type DibujarTitulo = (pagina: PDFPage, arriba: number, continuacion: boolean) => number

/**
 * Abre una hoja por cada vez que el cuerpo se llena. Un ítem que no cabe en lo
 * que queda pasa entero a la siguiente; solo se parte si ni en una hoja vacía
 * cabe.
 */
function crearFlujo(doc: PDFDocument, plantilla: Plantilla, dibujarTitulo: DibujarTitulo) {
  let pagina: PDFPage
  let y = 0
  let inicio = 0
  let abiertas = 0

  const abrir = () => {
    pagina = doc.addPage([ANCHO_HOJA, ALTO_HOJA])
    plantilla.dibujar(pagina)
    y = dibujarTitulo(pagina, plantilla.arribaCuerpo, abiertas > 0)
    inicio = y
    abiertas += 1
  }
  abrir()
  const altoHojaVacia = inicio - plantilla.abajoCuerpo

  const pintar = (r: Renglon) => {
    dibujarRenglon(pagina, r, y)
    y -= r.alto
  }

  return {
    colocar(bloque: Renglon[], espacioAntes = 0) {
      if (bloque.length === 0) return
      const antes = y === inicio ? 0 : espacioAntes
      const alto = bloque.reduce((suma, r) => suma + r.alto, 0)
      const libre = y - plantilla.abajoCuerpo
      if (antes + alto <= libre) {
        y -= antes
        bloque.forEach(pintar)
        return
      }
      if (alto <= altoHojaVacia) {
        abrir()
        bloque.forEach(pintar)
        return
      }
      // No cabe ni en una hoja entera: se parte, sin dejar un renglón solo abajo.
      const dosPrimeros = bloque.slice(0, 2).reduce((suma, r) => suma + r.alto, 0)
      if (antes + dosPrimeros > libre) abrir()
      else y -= antes
      for (const r of bloque) {
        if (r.alto > y - plantilla.abajoCuerpo) abrir()
        if (!r.texto && y === inicio) continue
        pintar(r)
      }
    },
  }
}

// ── Las dos hojas ───────────────────────────────────────────────────────────

function hojaRecipe(doc: PDFDocument, plantilla: Plantilla, fuentes: Fuentes, datos: DatosRecipe) {
  const { normal, negrita, cursiva } = fuentes
  const flujo = crearFlujo(doc, plantilla, (pagina, arriba, continuacion) => {
    const altoTitulo = 34
    const y = lineaBase(arriba, altoTitulo, 27)
    pagina.drawText('Rp.', { x: MARGEN, y, size: 27, font: cursiva, color: AZUL })
    if (continuacion) {
      pagina.drawText('(continuación)', {
        x: MARGEN + anchoDe('Rp.', cursiva, 27) + 8,
        y,
        size: 7.5,
        font: normal,
        color: GRIS,
      })
    }
    return arriba - altoTitulo - 8
  })

  const items = (Array.isArray(datos.medicamentos) ? datos.medicamentos : [])
    .map((m) => ({
      nombre: sanearTexto(m?.medicamento),
      detalle: [sanearLinea(m?.presentacion), sanearLinea(m?.cantidad)]
        .filter(Boolean)
        .join(' · '),
    }))
    .filter((m) => m.nombre || m.detalle)

  const TAM_NOMBRE = 11
  const sangria = anchoDe(`${items.length}.`, negrita, TAM_NOMBRE) + 5
  items.forEach((item, i) => {
    const bloque = [
      ...renglones(item.nombre, negrita, TAM_NOMBRE, TINTA, 14.5, sangria),
      ...renglones(item.detalle, normal, 9, GRIS, 12, sangria),
    ]
    if (bloque.length) bloque[0] = { ...bloque[0], marca: `${i + 1}.` }
    flujo.colocar(bloque, 10)
  })
}

function hojaIndicaciones(
  doc: PDFDocument,
  plantilla: Plantilla,
  fuentes: Fuentes,
  datos: DatosRecipe,
) {
  const { normal, negrita } = fuentes
  const flujo = crearFlujo(doc, plantilla, (pagina, arriba, continuacion) => {
    const altoTitulo = 20
    const y = lineaBase(arriba, altoTitulo, 14)
    pagina.drawText('Indicaciones', { x: MARGEN, y, size: 14, font: negrita, color: TINTA })
    if (continuacion) {
      pagina.drawText('(continuación)', {
        x: MARGEN + anchoDe('Indicaciones', negrita, 14) + 6,
        y,
        size: 7.5,
        font: normal,
        color: GRIS,
      })
    }
    return arriba - altoTitulo - 10
  })

  const conIndicacion = (Array.isArray(datos.medicamentos) ? datos.medicamentos : [])
    .map((m) => ({ nombre: sanearTexto(m?.medicamento), indicacion: sanearTexto(m?.indicacion) }))
    .filter((m) => m.indicacion)
  for (const m of conIndicacion) {
    flujo.colocar(
      [
        ...renglones(m.nombre, negrita, 10, TINTA, 13.5),
        ...renglones(m.indicacion, normal, 9.5, TINTA, 13),
      ],
      11,
    )
  }

  const generales = sanearTexto(datos.indicaciones)
  if (!generales) return
  const parrafos = generales.split(/\n{2,}/)
  parrafos.forEach((parrafo, i) => {
    const cuerpo = renglones(parrafo, normal, 9.5, TINTA, 13)
    if (i === 0) {
      // El título viaja con su primer párrafo: nunca queda solo al final de una hoja.
      const titulo = renglones('Indicaciones generales', negrita, 10, TINTA, 15)
      flujo.colocar([...titulo, ...cuerpo], conIndicacion.length ? 16 : 0)
    } else {
      flujo.colocar(cuerpo, 8)
    }
  })
}

// ── Lo que se exporta ───────────────────────────────────────────────────────

function numeroConCeros(numero: number | null | undefined): string {
  if (typeof numero !== 'number' || !Number.isFinite(numero)) return ''
  return String(Math.trunc(numero)).padStart(6, '0')
}

/** `2026-11-05` → `05/11/2026`. Lo que no sea una fecha ISO se devuelve tal cual. */
export function fechaLatina(iso: string): string {
  const partes = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso ?? '')
  return partes ? `${partes[3]}/${partes[2]}/${partes[1]}` : (iso ?? '')
}

/** `Recipe-000123.pdf`; un borrador, que aún no tiene número, `Recipe-borrador.pdf`. */
export function nombreDelArchivo(numero: number | null): string {
  const conCeros = numeroConCeros(numero)
  return `Recipe-${conCeros || 'borrador'}.pdf`
}

/** ¿Hay algo que poner en la hoja de indicaciones? */
export function hayIndicaciones(datos: Pick<DatosRecipe, 'medicamentos' | 'indicaciones'>): boolean {
  if (sanearTexto(datos.indicaciones)) return true
  const medicamentos = Array.isArray(datos.medicamentos) ? datos.medicamentos : []
  return medicamentos.some((m) => sanearTexto(m?.indicacion))
}

export async function generarPdf(
  datos: DatosRecipe,
  imagenes: ImagenesRecipe,
): Promise<Uint8Array> {
  const doc = await PDFDocument.create()
  const [normal, negrita, cursiva] = await Promise.all([
    doc.embedFont(StandardFonts.Helvetica),
    doc.embedFont(StandardFonts.HelveticaBold),
    doc.embedFont(StandardFonts.TimesRomanItalic),
  ])
  const fuentes: Fuentes = { normal, negrita, cursiva }
  const logo = await incrustar(doc, imagenes?.logo, LOGO_MAX, LOGO_MAX)
  const firma = await incrustar(doc, imagenes?.firma, FIRMA_ANCHO_MAX, FIRMA_ALTO_MAX)

  const plantilla = prepararPlantilla(datos, fuentes, logo, firma)
  hojaRecipe(doc, plantilla, fuentes, datos)
  if (hayIndicaciones(datos)) hojaIndicaciones(doc, plantilla, fuentes, datos)

  const paginas = doc.getPages()
  paginas.forEach((pagina, i) => plantilla.numerar(pagina, i + 1, paginas.length))

  const numero = numeroConCeros(datos.numero)
  doc.setTitle(numero ? `Récipe ${numero}` : 'Récipe')
  doc.setAuthor(sanearLinea(datos.doctor?.nombre))
  doc.setProducer('RX · Helios')
  doc.setCreator('RX · Helios')
  doc.setLanguage('es-VE')
  return doc.save()
}
