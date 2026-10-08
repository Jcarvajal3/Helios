/**
 * Pruebas de los datos del paciente en Nuevo financiamiento.
 *
 *   npx tsx src/features/merchant/paciente.test.ts
 */
import {
  MENSAJE_MENOR,
  PACIENTE_VACIO,
  cedulaLegible,
  cedulaParaEnviar,
  diasDelMes,
  correosCoinciden,
  edadEn,
  esCorreo,
  esFijo,
  esMovil,
  formatearFecha,
  formatearTelefono,
  hayDatosDePaciente,
  leerFechaDeNacimiento,
  pacienteParaEnviar,
  partesDeFecha,
  problemaDeCedula,
  problemaDeMovil,
  problemaDeNacimiento,
  problemasDelPaciente,
  sugerenciaDeCorreo,
  telefonoLegible,
  telefonoNacional,
} from './paciente'
import type { BorradorPaciente } from './paciente'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function igual<T>(dio: T, esperado: T, titulo: string) {
  comprueba(JSON.stringify(dio) === JSON.stringify(esperado), titulo, `dio ${JSON.stringify(dio)}`)
}

const HOY = '2026-09-30'

console.log('── cédula ────────────────────────────────────────────────────')
igual(cedulaParaEnviar('V', '12.345.678'), 'V12345678', 'quita los puntos')
igual(cedulaParaEnviar('E', ' 81234567 '), 'E81234567', 'extranjero con espacios')
igual(cedulaParaEnviar('V', '012345678'), 'V12345678', 'sin ceros delante')
igual(problemaDeCedula(''), 'Escribe el número de cédula.', 'vacía')
igual(problemaDeCedula('1234'), 'La cédula tiene muy pocos dígitos.', 'cuatro dígitos no bastan')
igual(problemaDeCedula('12345678'), null, 'ocho dígitos valen')
igual(problemaDeCedula('12345678901'), 'La cédula tiene demasiados dígitos.', 'once son demasiados')
igual(cedulaLegible('12345678'), '12.345.678', 'con puntos de millar')
igual(cedulaLegible('123456'), '123.456', 'una cédula antigua')

console.log('\n── fecha de nacimiento ───────────────────────────────────────')
igual(leerFechaDeNacimiento('12/04/1990', HOY), '1990-04-12', 'día/mes/año')
igual(leerFechaDeNacimiento('12-4-90', HOY), '1990-04-12', 'año de dos cifras es del siglo pasado')
igual(leerFechaDeNacimiento('01/01/05', HOY), '2005-01-01', 'año 05 es 2005')
igual(leerFechaDeNacimiento('12041990', HOY), '1990-04-12', 'los ocho dígitos seguidos')
igual(leerFechaDeNacimiento('1990-04-12', HOY), '1990-04-12', 'forma ISO')
igual(leerFechaDeNacimiento('31/02/1990', HOY), null, '31 de febrero no existe')
igual(leerFechaDeNacimiento('abc', HOY), null, 'texto no es una fecha')
igual(leerFechaDeNacimiento('29/02/2000', HOY), '2000-02-29', '29 de febrero bisiesto')

console.log('\n── edad ──────────────────────────────────────────────────────')
igual(edadEn('2008-09-30', HOY), 18, 'cumple 18 hoy')
igual(edadEn('2008-10-01', HOY), 17, 'cumple 18 mañana')
igual(edadEn('1990-04-12', HOY), 36, 'treinta y seis')
igual(edadEn('2000-02-29', '2018-02-28'), 17, 'nacido un 29/02: el 28/02 todavía no cumple')
igual(edadEn('2000-02-29', '2018-03-01'), 18, 'nacido un 29/02: cumple el 1/03')
igual(problemaDeNacimiento('2008-10-01', HOY), MENSAJE_MENOR, 'un menor no puede ser titular')
igual(problemaDeNacimiento('2008-09-30', HOY), null, 'con 18 recién cumplidos sí')
igual(problemaDeNacimiento('2027-01-01', HOY), 'La fecha de nacimiento es posterior a hoy.', 'fecha futura')
igual(problemaDeNacimiento('1900-01-01', HOY), 'Revisa el año: da más de 110 años.', 'más de 110 años')
comprueba(problemaDeNacimiento(null, HOY) !== null, 'sin fecha legible hay problema')

