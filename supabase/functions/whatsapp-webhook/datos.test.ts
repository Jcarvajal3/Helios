/**
 * Pruebas de los datos del paciente en el chat del bot.
 *
 *   npx tsx supabase/functions/whatsapp-webhook/datos.test.ts
 */
import {
  FORMULARIO,
  bolivares,
  diaCorto,
  dinero,
  dineroEn,
  enEuros,
  enPlural,
  faltantes,
  leerMoneda,
  monedaDe,
  nombreDeLaMoneda,
  horaCaracas,
  juntar,
  leerCedula,
  leerFormulario,
  leerMonto,
  leerMontoYConcepto,
  montoEs,
  lecturaDeLaIA,
  normalizarFecha,
  normalizarSexo,
  textoDeLaInteraccion,
} from './datos.ts'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

console.log('El formulario')

const lleno = `Nombres: José Luis
Apellidos: Pérez Gómez
Nacimiento (dd/mm/aaaa): 12/04/1990
Sexo (F/M): masculino
Teléfono: 0414-123.45.67
Correo: Jose@Gmail.com
Estado: Miranda
Ciudad: Caracas
Dirección: Los Palos Grandes, calle 3
Referencia (nombre): María Pérez
Teléfono de la referencia: 0212-555.12.34
Parentesco: Madre
Monto ($): 80,50
Concepto: Consulta + eco`

const l = leerFormulario(lleno)
comprueba(l.etiquetado, 'reconoce el formulario')
comprueba(
  l.paciente.first_name === 'José Luis' && l.paciente.last_name === 'Pérez Gómez',
  'nombres y apellidos tal cual',
)
comprueba(l.paciente.birth_date === '1990-04-12', 'la fecha dd/mm/aaaa', l.paciente.birth_date)
comprueba(l.paciente.sex === 'M', 'el sexo en palabras')
comprueba(l.paciente.phone === '0414-123.45.67', 'el teléfono tal cual (lo normaliza la base)')
comprueba(l.paciente.email === 'jose@gmail.com', 'el correo en minúsculas')
comprueba(l.paciente.reference_phone === '0212-555.12.34', 'el teléfono de la referencia')
comprueba(l.monto === 80.5 && l.concepto === 'Consulta + eco', 'monto y concepto', `${l.monto} ${l.concepto}`)
comprueba(l.moneda === 'USD', 'un formulario viejo («Monto ($)») es en dólares', String(l.moneda))
comprueba(faltantes(l.paciente).length === 0, 'no falta nada', faltantes(l.paciente).join(', '))

const vacio = leerFormulario(FORMULARIO)
comprueba(vacio.etiquetado && faltantes(vacio.paciente).length === 11, 'el formulario sin llenar: falta todo')
comprueba(!FORMULARIO.includes('Ciudad'), 'el formulario ya no pide la ciudad')
const sinCiudad = leerFormulario(lleno.replace(/^Ciudad:.*\n/m, ''))
comprueba(sinCiudad.etiquetado && faltantes(sinCiudad.paciente).length === 0, 'sin ciudad no falta nada')
comprueba(l.paciente.city === 'Caracas', 'si el médico escribe la ciudad, se lee')

const medio = leerFormulario('Nombres: Ana\nApellidos: Ruiz\nCorreo: ana@x.com\nCiudad:')
comprueba(medio.etiquetado, 'tres etiquetas bastan')
comprueba(
  faltantes(medio.paciente).includes('Teléfono') && !faltantes(medio.paciente).includes('Correo'),
  'dice lo que falta',
)

comprueba(!leerFormulario('José Pérez, 12/04/1990, masculino, 04141234567').etiquetado, 'texto libre: no es el formulario')

comprueba(FORMULARIO.includes('Monto:\nMoneda (dólares o euros):'), 'el formulario pregunta la moneda')
comprueba(vacio.moneda === null && vacio.monto === null, 'el formulario sin llenar: sin moneda ni monto')
comprueba(leerFormulario('Nombres: Ana\nApellidos: Ruiz\nMonto: 80\nMoneda (dólares o euros): euros').moneda === 'EUR', 'Moneda: euros')
comprueba(leerFormulario('Nombres: Ana\nApellidos: Ruiz\nMonto: 80\nMoneda: USD').moneda === 'USD', 'Moneda: USD')
comprueba(leerFormulario('Nombres: Ana\nApellidos: Ruiz\nMonto: €80').moneda === 'EUR', 'la moneda en el valor del monto')
comprueba(leerFormulario('Nombres: Ana\nApellidos: Ruiz\nMonto: 80 euros').monto === 80, 'el monto con la moneda escrita')
comprueba(leerFormulario('Nombres: Ana\nApellidos: Ruiz\nMonto: 80').moneda === null, 'sin moneda: queda sin decidir')
comprueba(
  leerFormulario('Nombres: Ana\nApellidos: Ruiz\nMonto: $80\nMoneda: euros').moneda === 'EUR',
  'la línea «Moneda» manda sobre el símbolo',
)
comprueba(leerFormulario('Moneda: euros').moneda === 'EUR', 'una corrección de solo la moneda')

