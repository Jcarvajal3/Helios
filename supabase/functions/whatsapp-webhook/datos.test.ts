/**
 * Pruebas de los datos del paciente en el chat del bot.
 *
 *   npx tsx supabase/functions/whatsapp-webhook/datos.test.ts
 */
import {
  FORMULARIO,
  diaCorto,
  dinero,
  faltantes,
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
comprueba(faltantes(l.paciente).length === 0, 'no falta nada', faltantes(l.paciente).join(', '))

const vacio = leerFormulario(FORMULARIO)
comprueba(vacio.etiquetado && faltantes(vacio.paciente).length === 12, 'el formulario sin llenar: falta todo')

const medio = leerFormulario('Nombres: Ana\nApellidos: Ruiz\nCorreo: ana@x.com\nCiudad:')
comprueba(medio.etiquetado, 'tres etiquetas bastan')
comprueba(
  faltantes(medio.paciente).includes('Teléfono') && !faltantes(medio.paciente).includes('Correo'),
  'dice lo que falta',
)

comprueba(!leerFormulario('José Pérez, 12/04/1990, masculino, 04141234567').etiquetado, 'texto libre: no es el formulario')

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
comprueba(lecturaDeLaIA([1, 2]) === null && lecturaDeLaIA('x') === null, 'algo que no es un objeto: null')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
