/**
 * Pruebas de los lectores y las reglas del alta (Nuevo pago en cuotas).
 *
 *   npx tsx src/features/merchant/registro.test.ts
 */
import { estrenarClaveDelAlta, claveDelAlta } from './claveDelAlta'
import type { Almacen } from './claveDelAlta'
import {
  coincideConLoPedido,
  diaDeLaSemana,
  enBolivares,
  esRechazoDeLaBase,
  esperaAlPaciente,
  fraseDeLaEspera,
  fraseDelComprobante,
  leerConfirmacion,
  leerElegibilidad,
  leerEstadoDelComprobante,
  leerFinanciamiento,
  leerMontoDeConsulta,
  leerReenvio,
  leerTasasDeHoy,
  leerVistaPrevia,
  limitesEnMoneda,
  maximoParaFinanciar,
  tasaBcvDe,
  minutosRestantes,
  pasoDelError,
  porcentajeDelServicio,
  reglaDelAtraso,
  rotuloDelServicio,
  textoDelPlazo,
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
  leerElegibilidad({ estado: 'nuevo', min_charge_usd: 10, limite_usd: 150 }),
  { estado: 'nuevo', minChargeUsd: 10, limiteUsd: 150 },
  'paciente nuevo',
)
igual(
  leerElegibilidad({
    estado: 'disponible',
    disponible_usd: '212.40',
    min_charge_usd: 10,
    nombre: 'José Pérez',
    telefono: '0414-1234567',
    email: 'jose@gmail.com',
    nombre_enmascarado: 'J*** P***',
    telefono_enmascarado: '0414-***-**67',
    email_enmascarado: 'j***@gmail.com',
  }),
  {
    estado: 'disponible',
    disponibleUsd: 212.4,
    minChargeUsd: 10,
    nombre: 'José Pérez',
    telefono: '0414-1234567',
    email: 'jose@gmail.com',
  },
  'paciente conocido: numeric como texto se lee',
)
igual(
  leerElegibilidad({ estado: 'no_disponible', mensaje: 'Esta persona no puede pagar en cuotas…', whatsapp_helios: null }),
  { estado: 'no_disponible', mensaje: 'Esta persona no puede pagar en cuotas…', whatsappHelios: null },
  'no disponible sin WhatsApp configurado',
)
const noDisp = leerElegibilidad({ estado: 'no_disponible', motivo: 'mora', deuda_usd: 50 })
comprueba(
  !JSON.stringify(noDisp).includes('mora') && !JSON.stringify(noDisp).includes('50'),
  'no disponible: aunque la base mandara un motivo, no pasa al panel',
)
igual(
  leerElegibilidad({ estado: 'nuevo', limite_usd: 150 }),
  { estado: 'nuevo', minChargeUsd: 10, limiteUsd: 150 },
  'sin mínimo, el del contrato',
)
lanza(() => leerElegibilidad({ estado: 'raro' }), 'un estado desconocido es un fallo del contrato')
lanza(() => leerElegibilidad(null), 'una respuesta vacía también')
igual(maximoParaFinanciar({ estado: 'nuevo', minChargeUsd: 10, limiteUsd: 150 }), 150, 'nuevo: el límite')
igual(
  leerElegibilidad({ estado: 'no_disponible' }),
  {
    estado: 'no_disponible',
    mensaje: 'Esta persona no puede pagar en cuotas con Helios. Si tiene dudas, puede escribir a Helios.',
    whatsappHelios: null,
  },
  'sin texto de la base, el neutro del panel',
)
igual(
  maximoParaFinanciar({ estado: 'no_disponible', mensaje: '', whatsappHelios: null }),
  null,
  'no disponible: no hay máximo',
)

