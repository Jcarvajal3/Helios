import { test } from 'node:test'
import assert from 'node:assert/strict'
import { limpiarFirma, prepararFirma, prepararLogo } from './imagenes.ts'

type Color = [number, number, number, number?]

function lienzo(ancho: number, alto: number, fondo: (x: number, y: number) => Color) {
  const rgba = new Uint8ClampedArray(ancho * alto * 4)
  for (let y = 0; y < alto; y++) {
    for (let x = 0; x < ancho; x++) {
      const [r, g, b, a = 255] = fondo(x, y)
      rgba.set([r, g, b, a], (y * ancho + x) * 4)
    }
  }
  return rgba
}

function pintar(
  rgba: Uint8ClampedArray,
  ancho: number,
  caja: { x: number; y: number; ancho: number; alto: number },
  [r, g, b, a = 255]: Color,
) {
  for (let y = caja.y; y < caja.y + caja.alto; y++) {
    for (let x = caja.x; x < caja.x + caja.ancho; x++) {
      rgba.set([r, g, b, a], (y * ancho + x) * 4)
    }
  }
}

function alfas(imagen: { rgba: Uint8ClampedArray }) {
  const valores: number[] = []
  for (let i = 3; i < imagen.rgba.length; i += 4) valores.push(imagen.rgba[i])
  return valores
}

function pixel(imagen: { rgba: Uint8ClampedArray; ancho: number }, x: number, y: number) {
  const p = (y * imagen.ancho + x) * 4
  return Array.from(imagen.rgba.subarray(p, p + 4))
}

/** Grano parejo y repetible, como el de una foto. */
function grano(x: number, y: number, amplitud: number) {
  return ((x * 73 + y * 151) % 11) / 10 * amplitud - amplitud / 2
}

test('limpiarFirma: el fondo gris queda transparente y la tinta opaca', () => {
  const rgba = lienzo(300, 150, (x, y) => {
    const g = 180 + grano(x, y, 8)
    return [g, g, g]
  })
  pintar(rgba, 300, { x: 60, y: 70, ancho: 180, alto: 6 }, [25, 25, 25])
  const limpia = limpiarFirma(rgba, 300, 150)
  assert.ok(limpia)
  assert.ok(limpia.ancho < 300 && limpia.alto < 150, 'recorta al contenido')
  assert.ok(limpia.ancho >= 180 && limpia.alto >= 6, 'no se come la tinta')
  assert.equal(limpia.rgba.length, limpia.ancho * limpia.alto * 4)
  assert.equal(pixel(limpia, 0, 0)[3], 0, 'la esquina es fondo')
  const centro = pixel(limpia, limpia.ancho >> 1, limpia.alto >> 1)
  assert.equal(centro[3], 255, 'el centro del trazo es tinta opaca')
  assert.ok(centro[0] < 60 && centro[1] < 60 && centro[2] < 60, 'la tinta negra sigue negra')
})

test('limpiarFirma: una sombra sobre el papel no se vuelve tinta', () => {
  // El papel va de claro a oscuro de izquierda a derecha.
  const rgba = lienzo(400, 200, (x, y) => {
    const g = 225 - (x / 400) * 95 + grano(x, y, 6)
    return [g, g, g]
  })
  pintar(rgba, 400, { x: 50, y: 100, ancho: 300, alto: 5 }, [20, 20, 30])
  const limpia = limpiarFirma(rgba, 400, 200)
  assert.ok(limpia)
  assert.ok(limpia.alto < 40, `se recortó al trazo, quedaron ${limpia.alto} px de alto`)
  assert.equal(pixel(limpia, 0, 0)[3], 0)
  assert.equal(pixel(limpia, limpia.ancho - 1, limpia.alto - 1)[3], 0)
  assert.equal(pixel(limpia, limpia.ancho >> 1, limpia.alto >> 1)[3], 255)
})

test('limpiarFirma: la tinta azul sigue azul y oscura; el papel amarillento no la tiñe', () => {
  const rgba = lienzo(300, 150, () => [230, 222, 195])
  pintar(rgba, 300, { x: 40, y: 70, ancho: 220, alto: 6 }, [40, 60, 170])
  const limpia = limpiarFirma(rgba, 300, 150)
  assert.ok(limpia)
  const [r, g, b] = pixel(limpia, limpia.ancho >> 1, limpia.alto >> 1)
  assert.ok(b > r && b > g, `quedó rgb(${r},${g},${b})`)
  assert.ok(0.299 * r + 0.587 * g + 0.114 * b <= 80, 'oscurecida')
})

