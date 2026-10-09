/**
 * Pruebas de lo que el bot le dice al paciente.
 *
 *   npx tsx supabase/functions/whatsapp-webhook/textos_paciente.test.ts
 */
import {
  MENU_PACIENTE,
  cuotasAPagar,
  fechaLarga,
  mensajeAyuda,
  mensajeComprobante,
  mensajeFinanciamientos,
  mensajeGenerico,
  mensajePagar,
  mensajePedirCedula,
  mensajeSinFinanciamientos,
} from './textos_paciente.ts'
import type { ResumenDelPaciente } from './textos_paciente.ts'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const base: ResumenDelPaciente = {
  nombre: 'Javier',
  tasa_bcv: 184.52,
  cuentas_de_cobro: '• Pago Móvil: Banesco · J-000000001 · 0414-1112233',
  pago_en_revision: false,
  financiamientos: [
    {
      orden: 1718,
      clinica: 'Clínica Test',
      consulta: 100,
      cuotas: [
        { sequence: 1, due_date: '2026-10-12', monto: 56.96, cargo_atraso: 0, vencida: false },
        { sequence: 2, due_date: '2026-10-19', monto: 56.96, cargo_atraso: 0, vencida: false },
      ],
    },
  ],
}

console.log('El menú')
comprueba(MENU_PACIENTE.length === 3 && MENU_PACIENTE.every((b) => b.title.length <= 20), 'tres botones de 20 caracteres o menos')
comprueba(
  mensajeGenerico('Javier').startsWith('💙 Gracias por escribirnos, Javier.') &&
    mensajeGenerico(null).startsWith('💙 Gracias por escribirnos.'),
  'el mensaje genérico, con y sin nombre',
)
comprueba(mensajeGenerico('Javier').length <= 1024, 'cabe en un mensaje con botones')

console.log('\nPagar cuota')
comprueba(cuotasAPagar(base).length === 1 && cuotasAPagar(base)[0].c.sequence === 1, 'sin vencidas: la próxima')
const pagar = mensajePagar(base)
comprueba(pagar.includes('💳 Tu próxima cuota'), 'el título', pagar)
comprueba(pagar.includes('* $56,96 — 12/10/2026 (#1718, Clínica Test)'), 'la cuota en formato venezolano', pagar)
comprueba(pagar.includes('Total a pagar: $56,96'), 'el total', pagar)
comprueba(pagar.includes('Bs 10.510,26 (tasa BCV del dólar 184,52)'), 'en bolívares de hoy', pagar)
comprueba(pagar.includes('Pago Móvil: Banesco') && pagar.includes('envíanos el comprobante'), 'cómo pagar')
comprueba(pagar.includes('Cómo pagar (en bolívares, por Pago Móvil o transferencia)'), 'solo en bolívares', pagar)

const vencida: ResumenDelPaciente = {
  ...base,
  pago_en_revision: true,
  financiamientos: [
    {
      ...base.financiamientos[0],
      cuotas: [
        { sequence: 1, due_date: '2026-10-12', monto: 56.96, cargo_atraso: 2, vencida: true },
        { sequence: 2, due_date: '2026-10-19', monto: 56.96, cargo_atraso: 0, vencida: false },
      ],
    },
  ],
}
const pagarVencida = mensajePagar(vencida)
comprueba(
  pagarVencida.includes('Tienes cuotas vencidas') &&
    pagarVencida.includes('+ cargo por atraso $2') &&
    pagarVencida.includes('Total a pagar: $58,96') &&
    pagarVencida.includes('pago en revisión'),
  'vencida: con el cargo, el total y el pago en revisión',
  pagarVencida,
)
comprueba(
  mensajePagar({ ...base, tasa_bcv: null }).includes('En bolívares, a la tasa BCV del dólar del día en que pagues.'),
  'sin tasa: lo dice',
)
comprueba(
  mensajePagar({ ...base, financiamientos: [] }).startsWith('No tienes cuotas pendientes, Javier'),
  'al día',
)

console.log('\nMis pagos en cuotas')
const ver = mensajeFinanciamientos(base)
comprueba(
  ver.includes('🩺 #1718 · Clínica Test (consulta $100)') &&
    ver.includes('* $56,96 — 19/10/2026') &&
    ver.includes('Total pendiente: $113,92') &&
    !ver.includes('Total pendiente de todos') && !ver.includes('Saldo'),
  'un pago en cuotas con su saldo',
  ver,
)
const dos = mensajeFinanciamientos({
  ...base,
  financiamientos: [
    ...base.financiamientos,
    { orden: 1720, clinica: 'Otra', consulta: 50, cuotas: [{ sequence: 2, due_date: '2026-10-20', monto: 28.48, cargo_atraso: 0, vencida: false }] },
  ],
})
comprueba(dos.includes('Total pendiente de todos: $142,40'), 'con dos, el saldo total', dos)
comprueba(mensajeFinanciamientos({ ...base, financiamientos: [] }).startsWith('No tienes pagos en cuotas activos'), 'sin activos')
comprueba(ver.startsWith('📋 Tus pagos en cuotas activos:'), 'el título de la lista', ver)
comprueba(fechaLarga('2026-10-12') === '12/10/2026', 'fecha larga')
comprueba(ver.includes('En bolívares hoy: Bs 21.020,52.'), 'el saldo en bolívares de hoy', ver)

