/**
 * Pruebas de la lectura del pagador.
 *
 *   npx tsx src/features/admin/payer.test.ts
 *
 * Lo que más importa aquí es lo que NO se reconoce. Una cédula mal leída no
 * da error: manda al operador a buscar a alguien que no existe, o peor, a
 * alguien que existe y no es. Por eso hay tantos casos de "esto no es una
 * cédula" como de "esto sí".
 */
import { matchesPayer, payerDocument, readPayerHint } from './payer'

let failures = 0

function check(ok: boolean, label: string, detail: string) {
  if (!ok) failures++
  console.log(`${ok ? 'OK  ' : 'FALLA'} ${label.padEnd(34)} ${detail}`)
}

// ── Lo que manda el BNC ────────────────────────────────────────────────────
const bnc = readPayerHint('TELF.:584241875770 BANCO:0102 CED.:V30496254 PMPC pago ')

check(bnc?.document === '30496254', 'cédula del BNC', String(bnc?.document))
check(bnc?.documentLetter === 'V', 'la letra por separado', String(bnc?.documentLetter))
check(bnc?.phone === '584241875770', 'teléfono del BNC', String(bnc?.phone))
check(bnc?.bankCode === '0102', 'banco de origen', String(bnc?.bankCode))
check(bnc?.bankName === 'Banco de Venezuela', 'nombre del banco', String(bnc?.bankName))
check(payerDocument(bnc!) === 'V30496254', 'cédula vestida', String(payerDocument(bnc!)))

// El banco de origen cambia de una línea a otra: son los bancos de la gente.
const mercantil = readPayerHint('TELF.:584147413630 BANCO:0105 CED.:V28657986 PMPC quinta bar ')
check(mercantil?.bankName === 'Mercantil', 'otro banco de origen', String(mercantil?.bankName))
check(mercantil?.document === '28657986', 'otra cédula', String(mercantil?.document))

// ── Otras formas de escribir lo mismo ──────────────────────────────────────
const variantes: Array<[string, string | null, string | null, string]> = [
  ['C.I. 30.496.254', '30496254', null, 'cédula con puntos y C.I.'],
  ['CI: V-12345678 TLF 0424-1875770', '12345678', '584241875770', 'cédula y móvil con guiones'],
  ['PAGO MOVIL V-30496254', '30496254', null, 'sin palabra, con la letra'],
  ['RIF J-123456789 TRANSFERENCIA', '123456789', null, 'un RIF de empresa'],
  ['CEDULA 26484675 TELEFONO 04121234567', '26484675', '584121234567', 'palabras completas'],
  ['TELF.:4241875770', null, '584241875770', 'móvil sin 58 ni cero'],
]

for (const [texto, documento, telefono, label] of variantes) {
  const hint = readPayerHint(texto)
  check(
    (hint?.document ?? null) === documento && (hint?.phone ?? null) === telefono,
    label,
    `${hint?.document ?? '—'} · ${hint?.phone ?? '—'}`,
  )
}

// ── Lo que no es un pagador ────────────────────────────────────────────────
const nada: Array<[string | null | undefined, string]> = [
  ['PAGO A PROVEEDOR', 'una transferencia de salida'],
  ['DEPOSITO EN EFECTIVO 1500', 'un número suelto no es cédula'],
  ['COMISION MANTENIMIENTO 0102', 'el código de un banco no es cédula'],
  ['ABONO INTERESES', 'sin ningún dato'],
  [null, 'sin descripción'],
  [undefined, 'descripción indefinida'],
  ['', 'descripción vacía'],
]

for (const [texto, label] of nada) {
  check(readPayerHint(texto) === null, label, JSON.stringify(texto))
}

// Un teléfono a medias no vale: buscar con él no encuentra a nadie y hace
// creer que se buscó.
const corto = readPayerHint('TELF.:04241 CED.:V30496254')
check(corto?.phone === null, 'teléfono incompleto se descarta', String(corto?.phone))
check(corto?.document === '30496254', 'pero la cédula se queda', String(corto?.document))

// ── Cotejar con una persona del padrón ─────────────────────────────────────
check(
  matchesPayer(bnc, { document: '30496254', phone: '584129999999' }),
  'coincide por cédula',
  'aunque el teléfono sea otro',
)
check(
  matchesPayer(bnc, { document: '11111111', phone: '584241875770' }),
  'coincide por teléfono',
  'aunque la cédula sea otra',
)
check(
  matchesPayer(bnc, { document: 'V-30.496.254', phone: null }),
  'coincide con puntos y letra',
  'se compara por dígitos',
)
check(
  !matchesPayer(bnc, { document: '11111111', phone: '584129999999' }),
  'no coincide con otro paciente',
  'ni por una ni por otra',
)
check(!matchesPayer(null, { document: '30496254', phone: null }), 'sin pista no coincide', 'null')
check(
  !matchesPayer(bnc, { document: null, phone: null }),
  'paciente sin datos no coincide',
  'dos nulos no son iguales',
)

console.log(failures === 0 ? '\n=== TODO OK ===' : `\n=== ${failures} FALLOS ===`)
process.exit(failures === 0 ? 0 : 1)