test('limpiarFirma: un trazo tenue también llega a opaco', () => {
  const rgba = lienzo(300, 150, () => [215, 215, 215])
  pintar(rgba, 300, { x: 40, y: 70, ancho: 220, alto: 6 }, [150, 150, 150])
  const limpia = limpiarFirma(rgba, 300, 150)
  assert.ok(limpia)
  assert.equal(pixel(limpia, limpia.ancho >> 1, limpia.alto >> 1)[3], 255)
})

test('limpiarFirma: un trazo muy grueso sigue siendo tinta', () => {
  const rgba = lienzo(400, 300, () => [235, 235, 235])
  pintar(rgba, 400, { x: 60, y: 60, ancho: 260, alto: 120 }, [15, 15, 15])
  const limpia = limpiarFirma(rgba, 400, 300)
  assert.ok(limpia)
  assert.equal(pixel(limpia, limpia.ancho >> 1, limpia.alto >> 1)[3], 255)
})

test('limpiarFirma: los puntitos sueltos no estiran el recorte', () => {
  const rgba = lienzo(600, 400, () => [220, 220, 220])
  pintar(rgba, 600, { x: 200, y: 200, ancho: 200, alto: 5 }, [20, 20, 20])
  pintar(rgba, 600, { x: 5, y: 5, ancho: 1, alto: 1 }, [20, 20, 20])
  pintar(rgba, 600, { x: 590, y: 390, ancho: 1, alto: 1 }, [20, 20, 20])
  const limpia = limpiarFirma(rgba, 600, 400)
  assert.ok(limpia)
  assert.ok(limpia.ancho < 230 && limpia.alto < 30, `${limpia.ancho}×${limpia.alto}`)
})

test('limpiarFirma: la mesa que salió en el borde de la foto se va', () => {
  const rgba = lienzo(600, 400, (x) => (x < 120 ? [45, 40, 35] : [225, 225, 225]))
  pintar(rgba, 600, { x: 250, y: 200, ancho: 250, alto: 5 }, [20, 20, 20])
  const limpia = limpiarFirma(rgba, 600, 400)
  assert.ok(limpia)
  assert.ok(limpia.ancho < 280 && limpia.alto < 30, `${limpia.ancho}×${limpia.alto}`)
})

test('limpiarFirma: una imagen vacía devuelve null', () => {
  assert.equal(limpiarFirma(lienzo(100, 60, () => [255, 255, 255]), 100, 60), null)
  assert.equal(limpiarFirma(lienzo(100, 60, () => [128, 128, 128]), 100, 60), null)
  assert.equal(limpiarFirma(lienzo(100, 60, () => [0, 0, 0]), 100, 60), null, 'toda negra')
  const conGrano = lienzo(200, 100, (x, y) => {
    const g = 190 + grano(x, y, 10)
    return [g, g, g]
  })
  assert.equal(limpiarFirma(conGrano, 200, 100), null, 'papel con grano')
  assert.equal(limpiarFirma(lienzo(50, 50, () => [0, 0, 0, 0]), 50, 50), null, 'transparente')
  assert.equal(limpiarFirma(new Uint8ClampedArray(0), 0, 0), null)
  assert.equal(limpiarFirma(new Uint8ClampedArray(8), 10, 10), null, 'faltan píxeles')
})

test('limpiarFirma: la transparencia que ya trae se respeta, solo se recorta', () => {
  const rgba = lienzo(100, 60, () => [0, 0, 0, 0])
  pintar(rgba, 100, { x: 20, y: 20, ancho: 40, alto: 4 }, [200, 30, 40, 180])
  const limpia = limpiarFirma(rgba, 100, 60)
  assert.ok(limpia)
  assert.ok(limpia.ancho < 100)
  assert.deepEqual(pixel(limpia, limpia.ancho >> 1, limpia.alto >> 1), [200, 30, 40, 180])
  assert.ok(alfas(limpia).includes(0), 'deja un pequeño margen')
})

test('prepararFirma y prepararLogo rechazan más de 15 MB', async () => {
  const pesado = new File([new Uint8Array(15 * 1024 * 1024 + 1)], 'firma.png')
  await assert.rejects(prepararFirma(pesado), /15 MB/)
  await assert.rejects(prepararLogo(pesado), /15 MB/)
})

test('prepararFirma: lo que no se puede leer da el error en español', async () => {
  // En Node no existe createImageBitmap, igual que un formato que el navegador no decodifica.
  const archivo = new File([new Uint8Array(10)], 'firma.heic')
  await assert.rejects(prepararFirma(archivo), /No pudimos leer esa imagen/)
})