console.log('\n── monto ─────────────────────────────────────────────────────')
const lim = { minimo: 10, maximo: 212.4 }
igual(leerMontoDeConsulta('100', lim, usd), { ok: true, monto: 100 }, 'un entero')
igual(leerMontoDeConsulta('45,50', lim, usd), { ok: true, monto: 45.5 }, 'con coma decimal')
igual(leerMontoDeConsulta('$ 45.50', lim, usd), { ok: true, monto: 45.5 }, 'con símbolo y punto')
igual(leerMontoDeConsulta('212,40', lim, usd), { ok: true, monto: 212.4 }, 'justo lo disponible')
igual(
  leerMontoDeConsulta('212,41', lim, usd),
  { ok: false, problema: 'El monto supera lo disponible ($212,40).' },
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
igual(leerMontoDeConsulta('0,1', { minimo: 0, maximo: null }, usd), { ok: true, monto: 0.1 }, '0,1 no se come por redondeo')

console.log('\n── la moneda de la consulta ──────────────────────────────────')
const eur = (n: number) => `€${n.toFixed(2).replace('.', ',')}`
const tasas = leerTasasDeHoy({
  business_date: '2026-10-07',
  usd: { rate: '190.123456', effective_date: '2026-10-07' },
  eur: { rate: 214.1, effective_date: '2026-10-07' },
  usd_per_eur: '1.126',
})
igual(tasas, { businessDate: '2026-10-07', usd: 190.123456, eur: 214.1, usdPorEuro: 1.126 }, 'las tasas de hoy')
igual(
  leerTasasDeHoy({ business_date: '2026-10-07', usd: { rate: 190 }, eur: null, usd_per_eur: null }),
  { businessDate: '2026-10-07', usd: 190, eur: null, usdPorEuro: null },
  'sin tasa del euro: null, no cero',
)
igual(tasaBcvDe(tasas, 'EUR'), 214.1, 'la tasa del euro para una consulta en euros')
igual(tasaBcvDe(tasas, 'USD'), 190.123456, 'la del dólar para una en dólares')
igual(tasaBcvDe(undefined, 'USD'), null, 'sin tasas todavía')

igual(limitesEnMoneda({ minimo: 10, maximo: 150 }, 'USD', null), { minimo: 10, maximo: 150 }, 'en dólares, los de siempre (sin tasa no hace falta)')
// Como `helios_assert_charge_amount_in`: ceil(min / tasa, 2) y trunc(máx / tasa, 2).
igual(
  limitesEnMoneda({ minimo: 10, maximo: 150 }, 'EUR', 1.126),
  { minimo: 8.89, maximo: 133.21 },
  'en euros: el mínimo hacia arriba (8,8809 → 8,89) y el máximo truncado (133,214 → 133,21)',
)
igual(limitesEnMoneda({ minimo: 10, maximo: null }, 'EUR', 1.25), { minimo: 8, maximo: null }, 'exacto: 10 / 1,25 es €8,00, no €8,01')
igual(limitesEnMoneda({ minimo: 10, maximo: 149.97 }, 'EUR', 1.17), { minimo: 8.55, maximo: 128.17 }, 'otra tasa: 8,547 → 8,55 y 128,179 → 128,17')
igual(limitesEnMoneda({ minimo: 10, maximo: 150 }, 'EUR', null), null, 'euros sin tasa: no se puede seguir')
igual(limitesEnMoneda({ minimo: 10, maximo: 150 }, 'EUR', 0), null, 'una tasa en cero tampoco vale')

const limEur = limitesEnMoneda({ minimo: 10, maximo: 150 }, 'EUR', 1.126)
if (limEur) {
  igual(leerMontoDeConsulta('8,88', limEur, eur), { ok: false, problema: 'El monto mínimo es €8,89.' }, 'euros: bajo el mínimo, en euros')
  igual(leerMontoDeConsulta('8,89', limEur, eur), { ok: true, monto: 8.89 }, 'euros: justo el mínimo')
  igual(leerMontoDeConsulta('133,21', limEur, eur), { ok: true, monto: 133.21 }, 'euros: justo el máximo')
  igual(
    leerMontoDeConsulta('133,22', limEur, eur),
    { ok: false, problema: 'El monto supera lo disponible (€133,21).' },
    'euros: un céntimo de más, en euros',
  )
}
igual(enBolivares(100, 214.1), 21410, 'el equivalente en bolívares')
igual(enBolivares(56.96, 190.123456), 10829.43, 'redondeado al céntimo')
igual(enBolivares(100, null), null, 'sin tasa no se inventa')

console.log('\n── vista previa ──────────────────────────────────────────────')
const vp = leerVistaPrevia({
  base_usd: 100,
  consumer_fee_pct: 12,
  consumer_fee_usd: 12,
  consumer_fee_vat_usd: '1.92',
  business_date: '2026-10-01',
  installments: [
    { sequence: 2, due_date: '2026-10-15', amount_usd: 56.96, financed_usd: 50 },
    { sequence: 1, due_date: '2026-10-08', amount_usd: 56.96, financed_usd: 50 },
  ],
  late_fee_usd: 2,
  late_fee_grace_days: 3,
  cabe: true,
  disponible_usd: null,
})
igual(vp.cuotas.map((c) => c.sequence), [1, 2], 'las cuotas salen en orden')
igual(vp.feeVatUsd, 1.92, 'el IVA de la Comisión Helios')
igual(leerVistaPrevia({}).feePct, 12, 'sin porcentaje de la base, el 12 % de la regla')
igual(vp.disponibleUsd, null, 'nuevo: sin disponible')
comprueba(vp.cabe, 'cabe')
comprueba(!leerVistaPrevia({ cabe: false }).cabe, 'no cabe')
comprueba(leerVistaPrevia({}).cabe, 'sin el dato, se asume que cabe (la base vuelve a validar)')
igual(rotuloDelServicio(12), 'Comisión Helios 12% + IVA', 'el rótulo de la Comisión Helios')
igual(rotuloDelServicio(12.5), 'Comisión Helios 12,5% + IVA', 'con decimales')
igual(
  reglaDelAtraso(vp, usd),
  'Si una cuota se paga con más de 3 días de atraso, se suma un cargo de $2,00 a esa cuota.',
  'la regla del atraso',
)
igual(reglaDelAtraso({ lateFeeUsd: null, lateFeeGraceDays: 3 }, usd), null, 'sin cifras no se inventa')
igual(reglaDelAtraso({ lateFeeUsd: 0, lateFeeGraceDays: 3 }, usd), null, 'sin cargo por mora (en 0) no se promete ninguno')
igual(vp.moneda, 'USD', 'sin currency: dólares')
igual(vp.baseCur, 100, 'sin base_cur: la de dólares')
igual(vp.cuotas[0].amountCur, 56.96, 'sin amount_cur: el de dólares')
igual(vp.cuotas[0].amountVes, null, 'sin amount_ves: null')

const vpEur = leerVistaPrevia({
  currency: 'EUR',
  fx_usd_per_unit: 1.126,
  tasa_bcv: 214.1,
  base_usd: 112.6,
  base_cur: 100,
  consumer_fee_pct: 12,
  consumer_fee_usd: 13.51,
  consumer_fee_vat_usd: 2.16,
  consumer_fee_cur: 12,
  consumer_fee_vat_cur: 1.92,
  installments: [
    { sequence: 1, due_date: '2026-10-14', amount_usd: 64.14, amount_cur: 56.96, amount_ves: 12195.14 },
    { sequence: 2, due_date: '2026-10-21', amount_usd: 64.13, amount_cur: 56.96, amount_ves: 12195.14 },
  ],
  cabe: false,
  disponible_usd: 50,
  disponible_cur: 44.4,
})
igual(
  [vpEur.moneda, vpEur.tasaBcv, vpEur.baseCur, vpEur.feeCur, vpEur.feeVatCur, vpEur.disponibleCur],
  ['EUR', 214.1, 100, 12, 1.92, 44.4],
  'en euros: lo que se enseña, en euros',
)
igual(vpEur.baseUsd, 112.6, 'y lo del libro sigue en dólares')
igual(
  vpEur.cuotas.map((c) => [c.amountCur, c.amountVes]),
  [
    [56.96, 12195.14],
    [56.96, 12195.14],
  ],
  'cada cuota en euros y en bolívares de hoy',
)

igual(diaDeLaSemana('2026-10-08'), 'jueves', 'el 8 de octubre de 2026 es jueves')
igual(diaDeLaSemana('2026-10-05'), 'lunes', 'el 5 de octubre de 2026 es lunes')

console.log('\n── pago en cuotas creado ─────────────────────────────────────')
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
    { sequence: 1, due_date: '2026-10-08', amount_usd: 56.96 },
    { sequence: 2, due_date: '2026-10-15', amount_usd: 56.96 },
  ],
  breakdown: { base_usd: 100, consumer_fee_usd: 12, consumer_fee_vat_usd: 1.92 },
  receipt: { status: 'pendiente' },
  registered_by: 'Ana (Secretaria)',
  staff_commission_usd: 0.5,
})
igual(creado.orderNumber, 1042, 'número de orden')
igual(creado.patientName, 'José Pérez', 'nombre del paciente')
igual(creado.receipt, 'pendiente', 'estado del comprobante')
igual(creado.cuotas.length, 2, 'dos cuotas')
igual(creado.staffCommissionUsd, 0.5, 'la comisión')
igual(creado.feePct, 12, 'el porcentaje sale de las cifras')
igual(porcentajeDelServicio(0, 5), 12, 'sin base, el de la regla (12 %)')
lanza(() => leerFinanciamiento({ order_number: 1 }), 'sin id no hay orden que enseñar')
igual(leerEstadoDelComprobante('rebotado'), 'rebotado', 'estado conocido')
igual(leerEstadoDelComprobante('perdido'), null, 'estado desconocido es null')

