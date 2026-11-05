// ═══════════════════════════════════════════════════════════════════════════
// Prepara la firma y el logo que sube el médico, en el navegador. El cálculo de
// píxeles (`limpiarFirma`) es puro: nada del DOM se toca al cargar el módulo,
// así se puede probar en Node.
// ═══════════════════════════════════════════════════════════════════════════

const MAX_BYTES = 15 * 1024 * 1024
const FIRMA_LADO_MAX = 1000
const LOGO_LADO_MAX = 512
/** Hasta aquí se reduce la foto antes de limpiarla: más píxeles no dan mejor firma. */
const FIRMA_LADO_DE_TRABAJO = 2000

const ERROR_LECTURA = 'No pudimos leer esa imagen. Prueba con una foto o un PNG.'
const ERROR_PESO = 'Esa imagen pesa más de 15 MB. Prueba con una más liviana.'
const ERROR_SIN_FIRMA =
  'No encontramos una firma en esa imagen. Prueba con una foto más clara sobre papel blanco.'

// ── El cálculo puro ─────────────────────────────────────────────────────────

/** Si tantos píxeles ya son transparentes, la imagen trae su transparencia de verdad. */
const FRACCION_TRANSPARENTE = 0.05
/** Por debajo de esta oscuridad relativa al papel, es papel: granos y sombras suaves. */
const OSCURIDAD_MIN = 0.12
/** Oscuridad a partir de la cual se empieza a creer que hay tinta. */
const OSCURIDAD_TINTA = 0.18
/** Diferencia absoluta mínima con el papel: en fotos oscuras el ruido pesa más. */
const DIFERENCIA_MIN = 14
/** Alfa a partir del cual un píxel cuenta como trazo y no como borde difuso. */
const ALFA_TRAZO = 48

interface ImagenRgba {
  rgba: Uint8ClampedArray
  ancho: number
  alto: number
}

function percentil(histograma: Uint32Array, cuantos: number, fraccion: number): number {
  const objetivo = cuantos * fraccion
  let acumulado = 0
  for (let i = 0; i < histograma.length; i++) {
    acumulado += histograma[i]
    if (acumulado >= objetivo) return i
  }
  return histograma.length - 1
}

/**
 * La luminancia del papel en cada píxel. Se toma un percentil alto por casillas
 * (la tinta ocupa poco, así que no lo mueve), se extiende a las casillas vecinas
 * por si una quedó llena de tinta, se suaviza y se interpola: eso sigue las
 * sombras de una foto. Un piso con el papel de toda la imagen evita confundir
 * con papel un trazo muy grueso.
 */
