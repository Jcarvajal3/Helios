/**
 * Pruebas de lo que el bot le dice al paciente.
 *
 *   npx tsx supabase/functions/whatsapp-webhook/textos_paciente.test.ts
 */
import {
  BOTON_AYUDA,
  BOTON_PAGAR,
  FRASE_NIVEL,
  MAXIMO_CON_BOTONES,
  MENU_PACIENTE,
  bolivaresDeHoy,
  cuotasAPagar,
  diaLargo,
  fechaLarga,
  mensajeAyuda,
  mensajeCedulaNoCoincide,
  mensajeComprobante,
  mensajeFinanciamientos,
  mensajeGenerico,
  mensajePagar,
  mensajePedirCedula,
  mensajeSinFinanciamientos,
  mensajeYaPague,
  tienePendientes,
} from './textos_paciente.ts'
import type { ResumenDelPaciente } from './textos_paciente.ts'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

// Como lo manda `helios_payment_accounts_block`: sin el titular (2026-10-23).
const DATOS_DE_PAGO = '🏦 *Pago Móvil*\nBanco: BNC (0191)\nTeléfono: 0412-1714930\nRIF: J-50496786-6'

const base: ResumenDelPaciente = {
  nombre: 'María',
  tasa_bcv: 184.52,
  cuentas_de_cobro: '• Pago Móvil: Banesco · J-000000001 · 0414-1112233',
  datos_de_pago: DATOS_DE_PAGO,
  pago_en_revision: false,
  disponible_usd: 50,
  bloqueo: null,
  nivel: 1,
  nivel_nombre: 'Nivel 1',
  limite_usd: 150,
  financiamientos: [
    {
      orden: 1042,
      clinica: 'Consultorio 103',
      medico: 'Dra. Nadia Khabbaze',
      medico_ref: 'la Dra. Nadia Khabbaze',
      consulta: 100,
      cuotas: [
        { sequence: 1, due_date: '2026-10-26', monto: 56.96, cargo_atraso: 0, vencida: false },
        { sequence: 2, due_date: '2026-11-02', monto: 56.96, cargo_atraso: 0, vencida: false },
      ],
      pagadas: [],
    },
  ],
}

console.log('El menú')
comprueba(MENU_PACIENTE.length === 3 && MENU_PACIENTE.every((b) => b.title.length <= 20), 'tres botones de 20 caracteres o menos')
comprueba(
  MENU_PACIENTE.map((b) => b.title).join(' · ') === 'Pagar mi cuota · Mi saldo y cuotas · Hablar con alguien',
  'los títulos nuevos',
)
comprueba(MENU_PACIENTE[1].id === 'paciente:financiamientos', 'el id del segundo botón no cambia (menús ya enviados)')
comprueba(BOTON_PAGAR.title.length <= 20 && BOTON_AYUDA.title.length <= 20, 'los botones sueltos caben')
comprueba(
  mensajeGenerico('María').startsWith('💙 ¡Hola, María! Gracias por escribirnos.') &&
    mensajeGenerico(null).startsWith('💙 ¡Hola! Gracias por escribirnos.'),
  'el menú, con y sin nombre',
  mensajeGenerico(null),
)
comprueba(mensajeGenerico('María').length <= MAXIMO_CON_BOTONES, 'cabe en un mensaje con botones')

console.log('\nRespuestas cortas')
comprueba(mensajeComprobante('María').startsWith('📄 ¡Gracias, María! Recibimos tu comprobante.'), 'el comprobante')
comprueba(
  mensajeYaPague('María') ===
    '¡Gracias, María! Envíanos por aquí la foto del comprobante 📸 y escribe también el número de referencia del pago. Así lo confirmamos más rápido.',
  'ya pagué: la foto y la referencia',
  mensajeYaPague('María'),
)
comprueba(mensajeAyuda('María') === 'Listo, María. Alguien de nuestro equipo te escribe por aquí en breve 💙', 'hablar con alguien')
comprueba(mensajePedirCedula().startsWith('Para proteger tus datos'), 'pide la cédula y dice por qué')
comprueba(mensajeCedulaNoCoincide().includes('Revísala'), 'la cédula no coincide')

