/**
 * Pruebas de los datos del pago escritos por el paciente (docs/03 §4.5).
 *
 *   npx tsx supabase/functions/whatsapp-webhook/datos_pago.test.ts
 */
import {
  faltanDatosDePago,
  formularioDePago,
  juntarDatosDePago,
  leerBanco,
  leerDatosDePago,
  leerMovil,
  leerReferenciaCompleta,
  nombrarCampos,
  quiereEscribirLosDatos,
} from './datos_pago.ts'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const igual = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b)

console.log('Cada dato')
comprueba(leerBanco('banesco') === 'Banesco', 'el banco por su nombre')
comprueba(leerBanco('0102') === 'Banco de Venezuela', 'por su código')
comprueba(leerBanco('BNC') === 'BNC Banco Nacional de Crédito', 'BNC')
comprueba(leerBanco('Banco de Venezuela') === 'Banco de Venezuela', 'el BDV por su nombre entero')
comprueba(leerBanco('el banco') === null, 'algo que no es un banco → null')
comprueba(leerMovil('0414-123.45.67') === '04141234567', 'un móvil con separadores')
comprueba(leerMovil('+58 416 1234567') === '04161234567', 'con +58')
comprueba(leerMovil('0212-1234567') === null, 'un fijo no es un Pago Móvil')
comprueba(leerReferenciaCompleta('001234567890') === '001234567890', 'una referencia completa')
comprueba(leerReferenciaCompleta('Ref: 0012 3456 7890') === '001234567890', 'con «Ref:» y espacios')
comprueba(leerReferenciaCompleta('123456') === null, 'con 6 cifras no está completa')
comprueba(leerReferenciaCompleta('pagué ayer 12345678') === null, 'una frase con un número no es una referencia')

console.log('El formulario')
comprueba(
  igual(
    leerDatosDePago('Banco desde el que pagaste: Banesco\nTeléfono desde el que pagaste: 0414-1234567\nReferencia completa: 001234567890'),
    { banco: 'Banesco', telefono: '04141234567', referencia: '001234567890' },
  ),
  'con etiquetas',
)
comprueba(
  igual(leerDatosDePago('001234567890\nMercantil\n04241234567'), {
    referencia: '001234567890',
    banco: 'Mercantil',
    telefono: '04241234567',
  }),
  'sin etiquetas y en cualquier orden',
)
comprueba(
  igual(leerDatosDePago('Banco: banco raro\nTeléfono: 0212-1234567\nReferencia: 00123456789'), { referencia: '00123456789' }),
  'lo que no se entiende no se guarda',
)
comprueba(igual(leerDatosDePago('hola, ya pagué'), {}), 'un mensaje cualquiera no trae datos')

console.log('Lo que falta')
const antes = leerDatosDePago('Banco: Banesco')
const despues = juntarDatosDePago(antes, leerDatosDePago('04141234567'))
comprueba(igual(faltanDatosDePago(despues), ['referencia']), 'se juntan los mensajes y falta la referencia')
comprueba(nombrarCampos(['telefono', 'referencia']) === 'el teléfono desde el que pagaste y la referencia completa', 'se nombra lo que falta')
comprueba(formularioDePago(['referencia']) === 'Referencia completa:', 'el formulario de lo que falta')
comprueba(formularioDePago().split('\n').length === 3, 'el formulario entero tiene tres líneas')

console.log('¿Quiere escribir los datos?')
for (const t of ['datos', 'Datos', 'No tengo captura', 'no tengo el comprobante']) {
  comprueba(quiereEscribirLosDatos(t), `«${t}»`)
}
for (const t of ['hola', 'mis datos están mal', 'ya pagué']) {
  comprueba(!quiereEscribirLosDatos(t), `«${t}» no`)
}

if (fallos > 0) {
  console.log(`\n${fallos} fallo(s)`)
  process.exit(1)
}
console.log('\nTodo bien')