function estimarPapel(
  luminancia: Uint8Array,
  alfa: Uint8Array,
  ancho: number,
  alto: number,
): Float32Array {
  const lado = Math.max(8, Math.ceil(Math.max(ancho, alto) / 16))
  const columnas = Math.ceil(ancho / lado)
  const filas = Math.ceil(alto / lado)

  const histogramaTotal = new Uint32Array(256)
  let visibles = 0
  for (let i = 0; i < luminancia.length; i++) {
    if (alfa[i] < 128) continue
    histogramaTotal[luminancia[i]]++
    visibles++
  }
  const papelGlobal = percentil(histogramaTotal, visibles, 0.9)

  const casillas = new Float32Array(columnas * filas)
  const histograma = new Uint32Array(256)
  for (let f = 0; f < filas; f++) {
    for (let c = 0; c < columnas; c++) {
      histograma.fill(0)
      let cuantos = 0
      const yFin = Math.min(alto, (f + 1) * lado)
      const xFin = Math.min(ancho, (c + 1) * lado)
      for (let y = f * lado; y < yFin; y++) {
        for (let x = c * lado; x < xFin; x++) {
          const i = y * ancho + x
          if (alfa[i] < 128) continue
          histograma[luminancia[i]]++
          cuantos++
        }
      }
      casillas[f * columnas + c] = cuantos ? percentil(histograma, cuantos, 0.9) : papelGlobal
    }
  }

  const vecinas = (origen: Float32Array, combinar: (valores: number[]) => number) => {
    const destino = new Float32Array(origen.length)
    for (let f = 0; f < filas; f++) {
      for (let c = 0; c < columnas; c++) {
        const valores: number[] = []
        for (let df = -1; df <= 1; df++) {
          for (let dc = -1; dc <= 1; dc++) {
            const nf = f + df
            const nc = c + dc
            if (nf >= 0 && nf < filas && nc >= 0 && nc < columnas) {
              valores.push(origen[nf * columnas + nc])
            }
          }
        }
        destino[f * columnas + c] = combinar(valores)
      }
    }
    return destino
  }
  const extendidas = vecinas(casillas, (v) => Math.max(...v))
  const suaves = vecinas(extendidas, (v) => v.reduce((a, b) => a + b, 0) / v.length)

  const papel = new Float32Array(ancho * alto)
  const piso = papelGlobal * 0.7
  for (let y = 0; y < alto; y++) {
    const fy = Math.min(Math.max((y + 0.5) / lado - 0.5, 0), filas - 1)
    const f0 = Math.floor(fy)
    const f1 = Math.min(f0 + 1, filas - 1)
    const ty = fy - f0
    for (let x = 0; x < ancho; x++) {
      const fx = Math.min(Math.max((x + 0.5) / lado - 0.5, 0), columnas - 1)
      const c0 = Math.floor(fx)
      const c1 = Math.min(c0 + 1, columnas - 1)
      const tx = fx - c0
      const arriba = suaves[f0 * columnas + c0] * (1 - tx) + suaves[f0 * columnas + c1] * tx
      const abajo = suaves[f1 * columnas + c0] * (1 - tx) + suaves[f1 * columnas + c1] * tx
      papel[y * ancho + x] = Math.max(arriba * (1 - ty) + abajo * ty, piso)
    }
  }
  return papel
}

/**
 * Quita lo que no es trazo: los puntitos sueltos y las manchas macizas que tocan
 * el borde (la mesa que salió en la foto). Devuelve una máscara con 1 en el trazo.
 */
function quedarseConLosTrazos(alfa: Uint8Array, ancho: number, alto: number): Uint8Array {
  const total = ancho * alto
  const mascara = new Uint8Array(total)
  const visitado = new Uint8Array(total)
  const pila = new Int32Array(total)
  const areaMinima = Math.max(3, total / 200000)
  const areaDeMancha = total * 0.02

  for (let semilla = 0; semilla < total; semilla++) {
    if (visitado[semilla] || alfa[semilla] < ALFA_TRAZO) continue
    let tope = 0
    pila[tope++] = semilla
    visitado[semilla] = 1
    const miembros: number[] = []
    let area = 0
    let tocaBorde = false
    let xMin = ancho
    let xMax = 0
    let yMin = alto
    let yMax = 0
    while (tope > 0) {
      const i = pila[--tope]
      miembros.push(i)
      area++
      const x = i % ancho
      const y = (i - x) / ancho
      if (x === 0 || y === 0 || x === ancho - 1 || y === alto - 1) tocaBorde = true
      if (x < xMin) xMin = x
      if (x > xMax) xMax = x
      if (y < yMin) yMin = y
      if (y > yMax) yMax = y
      for (let dy = -1; dy <= 1; dy++) {
        const ny = y + dy
        if (ny < 0 || ny >= alto) continue
        for (let dx = -1; dx <= 1; dx++) {
          const nx = x + dx
          if (nx < 0 || nx >= ancho) continue
          const n = ny * ancho + nx
          if (visitado[n] || alfa[n] < ALFA_TRAZO) continue
          visitado[n] = 1
          pila[tope++] = n
        }
      }
    }
    const relleno = area / ((xMax - xMin + 1) * (yMax - yMin + 1))
    const esMancha = tocaBorde && area > areaDeMancha && relleno > 0.3
    if (area < areaMinima || esMancha) continue
    for (const i of miembros) mascara[i] = 1
  }
  return mascara
}

