/**
 * Pruebas del bot del médico con la inicial del 50% (docs/07), con una base
 * de mentira: cada RPC responde lo que diga la prueba y se anota.
 *
 *   npx tsx supabase/functions/whatsapp-webhook/bot.test.ts
 */
import { atenderAlPersonal } from './bot.ts'
import type { Personal } from './bot.ts'
import type { EventoDeMensaje } from './logica.ts'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

/** Lo que no se dice hacia fuera (CLAUDE.md, «Nombres»). */
const PROHIBIDO = /pr[eé]stamo|financiamiento|financiar|cr[eé]dito|\bfee\b/i

type Llamada = { fn: string; args: Record<string, unknown> }

const PERSONAL: Personal = {
  id: 's1',
  phone_e164: '+584140000001',
  user_id: 'u1',
  staff_name: 'Ana',
  role: 'gerente',
  merchant_id: 'm1',
  merchant_name: 'Dra. Ana Lara',
}

/** Un paciente conocido, ya con la moneda elegida: falta el monto. */
const CONOCIDO = {
  cedula: 'V12345678',
  nuevo: false,
  disponible: 150,
  usdPorEur: 1.16,
  moneda: 'USD',
  nombre: 'Luis Pérez',
  telefono: '0414-1234567',
  email: 'luis@correo.com',
}

/** Corre el bot con una sesión y unas respuestas por RPC; devuelve lo que hizo y las llamadas. */
async function correr(
  mensaje: Partial<EventoDeMensaje>,
  sesion: { state: string; data: Record<string, unknown> },
  respuestas: Record<string, unknown> = {},
  humano = false,
) {
  const llamadas: Llamada[] = []
  const rpc = async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
    llamadas.push({ fn, args })
    if (fn === 'bot_session') return { ...sesion, nueva: false } as T
    const r = respuestas[fn]
    if (r instanceof Error) throw r
    return (r ?? null) as T
  }
  const m: EventoDeMensaje = {
    kind: 'message',
    id: 'wamid.1',
    from: '584140000001',
    type: 'text',
    texto: null,
    boton: null,
    adjunto: null,
    raw: {},
    ...mensaje,
  }
  const res = await atenderAlPersonal({ rpc, personal: PERSONAL, mensaje: m, humano })
  const textos = llamadas.filter((l) => l.fn === 'helios_whatsapp_text').map((l) => String(l.args.p_text))
  const guardados = llamadas.filter((l) => l.fn === 'bot_session_save').map((l) => l.args)
  const fns = llamadas.map((l) => l.fn)
  return { res, llamadas, textos, guardados, fns }
}

/** La vista previa de una consulta de 100 con inicial (docs/01 «La inicial»). */
function previa(moneda: 'USD' | 'EUR', inicial = true) {
  const usd = moneda === 'USD' ? 1 : 1.16
  const ves = moneda === 'USD' ? 100 : 116
  const fila = (sequence: number, due_date: string, cur: number) => ({
    sequence,
    due_date,
    amount_usd: Math.round(cur * usd * 100) / 100,
    amount_cur: cur,
    amount_ves: Math.round(cur * ves * 100) / 100,
  })
  return {
    currency: moneda,
    base_usd: 100 * usd,
    base_cur: 100,
    consumer_fee_pct: 12,
    consumer_fee_usd: 12 * usd,
    consumer_fee_cur: 12,
    consumer_fee_vat_usd: 1.92 * usd,
    consumer_fee_vat_cur: 1.92,
    down_payment_pct: inicial ? 50 : 0,
    down_payment_minutes: inicial ? 120 : null,
    installments: inicial
      ? [fila(0, '2026-11-12', 56.96), fila(1, '2026-11-26', 28.48), fila(2, '2026-12-10', 28.48)]
      : [fila(1, '2026-11-26', 56.96), fila(2, '2026-12-10', 56.96)],
    cabe: true,
    disponible_usd: 150,
  }
}

