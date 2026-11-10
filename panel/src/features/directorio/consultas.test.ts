/**
 * Pruebas de `/consultas`, la variante B de la prueba A/B del directorio
 * (docs/06).
 *
 *   npx tsx src/features/directorio/consultas.test.ts
 *
 * Lo que se vigila: que el botón de B lleve al WhatsApp de Helios con «-B»
 * en el código (y que A no cambie), que sin número o sin código vaya
 * directo al médico, y que ningún texto de B diga «sin inicial», «0%» o las
 * fechas de las cuotas, ni use el vocabulario prohibido.
 */
import { enlaceDeWhatsApp, mensajeAHelios, mensajeInicial } from './directorio'
import {
  CONDICIONES_DE_CONSULTAS,
  INICIAL_DE_CONSULTAS_USD,
  PROHIBIDO_EN_CONSULTAS,
  TEXTOS_DE_CONSULTAS,
  TOPE_DE_CONSULTAS_USD,
  ZONA_EN_CONSULTAS,
  lugarEnConsultas,
} from './consultas'

let fallos = 0

// Con tipos anchos: las constantes son literales y el lint daría la comparación por sabida.
const igual = (a: unknown, b: unknown) => a === b

function comprueba(ok: boolean, titulo: string, detalle: unknown = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${JSON.stringify(detalle)}`}`)
}

const medico = { nombre: 'Dra. Ana Lara', whatsapp: '+584141234567', codigo: 'DIR-7K2P' }
const helios = '+584220000000'
const textoDe = (url: string) => decodeURIComponent(new URL(url).searchParams.get('text') ?? '')

console.log('── El mensaje a Helios ───────────────────────────────────────')
comprueba(
  mensajeAHelios('Dra. Ana Lara', 'DIR-7K2P', 'b') === 'Hola, quiero agendar una consulta con Dra. Ana Lara. (Código DIR-7K2P-B)',
  'en B, el código lleva «-B»',
  mensajeAHelios('Dra. Ana Lara', 'DIR-7K2P', 'b'),
)
comprueba(
  mensajeAHelios(' Dra. Ana Lara ', ' DIR-7K2P ', 'b').endsWith('(Código DIR-7K2P-B)'),
  'en B, sin espacios entre el código y la marca',
  mensajeAHelios(' Dra. Ana Lara ', ' DIR-7K2P ', 'b'),
)
comprueba(
  mensajeAHelios('Dra. Ana Lara', 'DIR-7K2P') === 'Hola, quiero agendar una consulta con Dra. Ana Lara. (Código DIR-7K2P)',
  'sin variante, el de siempre (A)',
)
comprueba(mensajeAHelios('Dra. Ana Lara', 'DIR-7K2P', 'a') === mensajeAHelios('Dra. Ana Lara', 'DIR-7K2P'), 'A explícita = sin variante')

console.log('── El enlace del botón ───────────────────────────────────────')
{
  const b = enlaceDeWhatsApp(medico, helios, 'b')
  comprueba(b.startsWith('https://wa.me/584220000000?text='), 'B va al WhatsApp de Helios', b)
  comprueba(textoDe(b).endsWith('(Código DIR-7K2P-B)'), 'B lleva el código con «-B»', textoDe(b))
  const a = enlaceDeWhatsApp(medico, helios)
  comprueba(textoDe(a).endsWith('(Código DIR-7K2P)'), 'A con número de Helios: sin «-B»', textoDe(a))
  const sinNumero = enlaceDeWhatsApp(medico, null, 'b')
  comprueba(sinNumero.startsWith('https://wa.me/584141234567?text='), 'B sin número de Helios: directo al médico', sinNumero)
  comprueba(textoDe(sinNumero) === mensajeInicial(medico.nombre), 'directo al médico, con su mensaje', textoDe(sinNumero))
  const sinCodigo = enlaceDeWhatsApp({ ...medico, codigo: null }, helios, 'b')
  comprueba(sinCodigo.startsWith('https://wa.me/584141234567?text='), 'B sin código: directo al médico', sinCodigo)
  const codigoVacio = enlaceDeWhatsApp({ ...medico, codigo: '  ' }, helios, 'b')
  comprueba(codigoVacio.startsWith('https://wa.me/584141234567?'), 'B con código en blanco: directo al médico', codigoVacio)
}