console.log('\n── teléfono ──────────────────────────────────────────────────')
igual(telefonoNacional('0414-123.45.67'), '04141234567', 'con guion y puntos')
igual(telefonoNacional('4141234567'), '04141234567', 'sin el cero')
igual(telefonoNacional('+58 414 123 4567'), '04141234567', 'con el código de país')
igual(telefonoNacional('584141234567'), '04141234567', 'E.164 sin el más')
igual(telefonoNacional('041412345'), null, 'le faltan dígitos')
comprueba(esMovil('04221234567'), 'el 0422 es móvil')
comprueba(esMovil('04261234567'), 'el 0426 es móvil')
comprueba(!esMovil('04151234567'), 'el 0415 no es móvil')
comprueba(!esMovil('02121234567'), 'un fijo no es móvil')
comprueba(esFijo('0212-123.45.67'), 'un fijo de Caracas')
igual(telefonoLegible('04141234567'), '0414-123.45.67', 'como se dicta')
igual(telefonoLegible('123'), '123', 'lo que no se lee, tal cual')
igual(problemaDeMovil('02121234567')?.startsWith('Tiene que ser un móvil'), true, 'un fijo no vale de móvil')
igual(problemaDeMovil('0414 1234567'), null, 'un móvil vale')

console.log('\n── correo ────────────────────────────────────────────────────')
comprueba(esCorreo('jose@gmail.com'), 'correo normal')
comprueba(esCorreo(' Jose.Perez@Empresa.com.ve '), 'con subdominios y espacios')
comprueba(!esCorreo('jose@gmail'), 'sin dominio de primer nivel')
comprueba(!esCorreo('jose gmail.com'), 'sin arroba')
comprueba(!esCorreo('jose@@gmail.com'), 'dos arrobas')
comprueba(correosCoinciden('Jose@Gmail.com ', 'jose@gmail.com'), 'coinciden sin mayúsculas ni espacios')
comprueba(!correosCoinciden('jose@gmail.com', 'jose@gmial.com'), 'una errata no coincide')
igual(sugerenciaDeCorreo('jose@gmial.com'), 'jose@gmail.com', 'gmial → gmail')
igual(sugerenciaDeCorreo('ana@hotmial.com'), 'ana@hotmail.com', 'hotmial → hotmail')
igual(sugerenciaDeCorreo('ana@yahooo.es'), 'ana@yahoo.es', 'yahooo.es → yahoo.es')
igual(sugerenciaDeCorreo('ana@gmail.com'), null, 'un dominio bueno no se toca')
igual(sugerenciaDeCorreo('ana@clinicasanjose.com'), null, 'un dominio propio lejano no se toca')
igual(sugerenciaDeCorreo('ana'), null, 'sin arroba no hay sugerencia')

console.log('\n── el formulario entero ──────────────────────────────────────')
const bueno: BorradorPaciente = {
  firstName: ' José  Luis ',
  lastName: 'Pérez',
  birthDate: '12/04/1990',
  sex: 'M',
  phone: '0414-123.45.67',
  email: 'Jose@Gmail.com',
  emailConfirm: 'jose@gmail.com',
  state: 'Miranda',
  city: 'Caracas',
  address: 'Los Palos Grandes, calle 4',
  occupation: '',
  referenceName: 'María Pérez',
  referencePhone: '0424 123 4567',
  referenceRelationship: 'Madre',
}
igual(problemasDelPaciente(bueno, HOY), {}, 'un paciente completo no tiene problemas')

const vacio = problemasDelPaciente(PACIENTE_VACIO, HOY)
comprueba(Object.keys(vacio).length === 13, 'vacío: todo menos la ocupación', `dio ${Object.keys(vacio).join(',')}`)
comprueba(vacio.occupation === undefined, 'la ocupación es opcional')

igual(
  problemasDelPaciente({ ...bueno, emailConfirm: 'jose@gmial.com' }, HOY).emailConfirm,
  'Los dos correos no coinciden.',
  'el correo repetido distinto',
)
igual(
  problemasDelPaciente({ ...bueno, birthDate: '01/10/2008' }, HOY).birthDate,
  MENSAJE_MENOR,
  'un menor de titular',
)
comprueba(
  problemasDelPaciente({ ...bueno, referencePhone: '04141234567' }, HOY).referencePhone !== undefined,
  'la referencia no puede ser el mismo teléfono',
)
igual(
  problemasDelPaciente({ ...bueno, referencePhone: '0212-555.12.34' }, HOY).referencePhone,
  undefined,
  'la referencia puede ser un fijo',
)

