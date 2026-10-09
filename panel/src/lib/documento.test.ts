/**
 * Pruebas del documento en un formato.
 *
 *   npx tsx src/lib/documento.test.ts
 */
import {
  LETRAS_CEDULA,
  LETRAS_RIF,
  LETRAS_TITULAR,
  componerDocumento,
  documentoParaEnviar,
  documentoValido,
  limpiarNumero,
  partirDocumento,
  rifValido,
  tieneNumero,
} from './documento'

let fallos = 0
function igual(nombre: string, obtenido: unknown, esperado: unknown) {
  const ok = JSON.stringify(obtenido) === JSON.stringify(esperado)
  if (!ok) {
    fallos++
    console.error(`✗ ${nombre}\n  esperado: ${JSON.stringify(esperado)}\n  obtenido: ${JSON.stringify(obtenido)}`)
  } else {
    console.log(`✓ ${nombre}`)
  }
}

igual('los puntos se van', partirDocumento('V-12.345.678', LETRAS_CEDULA), { letra: 'V', numero: '12345678' })
igual('sin letra, la primera', partirDocumento('12345678', LETRAS_CEDULA), { letra: 'V', numero: '12345678' })
igual('el RIF guardado con guion', partirDocumento('J-123456789', LETRAS_TITULAR), { letra: 'J', numero: '123456789' })
igual('un pasaporte sin su P', partirDocumento('AB1234567', LETRAS_CEDULA), { letra: 'P', numero: 'AB1234567' })
igual('vacío', partirDocumento('', LETRAS_RIF), { letra: 'J', numero: '' })
igual('solo la letra', partirDocumento('E', LETRAS_CEDULA), { letra: 'E', numero: '' })
igual('el número solo admite dígitos', limpiarNumero('V', '12.345a678'), '12345678')
igual('y como mucho 9', limpiarNumero('J', '1234567890'), '123456789')
igual('el pasaporte, letras y dígitos', limpiarNumero('P', 'ab-123 456'), 'AB123456')
igual('se compone pegado', componerDocumento('E', '8.123.456'), 'E8123456')
igual('una cédula vale', documentoValido('V12345678', LETRAS_CEDULA), true)
igual('una cédula corta no', documentoValido('V123', LETRAS_CEDULA), false)
igual('un RIF J de 9', documentoValido('J123456789', LETRAS_TITULAR), true)
igual('un RIF J de 7 no', documentoValido('J1234567', LETRAS_TITULAR), false)
igual('un pasaporte', documentoValido('PAB12345', LETRAS_CEDULA), true)
igual('rif con V', rifValido('V123456789'), true)
igual('rif corto no', rifValido('J1234'), false)
igual('sin número no hay nada que enviar', documentoParaEnviar('J', LETRAS_RIF), '')
igual('con número, pegado', documentoParaEnviar('J-12345678-9', LETRAS_RIF), 'J123456789')
igual('solo la letra no tiene número', tieneNumero('J', LETRAS_RIF), false)

if (fallos > 0) {
  console.error(`\n${fallos} fallo(s).`)
  process.exit(1)
}
console.log('\nTodo bien.')