console.log('\nPagar mi cuota')
comprueba(cuotasAPagar(base).length === 1 && cuotasAPagar(base)[0].c.sequence === 1, 'sin vencidas: la próxima')
const pagar = mensajePagar(base)
comprueba(pagar.startsWith('💳 *Tu próxima cuota*\n$56,96 · vence el lunes 26/10\n'), 'el título y la cuota', pagar)
comprueba(pagar.includes('Consulta con la Dra. Nadia Khabbaze (orden #1042)'), 'nombra al médico, no a la clínica', pagar)
comprueba(!pagar.includes('Consultorio 103'), 'sin el nombre de la clínica', pagar)
// 56,96 × 184,52 = 10.510,2592
comprueba(pagar.includes('💵 *Monto en bolívares hoy: Bs 10.510,26*'), 'los bolívares de hoy', pagar)
comprueba(
  pagar.includes('Es el equivalente a $56,96 a la tasa BCV del dólar de hoy. Si pagas otro día, paga el equivalente a la tasa BCV de ese día.'),
  'dice que otro día es la tasa de ese día',
  pagar,
)
// La cuota y, como le quedan dos, el total de todo: los dos en el bloque de
// pago, antes de las cuentas (2026-10-21).
comprueba(
  pagar.split('Bs ').length === 3 && pagar.lastIndexOf('Bs ') < pagar.indexOf('🏦 *Pago Móvil*'),
  'los bolívares, solo en el bloque de pago',
  pagar,
)
// 113,92 × 184,52 = 21.020,5184
comprueba(
  pagar.includes('💰 *Para pagar todo de una vez hoy: Bs 21.020,52*\nSon tus 2 cuotas pendientes ($113,92).'),
  'el total de todo lo pendiente, para pagarlo de una vez',
  pagar,
)
comprueba(
  pagar.indexOf('Monto en bolívares hoy') < pagar.indexOf('Para pagar todo') &&
    pagar.indexOf('Para pagar todo') < pagar.indexOf('🏦 *Pago Móvil*'),
  'el total va después de la cuota y antes de las cuentas',
  pagar,
)
comprueba(
  !mensajePagar({ ...base, pago_en_revision: true }).includes('Para pagar todo'),
  'con un pago en revisión, sin el total de todo',
)
comprueba(
  !mensajePagar({ ...base, financiamientos: [{ ...base.financiamientos[0], cuotas: [base.financiamientos[0].cuotas[0]] }] }).includes(
    'Para pagar todo',
  ),
  'con una sola cuota pendiente, sin el total de todo',
)

// El céntimo: a esta tasa, una cuota da Bs 10.252,88 y el doble 20.505,76,
// pero las dos cuotas juntas son 20.505,77 (lo que cotiza la base).
const tasaRara = mensajePagar({ ...base, tasa_bcv: 180.001462 })
comprueba(
  tasaRara.includes('Monto en bolívares hoy: Bs 10.252,88*') && tasaRara.includes('hoy: Bs 20.505,77*'),
  'el total se redondea entero, no la cuota por dos',
  tasaRara,
)
// $1 × 100,004 = 100,00 y €1 × 110,004 = 110,00: 210,00 (juntos serían 210,01).
const mixto = bolivaresDeHoy({ ...base, tasa_bcv: 100.004, tasa_bcv_eur: 110.004 }, new Map([['USD', 1], ['EUR', 1]]))
comprueba(mixto === 210, 'cada moneda se redondea por separado, como la base', String(mixto))
// 1,005 × 1: en flotante sale 1,00; la base dice 1,01.
const medio = bolivaresDeHoy({ ...base, tasa_bcv: 1 }, new Map([['USD', 1.005]]))
comprueba(medio === 1.01, 'el medio céntimo se redondea hacia arriba, en exacto', String(medio))
comprueba(
  pagar.indexOf('Monto en bolívares') < pagar.indexOf('🏦 *Pago Móvil*') &&
    pagar.indexOf('🏦 *Pago Móvil*') < pagar.indexOf('📸 Cuando pagues') &&
    pagar.trimEnd().endsWith(FRASE_NIVEL),
  'el orden del bloque: monto, cuentas, comprobante, nivel',
  pagar,
)
comprueba(pagar.includes('Teléfono: 0412-1714930\nRIF: J-50496786-6'), 'las cuentas, cada dato en su línea', pagar)
comprueba(!pagar.includes('Titular'), 'sin el titular de la cuenta', pagar)
comprueba(
  mensajePagar({ ...base, datos_de_pago: undefined }).includes('• Pago Móvil: Banesco'),
  'sin `datos_de_pago` (base vieja): las cuentas de antes',
)

