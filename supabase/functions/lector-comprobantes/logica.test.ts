/**
 * Pruebas de lo que el lector entiende de una captura.
 *
 *   npx tsx supabase/functions/lector-comprobantes/logica.test.ts
 */
import {
  ESQUEMA,
  esComprobante,
  extensionDe,
  leerFechaIso,
  leerMontoBs,
  leerMovil,
  leerReferencia,
  nombreDelBanco,
  normalizar,
  urlDeDescarga,
} from './logica.ts'
import type { Comprobante } from './logica.ts'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

console.log('El monto en bolívares')
for (const [texto, esperado] of [
  ['5.442,41', 5442.41],
  ['Bs. 5.442,41', 5442.41],
  ['Bs.5442,41', 5442.41],
  ['5,442.41', 5442.41],
  ['12.442,4', 12442.4],
  ['1.250', 1250],
  ['1250,5', 1250.5],
  ['56,96', 56.96],
  ['Bs 10.624,18', 10624.18],
  ['1.234.567,89', 1234567.89],
] as const) {
  comprueba(leerMontoBs(texto) === esperado, `«${texto}» → ${esperado}`, String(leerMontoBs(texto)))
}
comprueba(leerMontoBs(null) === null, 'sin monto → null')
comprueba(leerMontoBs('Bs.') === null, 'sin cifras → null')
comprueba(leerMontoBs('0,00') === null, 'cero → null')

console.log('La referencia')
comprueba(leerReferencia('Ref: 1158795645') === '1158795645', 'solo las cifras')
comprueba(leerReferencia('0012-3456-78') === '0012345678', 'con guiones')
comprueba(leerReferencia('12345') === null, 'menos de 6 cifras → null')
comprueba(leerReferencia(null) === null, 'sin referencia → null')

console.log('La fecha')
comprueba(leerFechaIso('2026-10-21') === '2026-10-21', 'AAAA-MM-DD')
comprueba(leerFechaIso('2026-02-31') === null, 'una fecha que no existe → null')
comprueba(leerFechaIso('21/10/2026') === null, 'otro formato → null (el modelo la da en ISO)')

console.log('El teléfono del pagador')
comprueba(leerMovil('0414-123.45.67') === '04141234567', 'con separadores')
comprueba(leerMovil('+58 424 7654321') === '04247654321', 'con +58')
comprueba(leerMovil('0424***4321') === null, 'enmascarado → null')
comprueba(leerMovil('0212-1234567') === null, 'un fijo → null')

console.log('El banco')
comprueba(nombreDelBanco('0134') === 'Banesco', 'por código')
comprueba(nombreDelBanco('BANESCO BANCO UNIVERSAL') === 'Banesco', 'por nombre, en mayúsculas')
comprueba(nombreDelBanco('Banco Mercantil, C.A. Banco Universal de Venezuela') === 'Mercantil', '«Venezuela» no lo confunde con el BDV')
comprueba(nombreDelBanco('BDV') === 'Banco de Venezuela', 'BDV')
comprueba(nombreDelBanco('Banco Nacional de Crédito (BNC)') === 'BNC Banco Nacional de Crédito', 'BNC')
comprueba(nombreDelBanco('Banco Raro') === 'Banco Raro', 'uno que no está en la lista, tal cual')
comprueba(nombreDelBanco('  ') === null, 'vacío → null')

console.log('Normalizar una lectura')
const leido: Comprobante = {
  es_comprobante: true,
  estado: 'exitosa',
  metodo: 'pago_movil',
  banco_origen: 'Banesco',
  banco_destino: '0191',
  referencia: '001158795645',
  monto_texto: 'Bs. 10.624,18',
  fecha: '2026-10-21',
  hora: '19:07',
  telefono_origen: '0424-1239037',
  documento_origen: 'V12345678',
  telefono_destino: '0412***4930',
  documento_destino: 'J-504967866',
  cuenta_destino_final: null,
}
const n = normalizar(leido)
comprueba(
  JSON.stringify(n) ===
    JSON.stringify({
      method: 'pago_movil',
      bank: 'Banesco',
      reference: '001158795645',
      amount_ves: 10624.18,
      paid_on: '2026-10-21',
      payer_phone: '04241239037',
    }),
  'todos los campos',
  JSON.stringify(n),
)
comprueba(normalizar({ ...leido, metodo: 'otro' }).method === null, 'otro método → null')
comprueba(esComprobante(leido) && !esComprobante({ hola: 1 }) && !esComprobante(null), 'la forma mínima')

console.log('El esquema')
comprueba(ESQUEMA.additionalProperties === false, 'cerrado')
comprueba(
  ESQUEMA.required.length === Object.keys(ESQUEMA.properties).length &&
    ESQUEMA.required.every((k) => k in ESQUEMA.properties),
  'todo obligatorio (structured outputs lo exige)',
)
// El 400 del primer intento real: `enum` con `type: ['string', 'null']`. Lo
// nulo va con `anyOf` y ningún `type` es una lista.
const propiedades = Object.entries(ESQUEMA.properties) as Array<[string, Record<string, unknown>]>
const malas = propiedades.filter(([, p]) => {
  const tipos = [p, ...((p.anyOf as Array<Record<string, unknown>> | undefined) ?? [])]
  return tipos.some((t) => Array.isArray(t.type)) || ('enum' in p && typeof p.type !== 'string')
})
comprueba(malas.length === 0, 'sin listas de tipos ni enum con nulo', malas.map(([k]) => k).join(', '))
comprueba(normalizar({ ...leido, metodo: 'no_se_ve' }).method === null, '«no_se_ve» en el método → null')

console.log('La descarga')
comprueba(
  urlDeDescarga('https://lookaside.fbsbx.com/whatsapp_business/attachments/?mid=123&ext=456', 'https://waba-v2.360dialog.io/') ===
    'https://waba-v2.360dialog.io/whatsapp_business/attachments/?mid=123&ext=456',
  'por el host de 360dialog, con la misma ruta',
)
comprueba(extensionDe('image/png') === 'png' && extensionDe('application/pdf') === 'pdf' && extensionDe('image/jpeg') === 'jpg', 'la extensión')

if (fallos > 0) {
  console.log(`\n${fallos} fallo(s)`)
  process.exit(1)
}
console.log('\nTodo bien')
