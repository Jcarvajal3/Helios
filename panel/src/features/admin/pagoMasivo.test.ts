/**
 * Pruebas del archivo de pago masivo del banco.
 *
 *   npx tsx src/features/admin/pagoMasivo.test.ts [salida.xlsm]
 *
 * Lo que se vigila: que solo entren las clínicas que el banco acepta (cuenta
 * de 20 dígitos, V/E/J/G, bolívares con tasa), que las de prueba no se paguen,
 * y que la plantilla salga llena sin perder la macro. Con una ruta, deja ahí
 * el archivo de muestra para abrirlo en Excel.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { strFromU8, unzipSync } from 'fflate'

import {
  bloqueoDelPagoMasivo,
  cuentaDelBanco,
  descripcionPorDefecto,
  idDelBeneficiario,
  llenarPlantilla,
  repartirPagoMasivo,
  serieDeExcel,
} from './pagoMasivo'
import type { ClinicaDelPagoMasivo, HojaDePagoMasivo } from './pagoMasivo'

let failures = 0

function check(ok: boolean, label: string, detail: string) {
  if (!ok) failures++
  console.log(`${ok ? 'OK  ' : 'FALLA'} ${label.padEnd(34)} ${detail}`)
}

function clinica(parcial: Partial<ClinicaDelPagoMasivo>): ClinicaDelPagoMasivo {
  return {
    merchantId: crypto.randomUUID(),
    merchantName: 'Clínica',
    isTest: false,
    email: 'clinica@ejemplo.com',
    hasPayoutAccount: true,
    bank: 'Banco Nacional de Crédito',
    accountHolder: 'Clínica Ejemplo, C.A.',
    holderDocument: 'J123456789',
    accountNumber: '01910000000000000001',
    pagoMovilPhone: null,
    lineas: 1,
    pendingUsd: 50,
    pendingUsdPart: 50,
    pendingEur: 0,
    pendingVes: 9_550.5,
    ...parcial,
  }
}

// ── Las reglas sueltas ────────────────────────────────────────────────────

check(cuentaDelBanco('0191-0000-00-0000000001') === '01910000000000000001', 'cuenta con guiones', 'se limpia')
check(cuentaDelBanco('0191000000000000001') === null, 'cuenta de 19 dígitos', 'no vale')
check(idDelBeneficiario('j-12345678-9') === 'J123456789', 'RIF con guiones', 'J123456789')
check(idDelBeneficiario('V12345678') === 'V12345678', 'cédula', 'V12345678')
check(idDelBeneficiario('P123456') === null, 'pasaporte', 'el banco no lo acepta')
check(idDelBeneficiario('V1234567890') === null, 'más de 10 caracteres', 'no vale')
check(serieDeExcel('2026-10-14') === 46309, 'serie de Excel', String(serieDeExcel('2026-10-14')))
check(descripcionPorDefecto('2026-10-14') === 'Pago Helios 14/10/2026', 'descripción', descripcionPorDefecto('2026-10-14'))

// ── Quién entra ───────────────────────────────────────────────────────────

const hoja: HojaDePagoMasivo = {
  todayDate: '2026-10-14',
  fxRateUsd: 191.01,
  fxRateEur: 222.4,
  debitAccount: null,
  merchants: [
    clinica({ merchantName: 'Dentro A', accountHolder: 'Odontología <Sonrisa> & Cía', pendingVes: 1000 }),
    clinica({ merchantName: 'Dentro B', holderDocument: 'v-8.765.432', email: 'mal-correo', pendingVes: 2000.25 }),
    clinica({ merchantName: 'Solo Pago Móvil', accountNumber: null, pagoMovilPhone: '04141234567' }),
    clinica({ merchantName: 'Sin cuenta', hasPayoutAccount: false, accountNumber: null, accountHolder: null }),
    clinica({ merchantName: 'Pasaporte', holderDocument: 'P1234567' }),
    clinica({ merchantName: 'Sin tasa', pendingVes: null }),
    clinica({ merchantName: 'De prueba', isTest: true }),
  ],
}

const opciones = { cuentaDebito: '01910000000000009999', fechaPago: '2026-10-14', descripcion: 'Pago Helios 14/10/2026' }
const reparto = repartirPagoMasivo(hoja, opciones)

check(reparto.dentro.length === 2, 'entran dos', reparto.dentro.map((d) => d.clinica.merchantName).join(', '))
check(reparto.fuera.length === 4, 'cuatro a mano', reparto.fuera.map((f) => f.clinica.merchantName).join(', '))
check(reparto.pruebas.length === 1, 'la de prueba aparte', String(reparto.pruebas.length))
check(
  reparto.fuera.find((f) => f.clinica.merchantName === 'Solo Pago Móvil')?.motivo.includes('Pago Móvil') === true,
  'dice que es Pago Móvil',
  '',
)
check(reparto.totalVes === 3000.25, 'total en bolívares', String(reparto.totalVes))
const a = reparto.dentro[0]
const b = reparto.dentro[1]
check(a.fila.referencia === 10140001 && b.fila.referencia === 10140002, 'referencias', `${a.fila.referencia} ${b.fila.referencia}`)
check(b.fila.idBeneficiario === 'V8765432', 'cédula limpia', b.fila.idBeneficiario)
check(b.fila.email === null, 'correo malo se omite', String(b.fila.email))

check(bloqueoDelPagoMasivo(opciones, '2026-10-14', 2) === null, 'se puede bajar', '')
check(bloqueoDelPagoMasivo({ ...opciones, fechaPago: '2026-10-13' }, '2026-10-14', 2) !== null, 'fecha pasada', 'bloquea')
check(bloqueoDelPagoMasivo({ ...opciones, cuentaDebito: '123' }, '2026-10-14', 2) !== null, 'cuenta a debitar corta', 'bloquea')
check(bloqueoDelPagoMasivo({ ...opciones, descripcion: 'x'.repeat(61) }, '2026-10-14', 2) !== null, 'descripción larga', 'bloquea')

// ── La plantilla, llena ───────────────────────────────────────────────────

const ruta = fileURLToPath(new URL('./plantilla-pago-masivo.xlsm', import.meta.url))
const plantilla = new Uint8Array(readFileSync(ruta))
const llena = llenarPlantilla(plantilla, reparto.dentro.map((d) => d.fila))
const antes = unzipSync(plantilla)
const despues = unzipSync(llena)

check(
  Object.keys(antes).join('|') === Object.keys(despues).join('|'),
  'mismas partes, mismo orden',
  `${Object.keys(despues).length} partes`,
)
const vba = antes['xl/vbaProject.bin']
const vba2 = despues['xl/vbaProject.bin']
check(
  vba.length === vba2.length && vba.every((x, i) => x === vba2[i]),
  'la macro intacta',
  `${vba.length} bytes`,
)
const sheet = strFromU8(despues['xl/worksheets/sheet2.xml'])
check(sheet.includes('<dimension ref="A1:AP4"/>'), 'dimensión', sheet.match(/<dimension[^>]*>/)?.[0] ?? '')
check(sheet.includes('<c r="A3" s="7"><v>46309</v></c>'), 'fecha como serie', '')
check(sheet.includes('<t>01910000000000000001</t>'), 'cuenta como texto', 'conserva el 0')
check(sheet.includes('<c r="D4" s="16"><v>2000.25</v></c>'), 'monto con decimales', '')
check(sheet.includes('Odontología &lt;Sonrisa&gt; &amp; Cía'), 'nombre escapado', '')
check(!sheet.includes('r="H4"'), 'sin correo, sin celda', '')

const salida = process.argv[2]
if (salida) {
  writeFileSync(salida, llena)
  console.log(`\nMuestra en ${salida}`)
}

console.log(failures === 0 ? '\nTodo en verde.' : `\n${failures} falla(s).`)
process.exit(failures === 0 ? 0 : 1)