/** La tinta de un solo color: limpia, sin el tinte del papel y bien oscura. */
function colorDeTinta(
  rgba: Uint8ClampedArray,
  alfa: Uint8Array,
  mascara: Uint8Array,
): [number, number, number] {
  const NEGRO: [number, number, number] = [18, 20, 28]
  let tintaR = 0
  let tintaG = 0
  let tintaB = 0
  let tinta = 0
  let papelR = 0
  let papelG = 0
  let papelB = 0
  let papel = 0
  for (let i = 0; i < alfa.length; i++) {
    const p = i * 4
    if (mascara[i] && alfa[i] >= 200) {
      tintaR += rgba[p]
      tintaG += rgba[p + 1]
      tintaB += rgba[p + 2]
      tinta++
    } else if (alfa[i] === 0 && rgba[p + 3] >= 128) {
      papelR += rgba[p]
      papelG += rgba[p + 1]
      papelB += rgba[p + 2]
      papel++
    }
  }
  if (!tinta) return NEGRO
  let r = tintaR / tinta
  let g = tintaG / tinta
  let b = tintaB / tinta
  if (papel && papelR && papelG && papelB) {
    const gris = (papelR + papelG + papelB) / 3
    r *= gris / papelR
    g *= gris / papelG
    b *= gris / papelB
  }
  const mayor = Math.max(r, g, b)
  const menor = Math.min(r, g, b)
  if (mayor <= 0 || (mayor - menor) / mayor < 0.22) return NEGRO
  const luminancia = 0.299 * r + 0.587 * g + 0.114 * b
  const escala = Math.min(1, 70 / Math.max(luminancia, 1))
  return [Math.round(r * escala), Math.round(g * escala), Math.round(b * escala)]
}

/** La caja de lo que cumple `contenido`, con un pequeño margen. */
function recortarAlContenido(
  ancho: number,
  alto: number,
  contenido: (i: number) => boolean,
): { x: number; y: number; ancho: number; alto: number } | null {
  let xMin = ancho
  let xMax = -1
  let yMin = alto
  let yMax = -1
  for (let y = 0; y < alto; y++) {
    for (let x = 0; x < ancho; x++) {
      if (!contenido(y * ancho + x)) continue
      if (x < xMin) xMin = x
      if (x > xMax) xMax = x
      if (y < yMin) yMin = y
      if (y > yMax) yMax = y
    }
  }
  if (xMax < 0) return null
  const margen = Math.max(2, Math.round(Math.max(xMax - xMin + 1, yMax - yMin + 1) * 0.03))
  const x0 = Math.max(0, xMin - margen)
  const y0 = Math.max(0, yMin - margen)
  const x1 = Math.min(ancho - 1, xMax + margen)
  const y1 = Math.min(alto - 1, yMax + margen)
  return { x: x0, y: y0, ancho: x1 - x0 + 1, alto: y1 - y0 + 1 }
}

function respetarTransparencia(
  rgba: Uint8ClampedArray,
  ancho: number,
  alto: number,
): ImagenRgba | null {
  const caja = recortarAlContenido(ancho, alto, (i) => rgba[i * 4 + 3] > 8)
  if (!caja) return null
  const salida = new Uint8ClampedArray(caja.ancho * caja.alto * 4)
  for (let y = 0; y < caja.alto; y++) {
    const desde = ((y + caja.y) * ancho + caja.x) * 4
    salida.set(rgba.subarray(desde, desde + caja.ancho * 4), y * caja.ancho * 4)
  }
  return { rgba: salida, ancho: caja.ancho, alto: caja.alto }
}

