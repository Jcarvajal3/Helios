/**
 * Pruebas de los lectores y las reglas del alta (Nuevo financiamiento).
 *
 *   npx tsx src/features/merchant/registro.test.ts
 */
import { estrenarClaveDelAlta, claveDelAlta } from './claveDelAlta'
import type { Almacen } from './claveDelAlta'
import {
  coincideConLoPedido,
  diaDeLaSemana,
  esRechazoDeLaBase,
  fraseDelComprobante,
  leerElegibilidad,
  leerEstadoDelComprobante,
  leerFinanciamiento,
  leerMontoDeConsulta,
  leerReenvio,
  leerVistaPrevia,
  maximoParaFinanciar,
  pasoDelError,
  porcentajeDelServicio,
  reglaDelAtraso,
  rotuloDelServicio,
} from './registro'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function igual<T>(dio: T, esperado: T, titulo: string) {
  comprueba(JSON.stringify(dio) === JSON.stringify(esperado), titulo, `dio ${JSON.stringify(dio)}`)
}

function lanza(f: () => unknown, titulo: string) {
  try {
    f()
    comprueba(false, titulo, 'no lanzó')
  } catch {
    comprueba(true, titulo)
  }
}

const usd = (n: number) => `$${n.toFixed(2).replace('.', ',')}`

console.log('── elegibilidad ──────────────────────────────────────────────')
igual(
  leerElegibilidad({ estado: 'nuevo', min_charge_usd: 10, limite_usd: 350 }),
  { estado: 'nuevo', minChargeUsd: 10, limiteUsd: 350 },
  'paciente nuevo',
)
igual(
  leerElegibilidad({
    estado: 'disponible',
    disponible_usd: '212.40',
    min_charge_usd: 10,
    nombre_enmascarado: 'J*** P***',
    telefono_enmascarado: '0414-***-**67',
    email_enmascarado: 'j***@gmail.com',
  }),
  {
    estado: 'disponible',
    disponibleUsd: 212.4,
    minChargeUsd: 10,
    nombreEnmascarado: 'J*** P***',
    telefonoEnmascarado: '0414-***-**67',
    emailEnmascarado: 'j***@gmail.com',
  },
  'paciente conocido: numeric como texto se lee',
)
igual(
  leerElegibilidad({ estado: 'no_disponible', mensaje: 'No podemos financiar…', whatsapp_helios: null }),
  { estado: 'no_disponible', mensaje: 'No podemos financiar…', whatsappHelios: null },
  'no disponible sin WhatsApp configurado',
)
const noDisp = leerElegibilidad({ estado: 'no_disponible', motivo: 'mora', deuda_usd: 50 })
comprueba(
  !JSON.stringify(noDisp).includes('mora') && !JSON.stringify(noDisp).includes('50'),
  'no disponible: aunque la base mandara un motivo, no pasa al panel',
)
igual(
  leerElegibilidad({ estado: 'nuevo', limite_usd: 350 }),
  { estado: 'nuevo', minChargeUsd: 10, limiteUsd: 350 },
  'sin mínimo, el del contrato',
)
lanza(() => leerElegibilidad({ estado: 'raro' }), 'un estado desconocido es un fallo del contrato')
lanza(() => leerElegibilidad(null), 'una respuesta vacía también')
igual(maximoParaFinanciar({ estado: 'nuevo', minChargeUsd: 10, limiteUsd: 350 }), 350, 'nuevo: el límite')
igual(
  maximoParaFinanciar({ estado: 'no_disponible', mensaje: '', whatsappHelios: null }),
  null,
  'no disponible: no hay máximo',
)

console.log('\n── monto ─────────────────────────────────────────────────────')
const lim = { minimo: 10, maximo: 212.4 }
igual(leerMontoDeConsulta('100', lim, usd), { ok: true, usd: 100 }, 'un entero')
igual(leerMontoDeConsulta('45,50', lim, usd), { ok: true, usd: 45.5 }, 'con coma decimal')
igual(leerMontoDeConsulta('$ 45.50', lim, usd), { ok: true, usd: 45.5 }, 'con símbolo y punto')
igual(leerMontoDeConsulta('212,40', lim, usd), { ok: true, usd: 212.4 }, 'justo lo disponible')
igual(
  leerMontoDeConsulta('212,41', lim, usd),
  { ok: false, problema: 'El monto supera lo disponible para financiar ($212,40).' },
  'un céntimo de más',
)
igual(leerMontoDeConsulta('9,99', lim, usd), { ok: false, problema: 'El monto mínimo es $10,00.' }, 'bajo el mínimo')
igual(
  leerMontoDeConsulta('45,555', lim, usd),
  { ok: false, problema: 'El monto lleva como mucho dos decimales.' },
  'tres decimales',
)
comprueba(!leerMontoDeConsulta('', lim, usd).ok, 'vacío no vale')
comprueba(!leerMontoDeConsulta('cien', lim, usd).ok, 'texto no vale')
comprueba(!leerMontoDeConsulta('-20', lim, usd).ok, 'negativo no vale')
igual(leerMontoDeConsulta('0,1', { minimo: 0, maximo: null }, usd), { ok: true, usd: 0.1 }, '0,1 no se come por redondeo')