console.log('── Los textos de B ───────────────────────────────────────────')
comprueba(igual(INICIAL_DE_CONSULTAS_USD, 15), 'la inicial es $15', INICIAL_DE_CONSULTAS_USD)
comprueba(igual(TOPE_DE_CONSULTAS_USD, 60), 'el tope es $60', TOPE_DE_CONSULTAS_USD)
comprueba(
  `${TEXTOS_DE_CONSULTAS.h1.antes} ${TEXTOS_DE_CONSULTAS.h1.enfasis}` === '¡Consultas médicas por solo $15 de inicial!',
  'el titular',
  TEXTOS_DE_CONSULTAS.h1,
)
comprueba(TEXTOS_DE_CONSULTAS.entrada.startsWith('Paga el resto en 2 cuotas quincenales.'), 'la entrada', TEXTOS_DE_CONSULTAS.entrada)
comprueba(igual(CONDICIONES_DE_CONSULTAS, 'Inicial $15 y el resto en 2 cuotas quincenales'), 'la línea de la tarjeta', CONDICIONES_DE_CONSULTAS)
comprueba(!/\$\d+[,.]\d/.test(CONDICIONES_DE_CONSULTAS), 'la tarjeta no dice cuánto es cada cuota')
comprueba(igual(TEXTOS_DE_CONSULTAS.sello.cifra, '$15'), 'el sello dice $15', TEXTOS_DE_CONSULTAS.sello)
comprueba(TEXTOS_DE_CONSULTAS.titulo.includes('$15 de inicial'), 'el título de la pestaña', TEXTOS_DE_CONSULTAS.titulo)
{
  const todos = [
    TEXTOS_DE_CONSULTAS.titulo,
    TEXTOS_DE_CONSULTAS.descripcion,
    TEXTOS_DE_CONSULTAS.h1.antes,
    TEXTOS_DE_CONSULTAS.h1.enfasis,
    TEXTOS_DE_CONSULTAS.entrada,
    TEXTOS_DE_CONSULTAS.sello.cifra,
    TEXTOS_DE_CONSULTAS.sello.texto,
    CONDICIONES_DE_CONSULTAS,
    mensajeAHelios(medico.nombre, medico.codigo, 'b'),
  ]
  for (const t of todos) {
    const malo = PROHIBIDO_EN_CONSULTAS.find((re) => re.test(t))
    comprueba(!malo, `nada prohibido en «${t}»`, String(malo))
  }
  comprueba(PROHIBIDO_EN_CONSULTAS.some((re) => re.test('0% de inicial')), 'la lista atrapa «0% de inicial»')
  comprueba(PROHIBIDO_EN_CONSULTAS.some((re) => re.test('a los 14 y 28 días')), 'la lista atrapa «14 y 28 días»')
  comprueba(PROHIBIDO_EN_CONSULTAS.some((re) => re.test('Sin inicial')), 'la lista atrapa «Sin inicial»')
}

console.log('── La zona de cada tarjeta ───────────────────────────────────')
{
  comprueba(lugarEnConsultas({ codigo: 'DIR-P6U6', ciudad: 'Caracas' }) === 'San Bernardino', 'con zona: solo la zona')
  comprueba(lugarEnConsultas({ codigo: ' dir-p6u6 ', ciudad: null }) === 'San Bernardino', 'el código, sin importar mayúsculas ni espacios')
  comprueba(
    lugarEnConsultas({ codigo: 'DIR-YGRY', ciudad: null }) === 'Edificio Qvadra, Caracas',
    'sin zona: el edificio y «Caracas»',
  )
  comprueba(lugarEnConsultas({ codigo: 'DIR-ZZZZ', ciudad: 'Valencia' }) === 'Valencia', 'uno que no está en la lista: solo su ciudad')
  comprueba(lugarEnConsultas({ codigo: null, ciudad: '  ' }) === null, 'sin lista ni ciudad: nada')
  const especifico = /piso|oficina|ofi\b|consultorio|torre|nivel|local|\d/i
  const malas = Object.entries(ZONA_EN_CONSULTAS).filter(([, z]) => especifico.test(z))
  comprueba(malas.length === 0, 'ninguna zona lleva piso, oficina, consultorio, torre ni números', malas)
  const codigos = Object.keys(ZONA_EN_CONSULTAS)
  comprueba(codigos.every((c) => /^DIR-[A-Z0-9]{4}$/.test(c)), 'las claves son códigos de tarjeta', codigos)
}

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