function quitarElPapel(rgba: Uint8ClampedArray, ancho: number, alto: number): ImagenRgba | null {
  const total = ancho * alto
  const luminancia = new Uint8Array(total)
  const alfaOriginal = new Uint8Array(total)
  for (let i = 0; i < total; i++) {
    const p = i * 4
    luminancia[i] = Math.round(0.299 * rgba[p] + 0.587 * rgba[p + 1] + 0.114 * rgba[p + 2])
    alfaOriginal[i] = rgba[p + 3]
  }
  const papel = estimarPapel(luminancia, alfaOriginal, ancho, alto)

  // Cuánto más oscuro que su papel es cada píxel, de 0 a 1.
  const oscuridad = new Float32Array(total)
  const histograma = new Uint32Array(101)
  let conTinta = 0
  for (let i = 0; i < total; i++) {
    const diferencia = papel[i] - luminancia[i]
    if (alfaOriginal[i] < 128 || papel[i] < 1 || diferencia < DIFERENCIA_MIN) continue
    const d = diferencia / papel[i]
    oscuridad[i] = d
    if (d >= OSCURIDAD_TINTA) {
      histograma[Math.min(100, Math.round(d * 100))]++
      conTinta++
    }
  }
  if (!conTinta) return null

  // La rampa se adapta a la tinta: un bolígrafo flojo también llega a opaco.
  const tintaTipica = percentil(histograma, conTinta, 0.9) / 100
  const finRampa = Math.min(0.7, Math.max(OSCURIDAD_MIN + 0.12, tintaTipica * 0.75))
  const alfa = new Uint8Array(total)
  for (let i = 0; i < total; i++) {
    const t = Math.min(1, Math.max(0, (oscuridad[i] - OSCURIDAD_MIN) / (finRampa - OSCURIDAD_MIN)))
    alfa[i] = Math.round(t * t * (3 - 2 * t) * alfaOriginal[i])
  }

  const mascara = quedarseConLosTrazos(alfa, ancho, alto)
  const caja = recortarAlContenido(ancho, alto, (i) => mascara[i] === 1)
  if (!caja) return null

  // El borde difuso solo se queda si está pegado a un trazo.
  const cerca = mascara.slice()
  for (let pasada = 0; pasada < 2; pasada++) {
    const previa = cerca.slice()
    for (let y = 0; y < alto; y++) {
      for (let x = 0; x < ancho; x++) {
        const i = y * ancho + x
        if (previa[i]) continue
        const izquierda = x > 0 && previa[i - 1]
        const derecha = x < ancho - 1 && previa[i + 1]
        const encima = y > 0 && previa[i - ancho]
        const debajo = y < alto - 1 && previa[i + ancho]
        if (izquierda || derecha || encima || debajo) cerca[i] = 1
      }
    }
  }

  const [r, g, b] = colorDeTinta(rgba, alfa, mascara)
  const salida = new Uint8ClampedArray(caja.ancho * caja.alto * 4)
  for (let y = 0; y < caja.alto; y++) {
    for (let x = 0; x < caja.ancho; x++) {
      const origen = (y + caja.y) * ancho + (x + caja.x)
      const p = (y * caja.ancho + x) * 4
      salida[p] = r
      salida[p + 1] = g
      salida[p + 2] = b
      salida[p + 3] = cerca[origen] ? alfa[origen] : 0
    }
  }
  return { rgba: salida, ancho: caja.ancho, alto: caja.alto }
}

/**
 * Convierte una foto de una firma en tinta sobre transparente, recortada a su
 * contenido. Si la imagen ya trae transparencia, se respeta y solo se recorta.
 * Devuelve `null` si no encuentra tinta.
 */
export function limpiarFirma(
  rgba: Uint8ClampedArray,
  ancho: number,
  alto: number,
): { rgba: Uint8ClampedArray; ancho: number; alto: number } | null {
  if (!(ancho > 0 && alto > 0) || rgba.length < ancho * alto * 4) return null
  const total = ancho * alto
  let transparentes = 0
  for (let i = 0; i < total; i++) if (rgba[i * 4 + 3] < 250) transparentes++
  return transparentes / total >= FRACCION_TRANSPARENTE
    ? respetarTransparencia(rgba, ancho, alto)
    : quitarElPapel(rgba, ancho, alto)
}

// ── El navegador ────────────────────────────────────────────────────────────

type Lienzo = HTMLCanvasElement | OffscreenCanvas