console.log('\n── vista previa ──────────────────────────────────────────────')
const vp = leerVistaPrevia({
  base_usd: 100,
  consumer_fee_pct: 20,
  consumer_fee_usd: 20,
  consumer_fee_vat_usd: '3.20',
  business_date: '2026-10-01',
  installments: [
    { sequence: 2, due_date: '2026-10-15', amount_usd: 61.6, financed_usd: 50 },
    { sequence: 1, due_date: '2026-10-08', amount_usd: 61.6, financed_usd: 50 },
  ],
  late_fee_usd: 2,
  late_fee_grace_days: 3,
  cabe: true,
  disponible_usd: null,
})
igual(vp.cuotas.map((c) => c.sequence), [1, 2], 'las cuotas salen en orden')
igual(vp.feeVatUsd, 3.2, 'el IVA del servicio')
igual(vp.disponibleUsd, null, 'nuevo: sin disponible')
comprueba(vp.cabe, 'cabe')
comprueba(!leerVistaPrevia({ cabe: false }).cabe, 'no cabe')
comprueba(leerVistaPrevia({}).cabe, 'sin el dato, se asume que cabe (la base vuelve a validar)')
igual(rotuloDelServicio(20), 'Servicio Helios 20% + IVA', 'el rótulo del servicio')
igual(rotuloDelServicio(12.5), 'Servicio Helios 12,5% + IVA', 'con decimales')
igual(
  reglaDelAtraso(vp, usd),
  'Si una cuota se paga con más de 3 días de atraso, se suma un cargo de $2,00 a esa cuota.',
  'la regla del atraso',
)
igual(reglaDelAtraso({ lateFeeUsd: null, lateFeeGraceDays: 3 }, usd), null, 'sin cifras no se inventa')
igual(diaDeLaSemana('2026-10-08'), 'jueves', 'el 8 de octubre de 2026 es jueves')
igual(diaDeLaSemana('2026-10-05'), 'lunes', 'el 5 de octubre de 2026 es lunes')

console.log('\n── financiamiento creado ─────────────────────────────────────')
const creado = leerFinanciamiento({
  id: 'c1',
  order_number: 1042,
  status: 'confirmed',
  created_at: '2026-10-01T14:00:00Z',
  business_date: '2026-10-01',
  merchant_sale_usd: 100,
  concept: 'Consulta',
  beneficiary_name: null,
  patient: { nombre: 'José Pérez', documento_enmascarado: 'V-****5678', email_enmascarado: 'j***@gmail.com' },
  installments: [
    { sequence: 1, due_date: '2026-10-08', amount_usd: 61.6 },
    { sequence: 2, due_date: '2026-10-15', amount_usd: 61.6 },
  ],
  breakdown: { base_usd: 100, consumer_fee_usd: 20, consumer_fee_vat_usd: 3.2 },
  receipt: { status: 'pendiente' },
  registered_by: 'Ana (Secretaria)',
  staff_commission_usd: 0.5,
})
igual(creado.orderNumber, 1042, 'número de orden')
igual(creado.patientName, 'José Pérez', 'nombre del paciente')
igual(creado.receipt, 'pendiente', 'estado del comprobante')
igual(creado.cuotas.length, 2, 'dos cuotas')
igual(creado.staffCommissionUsd, 0.5, 'la comisión')
igual(creado.feePct, 20, 'el porcentaje sale de las cifras')
igual(porcentajeDelServicio(0, 5), 20, 'sin base, el del contrato')
lanza(() => leerFinanciamiento({ order_number: 1 }), 'sin id no hay financiamiento que enseñar')
igual(leerEstadoDelComprobante('rebotado'), 'rebotado', 'estado conocido')
igual(leerEstadoDelComprobante('perdido'), null, 'estado desconocido es null')

