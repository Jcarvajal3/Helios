/**
 * Pruebas del orden de los resultados de la paleta.
 *
 *   npx tsx src/components/admin/paleta/resultados.test.ts
 *
 * El servidor encuentra; aquí se decide qué sale primero. Lo exacto antes que
 * lo que contiene, y nunca se esconde lo que el servidor ya encontró.
 */
import { interpretar } from './consulta'
import {
  atajosDeEspacios,
  buscarLocales,
  buscarPagos,
  delNumero,
  ordenarPersonas,
  parecidoDeNombre,
  personasAPedir,
} from './resultados'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

function persona(id: string, fullName: string | null, phone: string | null, document: string | null) {
  return { id, fullName, phone, document }
}

console.log('── El parecido de un nombre ──────────────────────────────────')
igual(parecidoDeNombre('María Pérez', 'maria perez'), 100, 'el nombre entero, sin tildes')
igual(parecidoDeNombre('María Pérez', 'mar') > parecidoDeNombre('Ana María', 'mar'), true, 'empezar por lo buscado pesa más que una palabra que empieza')
igual(parecidoDeNombre('Ana María', 'mar') > parecidoDeNombre('Omar Díaz', 'mar'), true, 'una palabra que empieza pesa más que un trozo en medio')
igual(parecidoDeNombre('María José Pérez', 'maria perez') > 0, true, 'cada palabra por su comienzo, aunque haya otra en medio')
igual(parecidoDeNombre('Omar', 'm'), 0, 'con una letra, solo cuentan los comienzos')

console.log('\n── Pacientes ──────────────────────────────────────────────────')
{
  // Con cifras, el servidor solo sabe que el teléfono las contiene; la paleta
  // pone primero la cédula o el teléfono que son exactamente eso.
  const delServidor = [
    persona('contiene', 'Ana', '584241112345', 'V9912345678'),
    persona('otra', 'Luis', '584149998877', '5555555'),
    persona('exacta', 'Eva', '584120000000', 'V12345678'),
  ]
  igual(
    ordenarPersonas(delServidor, interpretar('V-12.345.678')).map((p) => p.id),
    ['exacta', 'contiene', 'otra'],
    'la cédula exacta primero; lo que no casa se enseña al final, no se esconde',
  )
  const porTelefono = [
    persona('trozo', 'Ana', '584241234567', null),
    persona('mismo', 'Eva', '584141234567', null),
  ]
  igual(
    ordenarPersonas(porTelefono, interpretar('0414-1234567')).map((p) => p.id),
    ['mismo', 'trozo'],
    'el teléfono dictado con el cero encaja con el guardado con el 58',
  )
  const porNombre = [
    persona('omar', 'Omar Rivas', null, null),
    persona('maria', 'María Rivas', null, null),
    persona('ana', 'Ana María Díaz', null, null),
  ]
  igual(
    ordenarPersonas(porNombre, interpretar('mar')).map((p) => p.id),
    ['omar', 'maria', 'ana'],
    'por nombre, el orden del servidor, que ya ordena por parecido y sin tildes',
  )
  igual(personasAPedir(interpretar('mar')), 5, 'con un nombre se piden las que se enseñan')
  igual(personasAPedir(interpretar('0414-1234567')), 20, 'con cifras, más, para reordenarlas')
  igual(
    ordenarPersonas([persona('a', 'Ana', null, null), persona('b', 'Beatriz', null, null)], interpretar('xyz')).map((p) => p.id),
    ['a', 'b'],
    'a igualdad, el orden del servidor',
  )
}