async function main() {
  console.log('El resumen, con inicial (USD)')
  {
    const r = await correr({ texto: '$100, Consulta' }, { state: 'monto', data: CONOCIDO }, { bot_preview_charge: previa('USD') })
    const t = r.textos[0] ?? ''
    console.log(t.replace(/^/gm, '        '))
    comprueba(
      t.includes(
        'Inicial, el día de hoy: $56,96 (Bs 5.696,00 a la tasa de hoy)\n' +
          'Cuotas:\n' +
          '1. $28,48 el jue 26/11 (Bs 2.848,00 a la tasa de hoy)\n' +
          '2. $28,48 el jue 10/12 (Bs 2.848,00 a la tasa de hoy)',
      ),
      'la inicial de hoy y las 2 cuotas, con su número de siempre',
      t,
    )
    comprueba(
      t.includes('Comisión Helios (12%): $12 (Lo paga el paciente)\nIVA de la Comisión Helios: $1,92 (Lo paga el paciente)'),
      'la comisión, seguida de «(Lo paga el paciente)»',
      t,
    )
    comprueba(!/total/i.test(t) && !t.includes('113,92'), 'ningún total con la comisión', t)
    comprueba(!/\b0\. |cuota 0|0\.ª/.test(t), 'la inicial no sale como «0.»', t)
    comprueba(
      t.includes(
        'tiene 2 horas para aceptarlo: responderá «Sí», enviará una foto de su cédula si se la pedimos y pagará la inicial en las 2 horas siguientes. ' +
          'La orden queda activa cuando se aprueba la inicial y te aviso aquí; si no la paga a tiempo, se anula y también te aviso.',
      ),
      'qué hace el paciente y cuándo queda activa',
      t,
    )
    comprueba(t.length <= 1024, 'cabe en un mensaje con botones', String(t.length))
    comprueba(!PROHIBIDO.test(t), 'sin vocabulario prohibido')
    const g = r.guardados.at(-1)
    comprueba(
      g?.p_state === 'resumen' && (g?.p_data as Record<string, unknown>)?.minutosDeLaInicial === 120,
      'guarda el plazo de la inicial para el «Listo»',
      JSON.stringify(g),
    )
  }

  console.log('\nEl resumen, con inicial (EUR) y un paciente nuevo')
  {
    const nuevo = {
      cedula: 'V87654321',
      nuevo: true,
      disponible: 150,
      usdPorEur: 1.16,
      moneda: 'EUR',
      paciente: {
        first_name: 'María José',
        last_name: 'Rodríguez Hernández',
        birth_date: '1990-04-12',
        sex: 'F',
        phone: '0414-1234567',
        email: 'maria.jose.rodriguez.hernandez@correo.com',
        state: 'Distrito Capital',
        address: 'Av. Francisco de Miranda, Torre Delta, piso 3, oficina 3-B, Chacao',
      },
    }
    const r = await correr({ texto: '100, Limpieza dental con fluorización' }, { state: 'monto', data: nuevo }, { bot_preview_charge: previa('EUR') })
    const t = r.textos[0] ?? ''
    comprueba(
      t.includes('Inicial, el día de hoy: €56,96 (Bs 6.607,36 a la tasa de hoy)\nCuotas:\n1. €28,48 el jue 26/11'),
      'la inicial y las cuotas en euros',
      t,
    )
    comprueba(t.includes('Consulta: €100') && t.includes('Comisión Helios (12%): €12 (Lo paga el paciente)'), 'la consulta y la comisión en euros', t)
    comprueba(t.includes('a la tasa BCV del euro del día en que pague'), 'la tasa del euro', t)
    comprueba(!t.includes('$'), 'una orden en euros no habla de dólares', t)
    comprueba(t.length <= 1024, 'un paciente nuevo con datos largos también cabe', String(t.length))
  }

  console.log('\nEl resumen de una orden sin inicial (como antes)')
  {
    const r = await correr({ texto: '$100, Consulta' }, { state: 'monto', data: CONOCIDO }, { bot_preview_charge: previa('USD', false) })
    const t = r.textos[0] ?? ''
    comprueba(!/inicial/i.test(t), 'sin la fila de la inicial', t)
    comprueba(
      t.includes('Cuotas:\n1. $56,96 el jue 26/11 (Bs 5.696,00 a la tasa de hoy)\n2. $56,96 el jue 10/12'),
      'las 2 cuotas de siempre',
      t,
    )
    comprueba(
      t.endsWith('tiene 2 horas para confirmarlo: responderá «Sí» y, si se lo pedimos, enviará una foto de su cédula.'),
      'la explicación de siempre',
      t,
    )
    const g = r.guardados.at(-1)
    comprueba((g?.p_data as Record<string, unknown>)?.minutosDeLaInicial === null, 'sin plazo de inicial', JSON.stringify(g))
  }

  console.log('\nEl «Listo» tras confirmar')
  function creada(extra: Record<string, unknown>) {
    const charge: Record<string, unknown> = {
      id: 'c1',
      order_number: 6261,
      status: 'pending',
      expires_at: '2026-11-12T20:30:00Z',
      confirmation: { telefono_enmascarado: '0414-***4567' },
    }
    return { charge: { ...charge, ...extra } }
  }
  {
    const r = await correr(
      { boton: 'orden:confirmar', texto: 'Confirmar' },
      { state: 'resumen', data: { ...CONOCIDO, monto: 100, minutosDeLaInicial: 120 } },
      { bot_create_charge: creada({ down_payment_pct: 50 }) },
    )
    const t = r.textos[0] ?? ''
    console.log(t.replace(/^/gm, '        '))
    comprueba(
      t ===
        'Listo. Orden #6261 enviada. Le escribimos a Luis Pérez al 0414-***4567 para que la acepte: ' +
          'responderá «Sí», enviará una foto de su cédula si se la pedimos y pagará la inicial en las 2 horas siguientes.\n' +
          'Tiene hasta las 16:30 para responder. ' +
          'La orden queda activa cuando se aprueba la inicial y te aviso aquí; si no la paga a tiempo, se anula y también te aviso.',
      'con inicial: el plazo y cuándo le avisamos',
      t,
    )
  }
  {
    const r = await correr(
      { boton: 'orden:confirmar', texto: 'Confirmar' },
      { state: 'resumen', data: { ...CONOCIDO, monto: 100 } },
      { bot_create_charge: creada({ down_payment_pct: null }) },
    )
    comprueba(
      r.textos[0]?.endsWith('Tiene hasta las 16:30. Te aviso aquí cuando responda.') && !/inicial/i.test(r.textos[0] ?? ''),
      'sin inicial: como antes',
      r.textos[0],
    )
  }

  console.log('\nMis pagos en cuotas')
  {
    const r = await correr({ boton: 'menu:mis', texto: 'Mis pagos en cuotas' }, { state: 'menu', data: {} }, {
      bot_recent_charges: [
        { order_number: 6262, customer_name: 'Luis Pérez', status: 'awaiting_down_payment', down_payment_due_at: '2026-11-12T20:30:00Z', currency: 'USD', merchant_sale_cur: 100 },
        // Como la devuelve `merchant_transactions` (frente A): fechas de cuotas null salvo en confirmed/pending/awaiting.
        {
          order_number: 6261, customer_name: 'Ana Gil', status: 'reverted', currency: 'EUR', merchant_sale_cur: 80,
          down_payment_due_at: null, down_payment_expired_at: '2026-11-12T20:31:00Z',
          cuota_1_due: null, cuota_1_run: null, cuota_2_due: null, cuota_2_run: null, expires_at: null,
        },
        {
          order_number: 6258, customer_name: 'Eva Mar', status: 'reverted', currency: 'USD', merchant_sale_cur: 40,
          down_payment_due_at: null, down_payment_expired_at: null,
          cuota_1_due: null, cuota_1_run: null, cuota_2_due: null, cuota_2_run: null, expires_at: null,
        },
        { order_number: 6260, customer_name: 'Rosa Díaz', status: 'pending', expires_at: '2026-11-12T19:00:00Z', currency: 'USD', merchant_sale_cur: 50 },
        { order_number: 6259, customer_name: 'Juan Rey', status: 'confirmed', currency: 'USD', merchant_sale_cur: 30 },
      ],
    })
    const t = r.textos[0] ?? ''
    console.log(t.replace(/^/gm, '        '))
    comprueba(t.includes('#6262 · Luis Pérez · $100 · Esperando la inicial (hasta las 16:30)'), 'esperando la inicial, con su hora', t)
    comprueba(t.includes('#6261 · Ana Gil · €80 · Anulado: no pagó la inicial\n'), 'anulada por no pagar la inicial (down_payment_expired_at)', t)
    comprueba(t.includes('#6258 · Eva Mar · $40 · Revertido\n'), 'otra revertida (por el equipo): «Revertido»', t)
    comprueba(!t.includes('null') && !t.includes('undefined') && !t.includes('NaN'), 'las fechas null no rompen nada', t)
    comprueba(t.includes('#6260 · Rosa Díaz · $50 · Esperando al paciente (vence 15:00)'), 'las de antes, igual', t)
    comprueba(!t.includes('awaiting') && !t.includes('reverted'), 'sin estados en inglés', t)
    comprueba(t.endsWith('«reenviar 6260».'), 'el ejemplo de «reenviar», con una que se puede reenviar', t)
  }

  console.log('\nReenviar')
  {
    const r = await correr({ texto: 'reenviar 6262' }, { state: 'menu', data: {} }, {
      bot_charge_by_order: { id: 'c2', status: 'awaiting_down_payment', order_number: 6262, down_payment_due_at: '2026-11-12T20:30:00Z' },
    })
    comprueba(!r.fns.includes('bot_resend_confirmation') && !r.fns.includes('bot_resend_receipt'), 'esperando la inicial: no reenvía nada')
    comprueba(
      r.textos[0] ===
        'La orden #6262 ya la aceptó el paciente y está esperando su inicial, así que no hay nada que reenviarle. Tiene hasta las 16:30 para pagarla.\n' +
          'La orden queda activa cuando se aprueba la inicial y te aviso aquí; si no la paga a tiempo, se anula y también te aviso.',
      'y lo explica',
      r.textos[0],
    )
  }
  {
    const r = await correr({ texto: 'reenviar 6261' }, { state: 'menu', data: {} }, {
      bot_charge_by_order: { id: 'c3', status: 'reverted', order_number: 6261, down_payment_expired_at: '2026-11-12T20:31:00Z' },
    })
    comprueba(
      !r.fns.includes('bot_resend_confirmation') && r.textos[0]?.includes('se anuló porque el paciente no pagó la inicial a tiempo'),
      'anulada por la inicial: lo dice y no reenvía',
      r.textos[0],
    )
  }
  {
    // Revertida por el equipo (sin `down_payment_expired_at`): la base dice que no se puede.
    const r = await correr({ texto: 'reenviar 6258' }, { state: 'menu', data: {} }, {
      bot_charge_by_order: { id: 'c6', status: 'reverted', order_number: 6258, down_payment_expired_at: null },
      bot_resend_confirmation: Object.assign(new Error('bot_resend_confirmation: Esta orden ya no se puede reenviar'), { code: '22023' }),
    })
    comprueba(
      r.fns.includes('bot_resend_confirmation') && r.textos[0] === 'Esta orden ya no se puede reenviar' && !/inicial/.test(r.textos[0] ?? ''),
      'otra revertida: el error de la base, sin hablar de la inicial',
      r.textos[0],
    )
  }
  {
    const r = await correr({ texto: 'reenviar 6260' }, { state: 'menu', data: {} }, {
      bot_charge_by_order: { id: 'c4', status: 'expired', order_number: 6260 },
      bot_resend_confirmation: { id: 'c4', status: 'pending', down_payment_pct: 50 },
    })
    comprueba(
      r.fns.includes('bot_resend_confirmation') &&
        r.textos[0]?.includes('pagará la inicial en las 3 horas siguientes') &&
        r.textos[0]?.includes('La orden queda activa cuando se aprueba la inicial'),
      'una vencida reabierta con inicial: la pregunta y la inicial',
      r.textos[0],
    )
  }
  {
    const r = await correr({ texto: 'reenviar 6100' }, { state: 'menu', data: {} }, {
      bot_charge_by_order: { id: 'c5', status: 'pending', order_number: 6100 },
      bot_resend_confirmation: { id: 'c5', status: 'pending', down_payment_pct: null },
    })
    comprueba(
      r.textos[0] ===
        'Listo, le reenviamos la pregunta al paciente de la orden #6100. Tiene 2 horas para confirmarla: responderá «Sí» y, si se lo pedimos, enviará una foto de su cédula.',
      'una pendiente sin inicial: como antes',
      r.textos[0],
    )
  }

  console.log('\nAyuda')
  {
    const r = await correr({ boton: 'menu:ayuda', texto: 'Ayuda' }, { state: 'menu', data: {} })
    const t = r.textos[0] ?? ''
    comprueba(t.includes('pagará la inicial en las 3 horas siguientes') && t.includes('se anula y también te aviso'), 'explica la inicial', t)
    comprueba(t.length <= 1024 && !PROHIBIDO.test(t), 'cabe con botones y sin vocabulario prohibido', String(t.length))
  }

  console.log('\nNo interrumpe (2026-11-20)')
  {
    const r = await correr({ texto: 'Gracias!' }, { state: 'menu', data: {} })
    comprueba(r.res === null && r.textos.length === 0, '«Gracias» en el menú: nada', r.textos.join(' | '))
  }
  {
    const r = await correr({ texto: 'qué tal todo' }, { state: 'menu', data: {} })
    comprueba(r.textos[0]?.startsWith('No entendí'), 'lo que no entiende, sin persona atendiendo: «No entendí»', r.textos[0])
  }
  {
    const r = await correr({ texto: 'qué tal todo' }, { state: 'menu', data: {} }, {}, true)
    comprueba(r.res === null && r.textos.length === 0, 'con una persona atendiendo: se calla', r.textos.join(' | '))
  }
  {
    const r = await correr({ boton: 'menu:ayuda', texto: 'Ayuda' }, { state: 'menu', data: {} }, {}, true)
    comprueba(r.textos.length > 0, 'con una persona atendiendo, sus botones siguen funcionando')
  }

  if (fallos > 0) {
    console.log(`\n${fallos} fallo(s)`)
    process.exit(1)
  }
  console.log('\nTodo bien')
}

main()