function crearLienzo(ancho: number, alto: number): Lienzo {
  if (typeof OffscreenCanvas !== 'undefined') return new OffscreenCanvas(ancho, alto)
  const lienzo = document.createElement('canvas')
  lienzo.width = ancho
  lienzo.height = alto
  return lienzo
}

function contexto(lienzo: Lienzo): CanvasRenderingContext2D {
  const ctx = (lienzo as HTMLCanvasElement).getContext('2d', { willReadFrequently: true })
  if (!ctx) throw new Error(ERROR_LECTURA)
  ctx.imageSmoothingEnabled = true
  ctx.imageSmoothingQuality = 'high'
  return ctx
}

async function comoPng(lienzo: Lienzo): Promise<Blob> {
  if ('convertToBlob' in lienzo) return lienzo.convertToBlob({ type: 'image/png' })
  return new Promise((resolver, rechazar) => {
    lienzo.toBlob(
      (blob) => (blob ? resolver(blob) : rechazar(new Error(ERROR_LECTURA))),
      'image/png',
    )
  })
}

/** Respeta la orientación de la foto: `createImageBitmap` aplica el EXIF. */
async function decodificar(archivo: File): Promise<ImageBitmap> {
  if (archivo.size > MAX_BYTES) throw new Error(ERROR_PESO)
  try {
    return await createImageBitmap(archivo)
  } catch {
    throw new Error(ERROR_LECTURA)
  }
}

/** Nunca agranda. */
function medidasHasta(ancho: number, alto: number, ladoMax: number) {
  const escala = Math.min(1, ladoMax / Math.max(ancho, alto))
  return {
    ancho: Math.max(1, Math.round(ancho * escala)),
    alto: Math.max(1, Math.round(alto * escala)),
  }
}

/** Convierte una foto de la firma en un PNG de tinta sobre transparente. */
export async function prepararFirma(archivo: File): Promise<Blob> {
  const bitmap = await decodificar(archivo)
  let pixeles: ImageData
  try {
    const trabajo = medidasHasta(bitmap.width, bitmap.height, FIRMA_LADO_DE_TRABAJO)
    const lienzo = crearLienzo(trabajo.ancho, trabajo.alto)
    const ctx = contexto(lienzo)
    ctx.drawImage(bitmap, 0, 0, trabajo.ancho, trabajo.alto)
    pixeles = ctx.getImageData(0, 0, trabajo.ancho, trabajo.alto)
  } catch {
    throw new Error(ERROR_LECTURA)
  } finally {
    bitmap.close()
  }

  const limpia = limpiarFirma(pixeles.data, pixeles.width, pixeles.height)
  if (!limpia) throw new Error(ERROR_SIN_FIRMA)

  const recorte = crearLienzo(limpia.ancho, limpia.alto)
  const ctxRecorte = contexto(recorte)
  const datos = ctxRecorte.createImageData(limpia.ancho, limpia.alto)
  datos.data.set(limpia.rgba)
  ctxRecorte.putImageData(datos, 0, 0)

  const final = medidasHasta(limpia.ancho, limpia.alto, FIRMA_LADO_MAX)
  if (final.ancho === limpia.ancho && final.alto === limpia.alto) return comoPng(recorte)
  const reducido = crearLienzo(final.ancho, final.alto)
  contexto(reducido).drawImage(recorte, 0, 0, final.ancho, final.alto)
  return comoPng(reducido)
}

/** Reduce el logo sin tocar sus colores ni su transparencia. */
export async function prepararLogo(archivo: File): Promise<Blob> {
  const bitmap = await decodificar(archivo)
  try {
    const final = medidasHasta(bitmap.width, bitmap.height, LOGO_LADO_MAX)
    const lienzo = crearLienzo(final.ancho, final.alto)
    contexto(lienzo).drawImage(bitmap, 0, 0, final.ancho, final.alto)
    return await comoPng(lienzo)
  } catch {
    throw new Error(ERROR_LECTURA)
  } finally {
    bitmap.close()
  }
}
