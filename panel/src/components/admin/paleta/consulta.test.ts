/**
 * Pruebas de lo que parece un texto tecleado en la paleta.
 *
 *   npx tsx src/components/admin/paleta/consulta.test.ts
 *
 * Son las formas en que la gente dicta los datos por teléfono. Si una deja de
 * reconocerse, la paleta busca donde no es y dice «Nada con…» de algo que sí
 * existe.
 */
import { agujaDeReferencia, gruposDe, interpretar, parteNacional } from './consulta'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

/** Lo que importa de una consulta, sin el texto. */
function lee(texto: string) {
  const c = interpretar(texto)
  return { forma: c.forma, personas: c.personas, orden: c.orden, referencia: c.referencia }
}

console.log('── Vacío y texto ─────────────────────────────────────────────')
igual(lee('   '), { forma: 'vacio', personas: null, orden: null, referencia: null }, 'solo espacios es vacío')
igual(lee('María'), { forma: 'texto', personas: 'María', orden: null, referencia: null }, 'un nombre va a pacientes tal cual, con su tilde')
igual(lee('m').personas, null, 'una sola letra no pregunta al servidor')
igual(interpretar('  Pagos   Reportados ').normal, 'pagos reportados', 'el texto normalizado, sin mayúsculas ni espacios de más')

console.log('\n── Número de orden ───────────────────────────────────────────')
igual(lee('#1043'), { forma: 'orden', personas: null, orden: 1043, referencia: null }, '«#1043»')
igual(lee('orden 1043').orden, 1043, '«orden 1043»')
igual(lee('Orden #1043').orden, 1043, '«Orden #1043»')
igual(lee('nº 1043').orden, 1043, '«nº 1043»')
igual(lee('#12').forma, 'orden', 'con almohadilla manda quien teclea, aunque sea corto')

console.log('\n── Referencia ────────────────────────────────────────────────')
igual(lee('ref 649498'), { forma: 'referencia', personas: null, orden: null, referencia: '649498' }, '«ref 649498»')
igual(lee('Referencia: 0102 6494 98').referencia, '0102649498', '«Referencia:» con espacios en medio')
igual(lee('ref 12').referencia, null, 'una referencia de dos cifras no se busca')
igual(agujaDeReferencia('000123649498'), '649498', 'al servidor van las seis últimas')
igual(agujaDeReferencia('6494'), '6494', 'si es más corta, entera')

console.log('\n── Teléfono ──────────────────────────────────────────────────')
igual(lee('0414-123 4567'), { forma: 'telefono', personas: '4141234567', orden: null, referencia: null }, '«0414-123 4567»: sin el cero, que no está en lo guardado')
igual(lee('+58 414 1234567').personas, '4141234567', '«+58 414 1234567»')
igual(lee('584141234567').personas, '4141234567', '«584141234567», como se guarda')
igual(lee('4141234567').forma, 'telefono', 'diez cifras que empiezan por 4')
igual(lee('(0414) 123-45-67').personas, '4141234567', 'con paréntesis y guiones')
igual(lee('04141').personas, '4141', 'un trozo de teléfono también busca')
igual(parteNacional('584141234567'), '4141234567', 'parteNacional quita el 58')
igual(parteNacional('04141234567'), '4141234567', 'parteNacional quita el cero')

console.log('\n── Cédula ────────────────────────────────────────────────────')
igual(lee('V-12.345.678'), { forma: 'cedula', personas: '12345678', orden: null, referencia: null }, '«V-12.345.678»: solo las cifras')
igual(lee('v12345678').personas, '12345678', '«v12345678»')
igual(lee('E 81234567').personas, '81234567', 'extranjera, «E 81234567»')
igual(lee('12.345.678').forma, 'cedula', 'con puntos y sin letra')
igual(lee('1.250').forma, 'numero', '«1.250» no es una cédula')

console.log('\n── RIF ───────────────────────────────────────────────────────')
igual(interpretar('J-12345678-9').forma, 'rif', '«J-12345678-9»')
igual(interpretar('J-12345678-9').digitos, '123456789', 'con su dígito verificador')

console.log('\n── Un número suelto ──────────────────────────────────────────')
igual(lee('1043'), { forma: 'numero', personas: '1043', orden: 1043, referencia: '1043' }, '«1043»: orden, referencia y trozo de cédula')
igual(lee('649498'), { forma: 'numero', personas: '649498', orden: 649498, referencia: '649498' }, '«649498»')
igual(lee('999').orden, null, 'menos de 1000 no es una orden')
igual(lee('0000999111').orden, null, 'con ceros delante no es una orden')
igual(lee('0000999111').referencia, '0000999111', 'pero sí una referencia')
igual(lee('1234567890').orden, null, 'diez cifras no son una orden')
igual(lee('123').personas, null, 'tres cifras no preguntan por pacientes')

console.log('\n── Los grupos de cada forma ──────────────────────────────────')
igual(gruposDe(interpretar('')), ['recientes', 'atajos'], 'sin texto: Recientes y los atajos')
igual(
  gruposDe(interpretar('maria')),
  ['pantallas', 'acciones', 'personas', 'locales', 'cifras', 'terminos'],
  'un nombre: el catálogo primero, luego pacientes y clínicas',
)
igual(
  gruposDe(interpretar('m')),
  ['pantallas', 'acciones', 'locales', 'cifras', 'terminos'],
  'una letra: sin pacientes',
)
igual(gruposDe(interpretar('#1043')), ['consumos'], '«#1043»: solo financiamientos')
igual(gruposDe(interpretar('ref 649498')), ['pagos'], '«ref 649498»: solo pagos')
igual(gruposDe(interpretar('0414-1234567')), ['personas'], 'un teléfono: pacientes')
igual(gruposDe(interpretar('V-12345678')), ['personas'], 'una cédula: pacientes')
igual(gruposDe(interpretar('J-12345678-9')), ['locales'], 'un RIF: clínicas')
igual(
  gruposDe(interpretar('1043')),
  ['consumos', 'pagos', 'personas', 'locales'],
  'un número suelto: de lo exacto a lo aproximado',
)
igual(gruposDe(interpretar('0000999111')), ['pagos', 'personas', 'locales'], 'sin orden posible, no se pregunta por financiamientos')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