igual(
  pacienteParaEnviar('V12345678', bueno, HOY),
  {
    document: 'V12345678',
    first_name: 'José Luis',
    last_name: 'Pérez',
    birth_date: '1990-04-12',
    sex: 'M',
    phone: '04141234567',
    email: 'jose@gmail.com',
    state: 'Miranda',
    city: 'Caracas',
    address: 'Los Palos Grandes, calle 4',
    occupation: null,
    reference_name: 'María Pérez',
    reference_phone: '04241234567',
    reference_relationship: 'Madre',
  },
  'el p_patient del contrato, normalizado',
)

comprueba(!hayDatosDePaciente(PACIENTE_VACIO), 'vacío no tiene datos')
comprueba(hayDatosDePaciente({ ...PACIENTE_VACIO, city: 'x' }), 'un campo basta para tener datos')

console.log('── lo que se teclea, con formato ───────────────────────────────')
igual(formatearFecha('12'), '12', 'el día sin barra hasta que hay mes')
igual(formatearFecha('120'), '12/0', 'la barra aparece con la primera cifra del mes')
igual(formatearFecha('12041990'), '12/04/1990', 'ocho cifras seguidas')
igual(formatearFecha('120419901'), '12/04/1990', 'el año no pasa de cuatro cifras')
igual(formatearFecha('1/4/90'), '01/04/90', 'la barra tecleada completa el cero')
igual(formatearFecha('12/'), '12/', 'la barra tecleada se queda')
igual(formatearFecha('4'), '04/', 'un día de 4 a 9 se cierra solo')
igual(formatearFecha('123'), '12/03/', 'un mes de 2 a 9 se cierra solo')
igual(formatearFecha('12/1'), '12/1', 'un mes que empieza por 1 espera la segunda cifra')
igual(formatearFecha('1990-04-12'), '12/04/1990', 'la forma ISO pegada se da la vuelta')
igual(formatearFecha('ab12-04.1990'), '12/04/1990', 'letras fuera, separadores valen')
igual(formatearFecha(''), '', 'vacío')
for (const t of ['12/04/1990', '04/', '12/03/', '01/04/90', '12/0']) {
  igual(formatearFecha(t), t, `dar formato dos veces no cambia «${t}»`)
}
igual(leerFechaDeNacimiento(formatearFecha('12041990'), HOY), '1990-04-12', 'lo formateado se lee')

igual(formatearTelefono('04141234567'), '0414-123.45.67', 'once cifras')
igual(formatearTelefono('0414'), '0414', 'sin guion hasta que hay más')
igual(formatearTelefono('04141'), '0414-1', 'el guion con la quinta cifra')
igual(formatearTelefono('04141234'), '0414-123.4', 'el primer punto')
igual(formatearTelefono('414'), '0414', 'pone el 0 que falta')
igual(formatearTelefono('212'), '0212', 'también a un fijo')
igual(formatearTelefono('+58 414 123 4567'), '0414-123.45.67', 'quita el +58')
igual(formatearTelefono('+58'), '58', 'el +58 a medio teclear espera')
igual(formatearTelefono('041412345678'), '0414-123.45.67', 'más de once no caben')
igual(formatearTelefono('0414-123.45.67'), '0414-123.45.67', 'dar formato dos veces no cambia')
comprueba(esMovil(formatearTelefono('4141234567')), 'lo formateado es un móvil')

igual(partesDeFecha('12/04', HOY), { dia: 12, mes: 4, anio: null }, 'a medio teclear: día y mes')
igual(partesDeFecha('12/04/90', HOY), { dia: 12, mes: 4, anio: 1990 }, 'año de dos cifras entero')
igual(partesDeFecha('31/02/1990', HOY), { dia: 31, mes: 2, anio: 1990 }, 'un día que no existe trae sus partes')
igual(partesDeFecha('00/00', HOY), { dia: null, mes: null, anio: null }, 'el día 0 y el mes 0 no cuentan')
igual(partesDeFecha('', HOY), { dia: null, mes: null, anio: null }, 'vacío')
igual(diasDelMes(2, null), 29, 'febrero sin año aún puede tener 29')
igual(diasDelMes(2, 1990), 28, '1990 no es bisiesto')
igual(diasDelMes(2, 2000), 29, '2000 sí')
igual(diasDelMes(2, 1900), 28, '1900 no')
igual(diasDelMes(4, 1990), 30, 'abril, 30')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
