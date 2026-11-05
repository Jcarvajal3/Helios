import { test } from 'node:test'
import assert from 'node:assert/strict'
import { PDFDocument, StandardFonts } from 'pdf-lib'
import type { DatosRecipe, ImagenesRecipe, Medicamento } from '../modelo.ts'
import {
  fechaLatina,
  generarPdf,
  hayIndicaciones,
  nombreDelArchivo,
  sanearTexto,
} from './pdf.ts'

/** PNG de 1×1, transparente. */
const PNG_MINIMO = Uint8Array.from(
  Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    'base64',
  ),
)
const SIN_IMAGENES: ImagenesRecipe = { firma: null, logo: null }

function medicamento(parcial: Partial<Medicamento> = {}): Medicamento {
  return {
    medicamento: 'Amoxicilina 500 mg',
    presentacion: 'Cápsulas',
    cantidad: '21 cápsulas',
    indicacion: '',
    ...parcial,
  }
}

function datos(parcial: Partial<DatosRecipe> = {}): DatosRecipe {
  return {
    numero: 123,
    fecha: '2026-11-05',
    doctor: {
      nombre: 'Dra. Ana Lara',
      especialidad: 'Medicina interna',
      cedula: 'V-12.345.678',
      mpps: '98765',
      colegio: '21034',
      telefono: '0414-555.12.34',
      correo: 'consulta@ejemplo.com',
      direccion: 'Av. Francisco de Miranda',
      ciudad: 'Caracas',
      consultorio: 'Consultorio Lara',
    },
    paciente: { nombre: 'María Peña', documento: 'V-20.111.222', edad: '34', correo: '' },
    medicamentos: [medicamento()],
    indicaciones: '',
    ...parcial,
  }
}

async function abrir(bytes: Uint8Array) {
  return PDFDocument.load(bytes, { updateMetadata: false })
}

async function hojas(d: DatosRecipe, imagenes = SIN_IMAGENES): Promise<number> {
  return (await abrir(await generarPdf(d, imagenes))).getPageCount()
}

test('una hoja de media carta si no hay indicaciones', async () => {
  const pdf = await abrir(await generarPdf(datos(), SIN_IMAGENES))
  assert.equal(pdf.getPageCount(), 1)
  const { width, height } = pdf.getPage(0).getSize()
  assert.equal(width, 396)
  assert.equal(height, 612)
})

test('dos hojas si un medicamento trae indicación', async () => {
  const d = datos({ medicamentos: [medicamento({ indicacion: '1 cápsula cada 8 horas' })] })
  assert.equal(await hojas(d), 2)
})

test('dos hojas si solo hay indicaciones generales', async () => {
  assert.equal(await hojas(datos({ indicaciones: 'Reposo por 48 horas.' })), 2)
})

test('sin indicaciones no hay hoja 2, ni cuando el texto se queda vacío al sanearlo', async () => {
  const d = datos({ medicamentos: [medicamento({ indicacion: ' 😀 ' })], indicaciones: '  \n ' })
  assert.equal(hayIndicaciones(d), false)
  assert.equal(await hojas(d), 1)
})

test('20 medicamentos con textos de 500 caracteres pasan a más hojas', async () => {
  const largo = 'Tomar con abundante agua después de las comidas. '.repeat(11).slice(0, 500)
  const medicamentos = Array.from({ length: 20 }, (_, i) =>
    medicamento({
      medicamento: `${i + 1} ${largo}`,
      presentacion: largo,
      cantidad: largo,
      indicacion: largo,
    }),
  )
  const pdf = await abrir(await generarPdf(datos({ medicamentos, indicaciones: largo }), SIN_IMAGENES))
  assert.ok(pdf.getPageCount() > 4, `salieron ${pdf.getPageCount()} hojas`)
  for (const pagina of pdf.getPages()) assert.equal(pagina.getHeight(), 612)
})

test('un ítem que no cabe en una hoja entera se parte sin colgarse', async () => {
  const enorme = 'palabra '.repeat(4000)
  const d = datos({ medicamentos: [medicamento({ medicamento: enorme, indicacion: enorme })] })
  assert.ok((await hojas(d)) > 4)
})

test('una palabra más larga que la línea no falla', async () => {
  const d = datos({ medicamentos: [medicamento({ medicamento: 'x'.repeat(20000) })] })
  assert.ok((await hojas(d)) >= 1)
})

test('los datos larguísimos del membrete no se comen el cuerpo', async () => {
  const largo = 'Nombre muy largo de verdad '.repeat(200)
  const d = datos({
    doctor: {
      nombre: largo,
      especialidad: largo,
      cedula: largo,
      mpps: largo,
      colegio: largo,
      telefono: largo,
      correo: largo,
      direccion: largo,
      ciudad: largo,
      consultorio: largo,
    },
    paciente: { nombre: largo, documento: largo, edad: largo, correo: largo },
    medicamentos: Array.from({ length: 5 }, () => medicamento()),
  })
  assert.equal(await hojas(d), 1)
})

test('texto con emoji, ≥ y caracteres fuera de WinAnsi no falla', async () => {
  const raro = 'Fiebre ≥ 38 °C 🌡️ “ojo” – 中文 Ω ✓ ​\t µg ñ'
  const d = datos({
    numero: 7,
    doctor: { ...datos().doctor, nombre: `Dra. 😀 Ana ${raro}`, especialidad: raro, correo: raro },
    paciente: { nombre: raro, documento: raro, edad: raro, correo: raro },
    medicamentos: [
      { medicamento: raro, presentacion: raro, cantidad: raro, indicacion: raro },
    ],
    indicaciones: raro,
  })
  assert.equal(await hojas(d), 2)
})