igual([creado.moneda, creado.merchantSaleCur], ['USD', 100], 'sin currency: dólares, la misma cifra')

comprueba(
  coincideConLoPedido(creado, { amount: 100, moneda: 'USD', document: 'V12345678' }),
  'coincide con lo pedido',
)
comprueba(
  !coincideConLoPedido(creado, { amount: 90, moneda: 'USD', document: 'V12345678' }),
  'otro monto: devolvió un alta anterior',
)
comprueba(
  !coincideConLoPedido(creado, { amount: 100, moneda: 'USD', document: 'V87654321' }),
  'otra cédula: devolvió un alta anterior',
)
comprueba(
  !coincideConLoPedido(creado, { amount: 100, moneda: 'EUR', document: 'V12345678' }),
  'otra moneda: €100 no son los $100 de antes',
)

const enEuros = leerFinanciamiento({
  id: 'c9',
  order_number: 1050,
  status: 'confirmed',
  currency: 'EUR',
  merchant_sale_usd: 112.6,
  merchant_sale_cur: 100,
  tasa_bcv: 214.1,
  patient: { documento_enmascarado: 'V-****5678' },
  installments: [
    { sequence: 1, due_date: '2026-10-14', amount_usd: 64.14, amount_cur: 56.96, amount_ves: 12195.14 },
    { sequence: 2, due_date: '2026-10-21', amount_usd: 64.13, amount_cur: 56.96, amount_ves: 12195.14 },
  ],
  breakdown: {
    base_usd: 112.6,
    consumer_fee_usd: 13.51,
    consumer_fee_vat_usd: 2.16,
    base_cur: 100,
    consumer_fee_cur: 12,
    consumer_fee_vat_cur: 1.92,
  },
})
igual(
  [enEuros.moneda, enEuros.merchantSaleCur, enEuros.feeCur, enEuros.feeVatCur],
  ['EUR', 100, 12, 1.92],
  'una orden en euros se lee en euros',
)
igual(enEuros.feePct, 12, 'el porcentaje sale de las cifras en dólares (13,51 / 112,6)')
comprueba(
  coincideConLoPedido(enEuros, { amount: 100, moneda: 'EUR', document: 'V12345678' }),
  'en euros: coincide con los €100 pedidos (no con los $112,60 del libro)',
)
comprueba(
  !coincideConLoPedido(enEuros, { amount: 112.6, moneda: 'EUR', document: 'V12345678' }),
  'en euros: el monto del libro no es el pedido',
)