const vencida: ResumenDelPaciente = {
  ...base,
  pago_en_revision: true,
  financiamientos: [
    {
      ...base.financiamientos[0],
      cuotas: [
        { sequence: 1, due_date: '2026-10-26', monto: 56.96, cargo_atraso: 0, vencida: true },
        { sequence: 2, due_date: '2026-11-02', monto: 56.96, cargo_atraso: 0, vencida: true },
      ],
    },
  ],
}
const pagarVencida = mensajePagar(vencida)
comprueba(
  pagarVencida.startsWith('⚠️ *Tienes 2 cuotas pendientes*\n• $56,96 · venció el lunes 26/10 · Dra. Nadia Khabbaze\n') &&
    pagarVencida.includes('*Total: $113,92*') &&
    pagarVencida.includes('Aún estás a tiempo de ponerte al día 💙') &&
    pagarVencida.includes('🔎 Estamos revisando un pago que nos enviaste.'),
  'vencidas: la lista, el total, el ánimo y el pago en revisión',
  pagarVencida,
)
// Caso 3 (2026-10-29): con dos vencidas, la más antigua y todo de una vez.
// 56,96 × 184,52 = 10.510,2592; 113,92 × 184,52 = 21.020,5184
comprueba(
  pagarVencida.includes('Aún estás a tiempo de ponerte al día 💙 Puedes pagar las dos o empezar por la más antigua.') &&
    pagarVencida.includes(
      '💵 *Para pagar la más antigua hoy: Bs 10.510,26*\n' +
        '💰 *Para pagar todo de una vez hoy: Bs 21.020,52*\n' +
        'Es el equivalente a la tasa BCV del dólar de hoy. Si pagas otro día, paga el equivalente a la tasa BCV de ese día.',
    ) &&
    !pagarVencida.includes('Monto en bolívares hoy') &&
    pagarVencida.trimEnd().endsWith(FRASE_NIVEL),
  'dos vencidas: la más antigua y todo de una vez',
  pagarVencida,
)
const vencidasYFutura = mensajePagar({
  ...base,
  financiamientos: [
    { ...base.financiamientos[0], cuotas: vencida.financiamientos[0].cuotas },
    {
      ...base.financiamientos[0],
      orden: 1050,
      cuotas: [{ sequence: 1, due_date: '2026-11-09', monto: 20, cargo_atraso: 0, vencida: false }],
    },
  ],
})
// 133,92 × 184,52 = 24.710,9184
comprueba(
  vencidasYFutura.includes(
    '💵 *Para pagar la más antigua hoy: Bs 10.510,26*\n💵 *Para ponerte al día hoy: Bs 21.020,52*\n💰 *Para pagar todo de una vez hoy: Bs 24.710,92*',
  ),
  'dos vencidas y otra por vencer: la más antigua, ponerse al día y todo',
  vencidasYFutura,
)
comprueba(
  mensajePagar({ ...vencida, tasa_bcv: null }).includes('💵 *Monto en bolívares*'),
  'dos vencidas sin tasa: el bloque de un monto',
)
const unaVencida = mensajePagar({
  ...vencida,
  pago_en_revision: false,
  financiamientos: [{ ...base.financiamientos[0], cuotas: [{ sequence: 1, due_date: '2026-10-26', monto: 56.96, cargo_atraso: 2, vencida: true }] }],
})
comprueba(
  unaVencida.startsWith('⚠️ *Tienes 1 cuota pendiente*\n• $56,96 + cargo por atraso $2 · venció') && !unaVencida.includes('*Total'),
  'una vencida: en singular, con su cargo y sin total',
  unaVencida,
)
comprueba(
  mensajePagar({ ...base, tasa_bcv: null }).includes(
    '💵 *Monto en bolívares*\nPagas el equivalente a $56,96 a la tasa BCV del dólar del día en que pagues.',
  ),
  'sin tasa: lo dice',
)
comprueba(mensajePagar({ ...base, financiamientos: [] }).startsWith('No tienes cuotas pendientes, María'), 'al día')
comprueba(
  mensajePagar({ ...base, financiamientos: [{ ...base.financiamientos[0], medico: undefined, medico_ref: undefined }] }).includes(
    'Consulta con Consultorio 103',
  ),
  'sin médico (base vieja): la clínica',
)