test('sanearTexto normaliza lo común, quita lo demás y respeta el español', () => {
  assert.equal(sanearTexto('≥ 38 ≤ 40'), '>= 38 <= 40')
  assert.equal(sanearTexto('“hola” – adiós — fin…'), '"hola" - adiós - fin...')
  assert.equal(sanearTexto('¿Año? ¡Sí! 1º 2ª ÁÉÍÓÚ áéíóú Üü Ññ µg'), '¿Año? ¡Sí! 1º 2ª ÁÉÍÓÚ áéíóú Üü Ññ µg')
  assert.equal(sanearTexto('a 😀 b 中文 c'), 'a b c')
  assert.equal(sanearTexto('é'), 'é')
  assert.equal(sanearTexto('10 ㎎'), '10 mg')
  assert.equal(sanearTexto('uno\r\ndos\n\n\n\ntres'), 'uno\ndos\n\ntres')
  assert.equal(sanearTexto(null), '')
  assert.equal(sanearTexto(undefined), '')
})

test('todo lo que sanearTexto deja lo pueden escribir las tres fuentes', async () => {
  const doc = await PDFDocument.create()
  const fuentes = await Promise.all(
    [StandardFonts.Helvetica, StandardFonts.HelveticaBold, StandardFonts.TimesRomanItalic].map(
      (f) => doc.embedFont(f),
    ),
  )
  let todos = ''
  for (let cp = 0; cp <= 0xffff; cp++) {
    if (cp >= 0xd800 && cp <= 0xdfff) continue
    todos += String.fromCodePoint(cp)
  }
  const saneado = sanearTexto(todos).replaceAll('\n', ' ')
  for (const fuente of fuentes) assert.doesNotThrow(() => fuente.encodeText(saneado))
})

test('una imagen corrupta o de otro tipo se omite sin fallar', async () => {
  const cabeceraPng = PNG_MINIMO.slice(0, 8)
  const azar = Uint8Array.from({ length: 512 }, (_, i) => (i * 37 + 11) % 256)
  const conCabecera = (cabecera: number[] | Uint8Array) => {
    const b = new Uint8Array(cabecera.length + azar.length)
    b.set(cabecera)
    b.set(azar, cabecera.length)
    return b
  }
  const malas: Uint8Array[] = [
    new Uint8Array(0),
    azar,
    conCabecera(cabeceraPng),
    PNG_MINIMO.slice(0, 40),
    conCabecera([0xff, 0xd8, 0xff]),
    Uint8Array.from([0xff, 0xd8, 0xff, 0xe0]),
    conCabecera([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]),
  ]
  for (const mala of malas) {
    const bytes = await generarPdf(datos(), { firma: mala, logo: mala })
    assert.equal((await abrir(bytes)).getPageCount(), 1)
  }
})

test('sin firma ni logo sale igual; con ellas el documento las lleva', async () => {
  const sin = await generarPdf(datos(), SIN_IMAGENES)
  const con = await generarPdf(datos(), { firma: PNG_MINIMO, logo: PNG_MINIMO })
  assert.equal((await abrir(con)).getPageCount(), 1)
  assert.ok(con.length > sin.length)
})

test('los datos que faltan no dejan fallar el PDF', async () => {
  const vacio = {
    numero: null,
    fecha: '',
    doctor: {},
    paciente: {},
    medicamentos: [{}],
    indicaciones: undefined,
  } as unknown as DatosRecipe
  assert.equal(await hojas(vacio), 1)
  assert.equal(await hojas(datos({ medicamentos: [] })), 1)
})

test('metadatos del documento', async () => {
  const pdf = await abrir(await generarPdf(datos(), SIN_IMAGENES))
  assert.equal(pdf.getTitle(), 'Récipe 000123')
  assert.equal(pdf.getAuthor(), 'Dra. Ana Lara')
  assert.equal(pdf.getProducer(), 'RX · Helios')
  assert.equal(pdf.getCreator(), 'RX · Helios')
  const borrador = await abrir(await generarPdf(datos({ numero: null }), SIN_IMAGENES))
  assert.equal(borrador.getTitle(), 'Récipe')
})

test('fechaLatina', () => {
  assert.equal(fechaLatina('2026-11-05'), '05/11/2026')
  assert.equal(fechaLatina('2026-11-05T10:00:00Z'), '05/11/2026')
  assert.equal(fechaLatina(''), '')
  assert.equal(fechaLatina('hoy'), 'hoy')
})

test('nombreDelArchivo', () => {
  assert.equal(nombreDelArchivo(123), 'Recipe-000123.pdf')
  assert.equal(nombreDelArchivo(1234567), 'Recipe-1234567.pdf')
  assert.equal(nombreDelArchivo(null), 'Recipe-borrador.pdf')
})

test('hayIndicaciones', () => {
  assert.equal(hayIndicaciones(datos()), false)
  assert.equal(hayIndicaciones(datos({ indicaciones: 'Reposo' })), true)
  assert.equal(hayIndicaciones(datos({ medicamentos: [medicamento({ indicacion: 'Una al día' })] })), true)
})