igual(fraseDelComprobante('enviado', 'j***@gmail.com'), 'Comprobante enviado a j***@gmail.com.', 'enviado')
comprueba(fraseDelComprobante('rebotado', 'j***@gmail.com').includes('rebotó'), 'rebotado lo dice')
comprueba(fraseDelComprobante('pendiente', null).includes('al correo del paciente'), 'sin correo enmascarado')
comprueba(fraseDelComprobante('sin_configurar', 'x').includes('no está configurado'), 'sin configurar')

igual(leerReenvio({ ok: true, email_enmascarado: 'j***@gmail.com', status: 'pendiente' }), { emailEnmascarado: 'j***@gmail.com', status: 'pendiente' }, 'reenvío')
lanza(() => leerReenvio({ ok: false }), 'reenvío con ok=false')

console.log('\n── a qué paso lleva cada error ───────────────────────────────')
igual(pasoDelError('El monto mínimo es $10', true), 'monto', 'monto mínimo')
igual(pasoDelError('El monto supera lo disponible para financiar ($50)', false), 'monto', 'cupo (redacción de antes)')
igual(pasoDelError('El monto supera lo disponible ($50)', false), 'monto', 'cupo')
igual(pasoDelError('Teléfono móvil inválido', true), 'datos', 'teléfono de un nuevo')
igual(pasoDelError('Correo inválido', false), null, 'correo de un conocido: no hay datos que corregir')
igual(pasoDelError('Falta el contacto de referencia', true), 'datos', 'referencia')
igual(pasoDelError('El titular debe ser mayor de edad. Si el paciente es menor…', true), 'datos', 'menor')
igual(pasoDelError('No podemos financiar a esta persona. Puede escribir…', true), 'cedula', 'no disponible (redacción de antes)')
igual(pasoDelError('Esta persona no puede pagar en cuotas con Helios.', true), 'cedula', 'no disponible')
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

// ── La confirmación del paciente (contrato §1.3.1) ─────────────────────────
console.log('\nLa confirmación del paciente')