console.log('\nMi saldo y cuotas')
const conPagada: ResumenDelPaciente = {
  ...base,
  financiamientos: [
    {
      ...base.financiamientos[0],
      cuotas: [{ sequence: 2, due_date: '2026-11-02', monto: 56.96, cargo_atraso: 0, vencida: false }],
      pagadas: [{ sequence: 1, due_date: '2026-10-26', monto: 56.96 }],
    },
  ],
}
const ver = mensajeFinanciamientos(conPagada)
comprueba(
  ver ===
    '📋 *Tu cuenta Helios*\n\n' +
      '🏅 *Nivel 1*\n' +
      '💰 *Saldo total: $150*\n' +
      '✨ *Disponible para tu próxima consulta: $50*\n\n' +
      '*Pagos en cuotas activos*\n' +
      '🩺 Dra. Nadia Khabbaze · orden #1042\n' +
      'Consulta: $100\n' +
      '✅ 1.ª cuota $56,96 · pagada\n' +
      '⏳ 2.ª cuota $56,96 · vence el lunes 02/11\n\n' +
      '*Por pagar: $56,96*\n\n' +
      '⭐ Si pagas a tiempo, puedes subir de nivel y aumentar tu saldo máximo.',
  'el mensaje entero: nivel, saldo total, disponible, activos y la frase de subir de nivel',
  ver,
)
comprueba(ver.length <= MAXIMO_CON_BOTONES && tienePendientes(conPagada), 'cabe con el botón «Pagar mi cuota»')
comprueba(!ver.includes('Bs '), 'sin bolívares (van solo junto a las cuentas)', ver)
comprueba(!ver.includes('Terminados') && !ver.includes('pagado completo'), 'sin los pagos terminados', ver)
const bloqueada = mensajeFinanciamientos({ ...vencida, disponible_usd: 0, bloqueo: 'cuota_vencida', pago_en_revision: false })
comprueba(
  bloqueada.includes('✨ *Disponible: $0*. Tienes una cuota pendiente; en cuanto la pagues, se reactiva.') &&
    bloqueada.includes('⚠️ 1.ª cuota $56,96 · venció el lunes 26/10'),
  'con una cuota vencida: lo disponible y por qué',
  bloqueada,
)
const sinNada = mensajeFinanciamientos({ ...base, financiamientos: [], disponible_usd: 150 })
comprueba(
  sinNada ===
    '📋 *Tu cuenta Helios*\n\n' +
      '🏅 *Nivel 1*\n' +
      '💰 *Saldo total: $150*\n' +
      '✨ *Disponible para tu próxima consulta: $150*\n\n' +
      '⭐ Si pagas a tiempo, puedes subir de nivel y aumentar tu saldo máximo.',
  'sin activos: solo el nivel, el saldo y la frase (sin «no tienes pagos»)',
  sinNada,
)
comprueba(!tienePendientes({ ...base, financiamientos: [] }), 'sin activos: sin botón «Pagar mi cuota»')
comprueba(
  bloqueada.startsWith('📋 *Tu cuenta Helios*\n\n🏅 *Nivel 1*\n💰 *Saldo total: $150*\n✨ *Disponible: $0*.'),
  'con una cuota vencida: el nivel y el saldo total también salen',
  bloqueada,
)
const sinNivel = mensajeFinanciamientos({ ...base, nivel: 0, nivel_nombre: 'Sin nivel', limite_usd: 0 })
comprueba(!sinNivel.includes('🏅') && !sinNivel.includes('Saldo total') && sinNivel.includes('Disponible'), 'nivel 0: ni nivel ni saldo total', sinNivel)
const baseVieja = mensajeFinanciamientos({ ...base, nivel: undefined, nivel_nombre: undefined, limite_usd: undefined })
comprueba(!baseVieja.includes('🏅') && !baseVieja.includes('Saldo total'), 'base vieja (sin nivel): no lo inventa', baseVieja)
comprueba(
  mensajeFinanciamientos({ ...base, nivel: 2, nivel_nombre: 'Nivel 2', limite_usd: 500 }).includes('🏅 *Nivel 2*\n💰 *Saldo total: $500*'),
  'otro nivel: su nombre y su tope',
)
comprueba(
  !mensajeFinanciamientos({ ...base, disponible_usd: undefined }).includes('Disponible'),
  'sin lo disponible (base vieja): no lo inventa',
)
comprueba(
  mensajeFinanciamientos({ ...base, pago_en_revision: true }).endsWith(
    '🔎 Tienes un pago en revisión: aún no aparece descontado.\n\n⭐ Si pagas a tiempo, puedes subir de nivel y aumentar tu saldo máximo.',
  ),
  'el pago en revisión va antes de la frase final',
)
comprueba(mensajeFinanciamientos({ ...base, pago_en_revision: true }).includes('pago en revisión'), 'el pago en revisión')
comprueba(fechaLarga('2026-10-12') === '12/10/2026' && diaLargo('2026-10-28') === 'miércoles 28/10', 'las fechas')