const juntos = juntar({ first_name: 'Ana', email: 'viejo@x.com' }, { email: 'nuevo@x.com', city: '  ' })
comprueba(juntos.email === 'nuevo@x.com' && juntos.first_name === 'Ana' && juntos.city === undefined, 'juntar')

console.log('\nLos valores sueltos')
comprueba(normalizarFecha('1/2/1980') === '1980-02-01', 'fecha corta')
comprueba(normalizarFecha('1980-02-01') === '1980-02-01', 'fecha ISO')
comprueba(normalizarFecha('ayer') === 'ayer', 'una fecha rara queda tal cual')
comprueba(normalizarSexo('Mujer') === 'F' && normalizarSexo('f') === 'F', 'sexo F')
comprueba(normalizarSexo('otro') === 'otro', 'un sexo raro queda tal cual (lo rechaza la base)')
comprueba(leerMonto('$ 80') === 80 && leerMonto('nada') === null, 'leerMonto')

const mc = leerMontoYConcepto('80 consulta')
comprueba(mc?.monto === 80 && mc.concepto === 'consulta', '«80 consulta»')
const mc2 = leerMontoYConcepto('Consulta + eco $120,50')
comprueba(mc2?.monto === 120.5 && mc2.concepto === 'Consulta + eco', '«Consulta + eco $120,50»', JSON.stringify(mc2))
comprueba(leerMontoYConcepto('100')?.concepto === null, 'solo el monto')
comprueba(leerMontoYConcepto('consulta') === null, 'sin monto: null')

console.log('\nLa moneda')
const conMoneda: Array<[string, number, 'USD' | 'EUR' | null, string | null]> = [
  ['80 consulta', 80, null, 'consulta'],
  ['€80 consulta', 80, 'EUR', 'consulta'],
  ['80€ consulta', 80, 'EUR', 'consulta'],
  ['80 € consulta', 80, 'EUR', 'consulta'],
  ['80 euros consulta', 80, 'EUR', 'consulta'],
  ['80 EUR consulta', 80, 'EUR', 'consulta'],
  ['consulta 80 eur', 80, 'EUR', 'consulta'],
  ['80 euro', 80, 'EUR', null],
  ['$80 consulta', 80, 'USD', 'consulta'],
  ['80$ consulta', 80, 'USD', 'consulta'],
  ['80 dólares consulta', 80, 'USD', 'consulta'],
  ['80 dolares', 80, 'USD', null],
  ['80 USD consulta', 80, 'USD', 'consulta'],
  ['Consulta + eco €120,50', 120.5, 'EUR', 'Consulta + eco'],
  ['80 consulta en euros', 80, 'EUR', 'consulta'],
  ['consulta 80, en dólares', 80, 'USD', 'consulta'],
  ['80 eurocolor', 80, null, 'eurocolor'],
]
for (const [texto, monto, moneda, concepto] of conMoneda) {
  const r = leerMontoYConcepto(texto)
  comprueba(
    r?.monto === monto && r.moneda === moneda && r.concepto === concepto,
    `«${texto}»`,
    JSON.stringify(r),
  )
}

for (const [texto, moneda] of [
  ['dólares', 'USD'], ['Dolares', 'USD'], ['usd', 'USD'], ['$', 'USD'], ['en dólares', 'USD'], ['Dólares (USD)', 'USD'],
  ['euros', 'EUR'], ['EUR', 'EUR'], ['€', 'EUR'], ['en euros', 'EUR'], ['Euros (EUR)', 'EUR'], ['euro', 'EUR'],
] as const) {
  comprueba(leerMoneda(texto) === moneda, `leerMoneda «${texto}»`, String(leerMoneda(texto)))
}
comprueba(
  leerMoneda('80 consulta') === null && leerMoneda('hola') === null && leerMoneda('') === null && leerMoneda('dólares y euros') === null,
  'leerMoneda: lo que no es solo una moneda, null',
)