comprueba(
  coincideConLoPedido(creado, { amountUsd: 100, document: 'V12345678' }),
  'coincide con lo pedido',
)
comprueba(
  !coincideConLoPedido(creado, { amountUsd: 90, document: 'V12345678' }),
  'otro monto: devolvió un alta anterior',
)
comprueba(
  !coincideConLoPedido(creado, { amountUsd: 100, document: 'V87654321' }),
  'otra cédula: devolvió un alta anterior',
)

igual(fraseDelComprobante('enviado', 'j***@gmail.com'), 'Comprobante enviado a j***@gmail.com.', 'enviado')
comprueba(fraseDelComprobante('rebotado', 'j***@gmail.com').includes('rebotó'), 'rebotado lo dice')
comprueba(fraseDelComprobante('pendiente', null).includes('al correo del paciente'), 'sin correo enmascarado')
comprueba(fraseDelComprobante('sin_configurar', 'x').includes('no está configurado'), 'sin configurar')

igual(leerReenvio({ ok: true, email_enmascarado: 'j***@gmail.com', status: 'pendiente' }), { emailEnmascarado: 'j***@gmail.com', status: 'pendiente' }, 'reenvío')
lanza(() => leerReenvio({ ok: false }), 'reenvío con ok=false')

console.log('\n── a qué paso lleva cada error ───────────────────────────────')
igual(pasoDelError('El monto mínimo es $10', true), 'monto', 'monto mínimo')
igual(pasoDelError('El monto supera lo disponible para financiar ($50)', false), 'monto', 'cupo')
igual(pasoDelError('Teléfono móvil inválido', true), 'datos', 'teléfono de un nuevo')
igual(pasoDelError('Correo inválido', false), null, 'correo de un conocido: no hay datos que corregir')
igual(pasoDelError('Falta el contacto de referencia', true), 'datos', 'referencia')
igual(pasoDelError('El titular debe ser mayor de edad. Si el paciente es menor…', true), 'datos', 'menor')
igual(pasoDelError('No podemos financiar a esta persona. Puede escribir…', true), 'cedula', 'no disponible')
igual(pasoDelError('La clínica está pausada', true), null, 'clínica pausada: nada que corregir')
igual(pasoDelError(undefined, true), null, 'sin mensaje')

comprueba(esRechazoDeLaBase({ code: '22023', message: 'x' }), 'un 22023 lo lanzó la base')
comprueba(esRechazoDeLaBase({ code: 'P0002', message: 'x' }), 'un P0002 también')
comprueba(!esRechazoDeLaBase(new TypeError('Failed to fetch')), 'un fallo de red no')
comprueba(!esRechazoDeLaBase({ code: '', message: 'x' }), 'sin código no')

console.log('\n── la clave de idempotencia ──────────────────────────────────')
function almacenDePrueba(): Almacen & { datos: Map<string, string> } {
  const datos = new Map<string, string>()
  return {
    datos,
    getItem: (k) => datos.get(k) ?? null,
    setItem: (k, v) => void datos.set(k, v),
    removeItem: (k) => void datos.delete(k),
  }
}
let n = 0
const generar = () => `clave-de-prueba-${String(++n).padStart(4, '0')}`
const almacen = almacenDePrueba()
const t0 = 1_000_000_000_000

const a = claveDelAlta(almacen, t0, generar)
const b = claveDelAlta(almacen, t0 + 60_000, generar)
igual(a, b, 'la misma clave tras recargar (doble clic, respuesta perdida)')
const c = estrenarClaveDelAlta(almacen, t0 + 120_000, generar)
comprueba(c !== a, 'tras un alta buena se estrena otra')
igual(claveDelAlta(almacen, t0 + 180_000, generar), c, 'y la nueva también se recuerda')
const d = claveDelAlta(almacen, t0 + 120_000 + 13 * 3600_000, generar)
comprueba(d !== c, 'pasadas 12 horas se descarta')
almacen.datos.set('helios.alta.idempotencia', '{roto')
comprueba(claveDelAlta(almacen, t0, generar) !== d, 'un apunte roto se ignora')
const sinAlmacen1 = claveDelAlta(null, t0, generar)
const sinAlmacen2 = claveDelAlta(null, t0, generar)
comprueba(sinAlmacen1 !== sinAlmacen2 && sinAlmacen1.length > 0, 'sin sessionStorage no revienta')
const reventon: Almacen = {
  getItem: () => {
    throw new Error('bloqueado')
  },
  setItem: () => {
    throw new Error('bloqueado')
  },
  removeItem: () => {},
}
comprueba(claveDelAlta(reventon, t0, generar).length > 0, 'un almacén que lanza tampoco revienta')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