console.log('\nEn euros')
const enEuros: ResumenDelPaciente = {
  ...base,
  tasa_bcv_eur: 215.3,
  financiamientos: [
    {
      orden: 1801,
      clinica: 'Clínica Euro',
      medico: 'Dr. Hiram Padrón',
      medico_ref: 'el Dr. Hiram Padrón',
      moneda: 'EUR',
      consulta: 100,
      cuotas: [
        { sequence: 1, due_date: '2026-10-14', monto: 56.96, cargo_atraso: 0, vencida: false },
        { sequence: 2, due_date: '2026-10-21', monto: 56.96, cargo_atraso: 0, vencida: false },
      ],
    },
  ],
}
const pagarEur = mensajePagar(enEuros)
comprueba(pagarEur.startsWith('💳 *Tu próxima cuota*\n€56,96 · vence el miércoles 14/10\nConsulta con el Dr. Hiram Padrón'), 'la cuota en euros', pagarEur)
// 56,96 × 215,30 = 12.263,488 → 12.263,49
comprueba(
  pagarEur.includes('Monto en bolívares hoy: Bs 12.263,49*') && pagarEur.includes('a la tasa BCV del euro de hoy'),
  'en bolívares a la tasa del euro',
  pagarEur,
)
comprueba(!pagarEur.includes('$') && !pagarEur.includes('dólar'), 'una orden en euros no habla de dólares', pagarEur)
comprueba(
  mensajePagar({ ...enEuros, tasa_bcv_eur: null }).includes('a la tasa BCV del euro del día en que pagues'),
  'sin tasa del euro: la del euro del día en que pague',
)
const eurVencida = mensajePagar({
  ...enEuros,
  financiamientos: [{ ...enEuros.financiamientos[0], cuotas: [{ sequence: 1, due_date: '2026-10-14', monto: 56.96, cargo_atraso: 2, vencida: true }] }],
})
// 56,96 × 215,30 + 2 × 184,52 = 12.263,488 + 369,04 = 12.632,528 → 12.632,53
comprueba(
  eurVencida.includes('€56,96 + cargo por atraso $2') &&
    eurVencida.includes('Bs 12.632,53*') &&
    eurVencida.includes('Es el equivalente a €56,96 + $2 a la tasa BCV del euro y del dólar de hoy.'),
  'el cargo por atraso, en dólares y a la tasa del dólar',
  eurVencida,
)
const mezcla = mensajeFinanciamientos({ ...enEuros, financiamientos: [...base.financiamientos, ...enEuros.financiamientos] })
comprueba(mezcla.includes('*Por pagar: $113,92 + €113,92*'), 'una en dólares y otra en euros: no se suman entre sí', mezcla)

console.log('\nVocabulario')
const PROHIBIDAS = /pr[ée]stamo|financ|cr[ée]dito|\bfee\b/i
const todos = [
  ...MENU_PACIENTE.map((b) => b.title),
  mensajeGenerico('María'),
  mensajeSinFinanciamientos(),
  mensajeComprobante('María'),
  mensajeYaPague('María'),
  mensajeAyuda('María'),
  mensajePedirCedula(),
  mensajeCedulaNoCoincide(),
  pagar,
  pagarVencida,
  unaVencida,
  ver,
  bloqueada,
  sinNada,
  mensajePagar({ ...base, financiamientos: [] }),
  pagarEur,
  eurVencida,
  mezcla,
]
const conPalabras = todos.filter((t) => PROHIBIDAS.test(t))
comprueba(conPalabras.length === 0, 'ningún texto dice préstamo, financiamiento, crédito ni fee', conPalabras.join(' | '))
const OTROS_MEDIOS = /zelle|efectivo|usdt|divisas/i
comprueba(!todos.some((t) => OTROS_MEDIOS.test(t)), 'ningún texto ofrece Zelle, efectivo ni divisas')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