comprueba(dineroEn(56.96, 'EUR') === '€56,96' && dineroEn(1250.5, 'EUR') === '€1.250,50' && dineroEn(100, 'EUR') === '€100', 'euros al estilo venezolano')
comprueba(dineroEn(61.6, 'USD') === '$61,60', 'dólares con dineroEn')
comprueba(bolivares(55432.1) === 'Bs 55.432,10' && bolivares(100) === 'Bs 100,00' && bolivares(0.5) === 'Bs 0,50', 'bolívares con sus dos decimales')
comprueba(nombreDeLaMoneda('EUR') === 'euro' && nombreDeLaMoneda('USD') === 'dólar', 'el nombre de la moneda')
comprueba(enPlural('EUR') === 'euros' && enPlural('USD') === 'dólares', 'en plural')
comprueba(monedaDe('EUR') === 'EUR' && monedaDe('USD') === 'USD' && monedaDe(null) === 'USD' && monedaDe('x') === 'USD', 'monedaDe')
comprueba(enEuros(150, 1.17) === 128.2, 'disponible en euros: truncado al céntimo', String(enEuros(150, 1.17)))
comprueba(enEuros(117, 1.17) === 100, 'una división exacta no pierde un céntimo', String(enEuros(117, 1.17)))
comprueba(enEuros(100, 1.0857) === 92.1, 'nunca se redondea hacia arriba (92,1063… → 92,10)', String(enEuros(100, 1.0857)))

comprueba(leerCedula('V-12.345.678') === 'V12345678', 'cédula con guiones y puntos')
comprueba(leerCedula('e 1234567') === 'E1234567', 'cédula E')
comprueba(leerCedula('12345678') === 'V12345678', 'sin letra es V')
comprueba(leerCedula('hola') === null && leerCedula('12') === null, 'no es cédula')

comprueba(dinero(61.6) === '$61,60' && dinero(100) === '$100' && dinero(1.92) === '$1,92', 'dinero al estilo venezolano')
comprueba(montoEs(1250.5) === '1.250,50' && montoEs(1234567) === '1.234.567' && montoEs(99.999) === '100', 'miles y redondeo')
comprueba(diaCorto('2026-10-12') === 'lun 12/10', 'día corto', diaCorto('2026-10-12'))
comprueba(horaCaracas('2026-10-05T20:40:00Z') === '16:40', 'hora de Caracas', horaCaracas('2026-10-05T20:40:00Z'))

console.log('\nLo que devuelve la IA')
const json = '{"first_name":"Ana","birth_date":"12/04/1990","sex":"mujer","email":"Ana@X.com","monto":80,"concepto":"Consulta","atendido":null,"phone":null}'
comprueba(textoDeLaInteraccion({ status: 'completed', output_text: json }) === json, 'output_text')
comprueba(
  textoDeLaInteraccion({ status: 'completed', steps: [{ type: 'model_output', content: [{ type: 'text', text: json }] }] }) === json,
  'el texto dentro de steps',
)
comprueba(textoDeLaInteraccion({ status: 'failed', output_text: json }) === null, 'una interacción que no terminó: null')
comprueba(textoDeLaInteraccion(null) === null && textoDeLaInteraccion({ steps: [] }) === null, 'sin texto: null')

const ia = lecturaDeLaIA(JSON.parse(json))
comprueba(
  ia !== null &&
    ia.paciente.first_name === 'Ana' &&
    ia.paciente.birth_date === '1990-04-12' &&
    ia.paciente.sex === 'F' &&
    ia.paciente.email === 'ana@x.com' &&
    ia.paciente.phone === undefined &&
    ia.monto === 80 &&
    ia.concepto === 'Consulta' &&
    ia.atendido === null,
  'convierte y normaliza como el formulario',
  JSON.stringify(ia),
)
comprueba(
  lecturaDeLaIA({ first_name: 'Ana', clave_rara: 'x', monto: -5 })?.monto === null &&
    !('clave_rara' in (lecturaDeLaIA({ clave_rara: 'x' })?.paciente ?? {})),
  'ignora claves desconocidas y montos raros',
)
comprueba(ia?.moneda === null, 'la IA sin moneda: sin decidir')
comprueba(
  lecturaDeLaIA({ monto: 80, moneda: 'EUR' })?.moneda === 'EUR' &&
    lecturaDeLaIA({ monto: 80, moneda: 'usd' })?.moneda === 'USD' &&
    lecturaDeLaIA({ monto: 80, moneda: 'bolívares' })?.moneda === null,
  'la moneda de la IA: solo USD o EUR',
)
comprueba(lecturaDeLaIA([1, 2]) === null && lecturaDeLaIA('x') === null, 'algo que no es un objeto: null')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
