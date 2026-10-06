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
comprueba(pagar.includes('Bs. 10.510,26 (tasa BCV 184,52)'), 'en bolívares de hoy', pagar)
comprueba(pagar.includes('Pago Móvil: Banesco') && pagar.includes('envíanos el comprobante'), 'cómo pagar')

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
  mensajePagar({ ...base, tasa_bcv: null }).includes('a la tasa BCV del día en que pagues'),
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
    ver.includes('Saldo: $113,92') &&
    !ver.includes('Saldo total'),
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
comprueba(dos.includes('Saldo total: $142,40'), 'con dos, el saldo total', dos)
comprueba(mensajeFinanciamientos({ ...base, financiamientos: [] }).startsWith('No tienes pagos en cuotas activos'), 'sin activos')
comprueba(ver.startsWith('📋 Tus pagos en cuotas activos:'), 'el título de la lista', ver)
comprueba(fechaLarga('2026-10-12') === '12/10/2026', 'fecha larga')

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
]
const conPalabras = todos.filter((t) => PROHIBIDAS.test(t))
comprueba(conPalabras.length === 0, 'ningún texto dice préstamo, financiamiento ni crédito', conPalabras.join(' | '))

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