console.log('\n── Clínicas ───────────────────────────────────────────────────')
{
  const locales = [
    { id: 'a', name: 'La Quinta Bar', legalName: 'Inversiones Quinta C.A.', taxId: 'J-40123456-7', handle: '@laquinta' },
    { id: 'b', name: 'Quinta Avenida', legalName: null, taxId: 'J-30999888-1', handle: null },
    { id: 'c', name: 'El Sótano', legalName: 'Sotano Group', taxId: null, handle: '@elsotano' },
  ]
  igual(buscarLocales(locales, interpretar('quinta')).map((l) => l.id), ['b', 'a'], 'el que empieza por lo buscado va antes')
  igual(buscarLocales(locales, interpretar('sotano')).map((l) => l.id), ['c'], 'sin tilde encuentra «Sótano»')
  igual(buscarLocales(locales, interpretar('inversiones')).map((l) => l.id), ['a'], 'también por la razón social')
  igual(buscarLocales(locales, interpretar('@elsot')).map((l) => l.id), ['c'], 'y por el paciente de la red social')
  igual(buscarLocales(locales, interpretar('J-40123456-7')).map((l) => l.id), ['a'], 'por RIF con letra y guiones')
  igual(buscarLocales(locales, interpretar('40123456')).map((l) => l.id), ['a'], 'por las cifras del RIF')
  igual(buscarLocales(locales, interpretar('401')).map((l) => l.id), [], 'con menos de cuatro cifras no se mira el RIF')
  igual(buscarLocales(locales, interpretar('e')).map((l) => l.id), ['c'], 'una letra: solo los comienzos de palabra')
  igual(buscarLocales(locales, interpretar('a'), 1).length, 1, 'el límite se respeta')
}

console.log('\n── Financiamientos ──────────────────────────────────────────────────')
{
  const filas = [{ orderNumber: 10430 }, { orderNumber: 1043 }, { orderNumber: null }]
  igual(delNumero(filas, 1043), [{ orderNumber: 1043 }], 'solo el de ese número, no los que lo contienen')
  igual(delNumero(filas, null), [], 'sin número, nada')
}

console.log('\n── Pagos reportados ──────────────────────────────────────────')
{
  const pagos = [
    { id: 'contiene', reference: '1649498000', createdAt: '2026-09-20T10:00:00Z' },
    { id: 'viejo', reference: '649498', createdAt: '2026-09-01T10:00:00Z' },
    { id: 'final', reference: '0102649498', createdAt: '2026-09-21T10:00:00Z' },
    { id: 'nuevo', reference: '649498', createdAt: '2026-09-22T10:00:00Z' },
    { id: 'otro', reference: '123456', createdAt: '2026-09-23T10:00:00Z' },
    { id: 'sin', reference: null, createdAt: '2026-09-24T10:00:00Z' },
  ]
  igual(
    buscarPagos(pagos, '649498').map((p) => p.id),
    ['nuevo', 'viejo', 'final', 'contiene'],
    'exacta (la más reciente antes), luego por el final, luego dentro',
  )
  igual(
    buscarPagos(pagos, '000123456').map((p) => p.id),
    ['otro'],
    'dictada larga: encaja la guardada que es su final',
  )
  igual(buscarPagos(pagos, null), [], 'sin referencia, nada')
  igual(buscarPagos(pagos, '649498', 2).length, 2, 'el límite se respeta')
}

console.log('\n── Atajos de los equipos ─────────────────────────────────────')
{
  const pantallas = [
    { id: 'c1', espacio: 'cobranza' },
    { id: 'c2', espacio: 'cobranza' },
    { id: 'c3', espacio: 'cobranza' },
    { id: 'k1', espacio: 'caja' },
    { id: 'k2', espacio: 'caja' },
    { id: 'r1', espacio: 'riesgo' },
    { id: 'g1', espacio: 'gerencia' },
    { id: 'd1', espacio: 'directorio' },
  ]
  const ids = (espacios: string[], max?: number) =>
    atajosDeEspacios(pantallas, espacios, max).map((p) => p.id)
  igual(ids(['cobranza', 'caja', 'riesgo', 'gerencia']), ['c1', 'k1', 'r1', 'g1', 'c2', 'k2'], 'repartidos: la primera de cada equipo, luego la segunda')
  igual(ids(['riesgo']), ['r1'], 'un equipo con una pantalla')
  igual(ids(['cobranza'], 2), ['c1', 'c2'], 'sin pasar del máximo')
  igual(ids([]), [], 'sin equipos, sin atajos')
}

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