console.log('\nEn euros')
const enEuros: ResumenDelPaciente = {
  ...base,
  tasa_bcv_eur: 215.3,
  financiamientos: [
    {
      orden: 1801,
      clinica: 'Clínica Euro',
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
comprueba(pagarEur.includes('* €56,96 — 14/10/2026 (#1801, Clínica Euro)'), 'la cuota en euros', pagarEur)
comprueba(pagarEur.includes('Total a pagar: €56,96'), 'el total en euros', pagarEur)
// 56,96 × 215,30 = 12.263,488 → 12.263,49
comprueba(pagarEur.includes('En bolívares hoy: Bs 12.263,49 (tasa BCV del euro 215,30).'), 'en bolívares a la tasa del euro', pagarEur)
comprueba(!pagarEur.includes('$') && !pagarEur.includes('dólar'), 'una orden en euros no habla de dólares', pagarEur)
comprueba(
  mensajePagar({ ...enEuros, tasa_bcv_eur: null }).includes('a la tasa BCV del euro del día en que pagues'),
  'sin tasa del euro: la del euro del día en que pague',
)

const eurVencida: ResumenDelPaciente = {
  ...enEuros,
  financiamientos: [
    {
      ...enEuros.financiamientos[0],
      cuotas: [{ sequence: 1, due_date: '2026-10-14', monto: 56.96, cargo_atraso: 2, vencida: true }],
    },
  ],
}
const pagarEurVencida = mensajePagar(eurVencida)
// 56,96 × 215,30 + 2 × 184,52 = 12.263,488 + 369,04 = 12.632,528 → 12.632,53
comprueba(
  pagarEurVencida.includes('* €56,96 + cargo por atraso $2') &&
    pagarEurVencida.includes('Total a pagar: €56,96 + $2') &&
    pagarEurVencida.includes('Bs 12.632,53 (tasa BCV del euro 215,30 · tasa BCV del dólar 184,52)'),
  'el cargo por atraso, en dólares y a la tasa del dólar',
  pagarEurVencida,
)
comprueba(
  mensajePagar({ ...eurVencida, tasa_bcv: null }).includes('a la tasa BCV del euro y del dólar del día en que pagues'),
  'falta la tasa del dólar para el cargo: a la del día',
)

const verEur = mensajeFinanciamientos(enEuros)
comprueba(
  verEur.includes('🩺 #1801 · Clínica Euro (consulta €100)') && verEur.includes('* €56,96 — 21/10/2026') && verEur.includes('Total pendiente: €113,92'),
  'mis pagos en cuotas, en euros',
  verEur,
)
const mezcla = mensajeFinanciamientos({ ...enEuros, financiamientos: [...base.financiamientos, ...enEuros.financiamientos] })
// 113,92 × 184,52 + 113,92 × 215,30 = 21.020,5184 + 24.526,976 = 45.547,4944
comprueba(
  mezcla.includes('Total pendiente: $113,92') &&
    mezcla.includes('Total pendiente: €113,92') &&
    mezcla.includes('Total pendiente de todos: $113,92 + €113,92') &&
    mezcla.includes('En bolívares hoy: Bs 45.547,49.'),
  'una en dólares y otra en euros: no se suman entre sí',
  mezcla,
)

console.log('\nVocabulario')
const PROHIBIDAS = /pr[ée]stamo|financ|cr[ée]dito/i
const todos = [
  ...MENU_PACIENTE.map((b) => b.title),
  mensajeGenerico('Javier'),
  mensajeSinFinanciamientos(),
  mensajeComprobante('Javier'),
  mensajeAyuda('Javier'),
  mensajePedirCedula(),
  pagar,
  pagarVencida,
  ver,
  dos,
  mensajeFinanciamientos({ ...base, financiamientos: [] }),
  mensajePagar({ ...base, financiamientos: [] }),
  pagarEur,
  pagarEurVencida,
  verEur,
  mezcla,
]
const conPalabras = todos.filter((t) => PROHIBIDAS.test(t))
comprueba(conPalabras.length === 0, 'ningún texto dice préstamo, financiamiento ni crédito', conPalabras.join(' | '))
const OTROS_MEDIOS = /zelle|efectivo|usdt|divisas/i
comprueba(!todos.some((t) => OTROS_MEDIOS.test(t)), 'ningún texto ofrece Zelle, efectivo ni divisas')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