const pendiente = leerFinanciamiento({
  id: 'c-1',
  order_number: 1042,
  status: 'pending',
  channel: 'whatsapp',
  expires_at: '2026-10-05T16:40:00-04:00',
  merchant_sale_usd: 100,
  breakdown: { base_usd: 100, consumer_fee_pct: 12, consumer_fee_usd: 12, consumer_fee_vat_usd: 1.92 },
  receipt: { status: 'sin_enviar', email_enmascarado: 'j***@gmail.com' },
  confirmation: {
    status: 'entregada',
    telefono_enmascarado: '0414-***-**67',
    sent_at: '2026-10-05T14:40:05-04:00',
    answered_at: null,
    resends_today: 1,
  },
  installments: [
    { sequence: 1, due_date: '2026-10-12', amount_usd: 56.96 },
    { sequence: 2, due_date: '2026-10-19', amount_usd: 56.96 },
  ],
})
comprueba(
  pendiente.status === 'pending' && esperaAlPaciente(pendiente) && pendiente.channel === 'whatsapp',
  'una orden pendiente espera al paciente',
)
comprueba(pendiente.receipt === 'sin_enviar', 'su comprobante está sin enviar')
comprueba(
  pendiente.confirmation?.status === 'entregada' &&
    pendiente.confirmation.telefonoEnmascarado === '0414-***-**67' &&
    pendiente.confirmation.resendsToday === 1,
  'lee la confirmación',
)
comprueba(pendiente.cuotas.length === 2, 'trae el plan de cuotas aunque no haya deuda')
comprueba(
  fraseDelComprobante('sin_enviar', 'j***@gmail.com') ===
    'El comprobante sale a j***@gmail.com en cuanto el paciente acepte.',
  'la frase del comprobante sin enviar',
)

const sinConfirmacion = leerFinanciamiento({
  id: 'c-2',
  order_number: 7,
  status: 'confirmed',
  merchant_sale_usd: 10,
})
comprueba(
  sinConfirmacion.confirmation === null &&
    sinConfirmacion.expiresAt === null &&
    sinConfirmacion.channel === 'panel' &&
    sinConfirmacion.declineReason === null,
  'una base sin la confirmación no rompe nada',
)
comprueba(!esperaAlPaciente(sinConfirmacion), 'confirmado no espera')

const rechazado = leerFinanciamiento({
  id: 'c-3',
  order_number: 8,
  status: 'declined',
  merchant_sale_usd: 10,
  decline_reason: 'no_disponible',
  decline_message: 'Esta persona no puede pagar en cuotas con Helios.',
})
comprueba(
  rechazado.declineReason === 'no_disponible' &&
    rechazado.declineMessage === 'Esta persona no puede pagar en cuotas con Helios.',
  'lee el motivo y el texto del rechazo',
)
comprueba(
  leerFinanciamiento({ id: 'c-4', order_number: 9, merchant_sale_usd: 1, decline_reason: 'otro' })
    .declineReason === null,
  'un motivo desconocido no se inventa',
)

comprueba(leerConfirmacion(null) === null, 'sin confirmación, null')
comprueba(
  leerConfirmacion({ status: 'estado_nuevo' })?.status === null,
  'un estado nuevo no se pinta como otro',
)

const ahora = Date.parse('2026-10-05T15:00:00-04:00')
comprueba(minutosRestantes('2026-10-05T16:40:00-04:00', ahora) === 100, '100 minutos restantes')
comprueba(minutosRestantes('2026-10-05T15:00:30-04:00', ahora) === 1, 'medio minuto redondea a 1')
comprueba(minutosRestantes('2026-10-05T14:00:00-04:00', ahora) === 0, 'vencida: 0')
comprueba(
  minutosRestantes(null, ahora) === 0 && minutosRestantes('no-es-fecha', ahora) === 0,
  'sin plazo: 0',
)
comprueba(textoDelPlazo(100) === '1 h 40 min', 'plazo: 1 h 40 min', textoDelPlazo(100))
comprueba(textoDelPlazo(120) === '2 h', 'plazo: 2 h', textoDelPlazo(120))
comprueba(textoDelPlazo(5) === '5 min' && textoDelPlazo(0) === 'menos de 1 min', 'plazo corto')

comprueba(
  fraseDeLaEspera(pendiente.confirmation).startsWith('Le enviamos un WhatsApp al 0414-***-**67'),
  'la frase de la espera nombra el teléfono',
  fraseDeLaEspera(pendiente.confirmation),
)
comprueba(
  pendiente.confirmation !== null &&
    fraseDeLaEspera({ ...pendiente.confirmation, status: 'fallida' }).startsWith('No pudimos escribirle'),
  'si falló, lo dice',
)
comprueba(fraseDeLaEspera(null).startsWith('Enviando un WhatsApp al paciente'), 'sin datos, enviando')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
