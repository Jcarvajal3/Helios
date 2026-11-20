/**
 * Pruebas del bot del paciente con el lector de comprobantes (docs/03), con
 * una base de mentira: cada RPC responde lo que diga la prueba y se anota.
 *
 *   npx tsx supabase/functions/whatsapp-webhook/paciente.test.ts
 */
import { atenderAlPaciente, esUnSiRepetido, recordarLaInicial } from './paciente.ts'
import type { EventoDeMensaje } from './logica.ts'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

type Llamada = { fn: string; args: Record<string, unknown> }

const PERFIL = { id: 'p1', nombre: 'Lia', documento: 'V12345678', documento_enmascarado: 'V-****5678' }

function contexto(extra: Record<string, unknown> = {}) {
  return {
    perfiles: [PERFIL],
    elegido: null,
    estado: null,
    humano: false,
    menu_reciente: false,
    vencida_texto: null,
    lector: 'apagado',
    borrador: null,
    ...extra,
  }
}

/** Corre el bot con un contexto y unas respuestas por RPC; devuelve lo que hizo y las llamadas. */
async function correr(
  mensaje: Partial<EventoDeMensaje>,
  ctx: Record<string, unknown>,
  respuestas: Record<string, unknown> = {},
) {
  const llamadas: Llamada[] = []
  let despertado = 0
  const rpc = async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
    llamadas.push({ fn, args })
    if (fn === 'bot_paciente_contexto') return ctx as T
    return (respuestas[fn] ?? null) as T
  }
  const m: EventoDeMensaje = {
    kind: 'message',
    id: 'wamid.1',
    from: '584140009501',
    type: 'text',
    texto: null,
    boton: null,
    adjunto: null,
    raw: {},
    ...mensaje,
  }
  const res = await atenderAlPaciente({ rpc, mensaje: m, despertarAlLector: () => despertado++ })
  const textos = llamadas.filter((l) => l.fn === 'helios_whatsapp_patient_text').map((l) => String(l.args.p_text))
  const guardados = llamadas.filter((l) => l.fn === 'bot_paciente_guardar').map((l) => l.args)
  const fns = llamadas.map((l) => l.fn)
  return { res, llamadas, textos, guardados, fns, despertado }
}

const FOTO: Partial<EventoDeMensaje> = { type: 'image', adjunto: { id: 'media-1', mime: 'image/jpeg' } }

async function main() {
  console.log('Apagado: como siempre')
  {
    const r = await correr(FOTO, contexto())
    comprueba(!r.fns.includes('bot_comprobante_nuevo'), 'no encola nada')
    comprueba(r.guardados.some((g) => g.p_humano_horas === 8), 'se calla 8 h')
    comprueba(r.textos[0]?.includes('Lo revisamos'), 'el acuse de siempre', r.textos[0])
  }
  {
    const r = await correr({ boton: 'paciente:ya_pague', texto: 'Ya pagué' }, contexto())
    comprueba(r.textos[0]?.includes('escribe también el número de referencia'), '«Ya pagué» como siempre', r.textos[0])
  }
  {
    const r = await correr({ texto: 'datos' }, contexto())
    comprueba(!r.fns.includes('bot_paciente_borrador'), '«datos» no abre el formulario')
  }

  console.log('Sombra: como siempre, y además se lee')
  {
    const r = await correr(FOTO, contexto({ lector: 'sombra' }), {
      bot_comprobante_nuevo: { ok: true, id: 'l1', mode: 'sombra' },
    })
    comprueba(r.fns.includes('bot_comprobante_nuevo') && r.despertado === 1, 'encola y despierta al lector')
    comprueba(r.guardados.some((g) => g.p_humano_horas === 8), 'se calla 8 h como siempre')
    comprueba(r.textos[0]?.includes('Lo revisamos'), 'el acuse de siempre', r.textos[0])
  }

  console.log('Activo')
  {
    const r = await correr(FOTO, contexto({ lector: 'activo' }), {
      bot_comprobante_nuevo: { ok: true, id: 'l1', mode: 'activo' },
    })
    const encolada = r.llamadas.find((l) => l.fn === 'bot_comprobante_nuevo')?.args
    comprueba(encolada?.p_media_id === 'media-1' && encolada?.p_mime === 'image/jpeg' && encolada?.p_quiet === false, 'encola la captura con su adjunto')
    comprueba(!r.guardados.some((g) => g.p_humano_horas === 8), 'no se calla')
    comprueba(r.textos[0]?.includes('Lo estamos verificando'), 'el acuse dice que lo verifica', r.textos[0])
  }
  {
    const r = await correr(FOTO, contexto({ lector: 'activo' }), {
      bot_comprobante_nuevo: { ok: false, motivo: 'tope', mode: 'activo' },
    })
    comprueba(r.guardados.some((g) => g.p_humano_horas === 8) && r.despertado === 0, 'pasado el tope, como siempre')
  }
  {
    const r = await correr(FOTO, contexto({ lector: 'activo', humano: true }), {
      bot_comprobante_nuevo: { ok: true, id: 'l1', mode: 'activo' },
    })
    const encolada = r.llamadas.find((l) => l.fn === 'bot_comprobante_nuevo')?.args
    comprueba(r.res === null && r.textos.length === 0, 'con una persona atendiendo, no escribe')
    comprueba(encolada?.p_quiet === true && r.despertado === 1, 'pero la captura se lee, en silencio')
  }
  {
    const r = await correr(FOTO, contexto({ lector: 'activo', perfiles: [PERFIL, { ...PERFIL, id: 'p2' }] }), {
      bot_comprobante_nuevo: { ok: true, id: 'l1', mode: 'activo' },
    })
    comprueba(!r.fns.includes('bot_comprobante_nuevo'), 'un teléfono de varios pacientes sin elegir: no se sabe de quién es')
  }

  console.log('La referencia pedida')
  {
    const r = await correr({ texto: '1158795645' }, contexto({ lector: 'activo', estado: 'referencia' }), {
      bot_comprobante_referencia: { ok: true, outcome: 'registrado' },
    })
    comprueba(r.fns.includes('bot_comprobante_referencia') && r.textos[0]?.includes('Ya lo estamos verificando'), 'se pasa a la base y se agradece', r.textos[0])
  }
  {
    const r = await correr({ texto: 'no sé cuál es' }, contexto({ lector: 'activo', estado: 'referencia' }), {
      bot_comprobante_referencia: { ok: true, outcome: 'para_el_equipo' },
    })
    comprueba(r.textos[0]?.includes('Alguien de nuestro equipo'), 'lo que no es una referencia, al equipo', r.textos[0])
  }
  {
    const r = await correr({ boton: 'paciente:pagar', texto: 'Pagar mi cuota' }, contexto({ lector: 'activo', estado: 'referencia' }), {
      bot_paciente_resumen: { nombre: 'Lia', financiamientos: [], tasa_bcv: 100 },
    })
    comprueba(!r.fns.includes('bot_comprobante_referencia') && r.guardados.some((g) => g.p_estado === ''), 'un botón deja de esperar la referencia')
  }

  console.log('Los datos escritos')
  {
    const r = await correr({ boton: 'paciente:ya_pague', texto: 'Ya pagué' }, contexto({ lector: 'activo' }))
    comprueba(r.textos[0]?.includes('escribe *datos*'), '«Ya pagué» ofrece escribir los datos', r.textos[0])
  }
  {
    const r = await correr({ texto: 'No tengo captura' }, contexto({ lector: 'activo' }))
    comprueba(r.guardados.some((g) => g.p_estado === 'datos_pago') && r.textos[0]?.includes('Referencia completa:'), 'abre el formulario', r.textos[0])
  }
  {
    const r = await correr({ texto: 'Banco: Banesco' }, contexto({ lector: 'activo', estado: 'datos_pago', borrador: {} }))
    const b = r.llamadas.find((l) => l.fn === 'bot_paciente_borrador')?.args.p_draft as Record<string, unknown>
    comprueba(b?.banco === 'Banesco' && b?.intentos === 1, 'guarda lo que llegó', JSON.stringify(b))
    comprueba(r.textos[0]?.startsWith('Me falta el teléfono desde el que pagaste y la referencia completa'), 'y pide lo que falta', r.textos[0])
  }
  {
    const r = await correr(
      { texto: '04141234567\n001234567890' },
      contexto({ lector: 'activo', estado: 'datos_pago', borrador: { banco: 'Banesco', intentos: 1 } }),
      { bot_comprobante_datos: { ok: true, id: 'l9', outcome: 'esperando' } },
    )
    const a = r.llamadas.find((l) => l.fn === 'bot_comprobante_datos')?.args
    comprueba(a?.p_bank === 'Banesco' && a?.p_payer_phone === '04141234567' && a?.p_reference === '001234567890', 'completos, a la base', JSON.stringify(a))
    comprueba(r.textos[0]?.includes('buscamos tu pago en el banco') && r.guardados.some((g) => g.p_estado === ''), 'y se espera al banco', r.textos[0])
  }
  {
    const r = await correr({ texto: 'no sé' }, contexto({ lector: 'activo', estado: 'datos_pago', borrador: { intentos: 2 } }))
    comprueba(r.guardados.some((g) => g.p_humano_horas === 8) && r.textos[0]?.includes('Alguien de nuestro equipo'), 'a la tercera, al equipo', r.textos[0])
  }
  {
    const r = await correr(
      { texto: 'Banco: Banesco\nTeléfono: 04141234567\nReferencia: 001234567890' },
      contexto({ lector: 'activo', estado: 'datos_pago', borrador: {} }),
      { bot_comprobante_datos: { ok: true, id: 'l9', outcome: 'monto_no_cuadra' } },
    )
    comprueba(r.guardados.some((g) => g.p_humano_horas === 8), 'si la base no puede, lo ve una persona')
  }

  console.log('La inicial (docs/07)')
  const ESPERANDO = {
    nombre: 'Lia',
    tasa_bcv: 100,
    cuentas_de_cobro: '• Pago Móvil',
    datos_de_pago: '🏦 *Pago Móvil*',
    pago_en_revision: false,
    disponible_usd: 50,
    nivel: 1,
    nivel_nombre: 'Nivel 1',
    limite_usd: 150,
    financiamientos: [
      {
        orden: 6261,
        clinica: 'Consultorio 103',
        medico: 'Dra. Nadia Khabbaze',
        medico_ref: 'la Dra. Nadia Khabbaze',
        moneda: 'USD',
        consulta: 100,
        estado: 'awaiting_down_payment',
        inicial_vence_at: '2026-11-12T20:30:00Z',
        cuotas: [
          { sequence: 0, due_date: '2026-11-12', monto: 56.96, cargo_atraso: 0, vencida: false },
          { sequence: 1, due_date: '2026-11-26', monto: 28.48, cargo_atraso: 0, vencida: false },
          { sequence: 2, due_date: '2026-12-10', monto: 28.48, cargo_atraso: 0, vencida: false },
        ],
        pagadas: [],
      },
    ],
  }
  {
    // La captura de la inicial: el webhook ya no la toma por cédula (la orden
    // fue aceptada), así que llega aquí y va al lector como cualquier cuota.
    const r = await correr(FOTO, contexto({ lector: 'activo' }), {
      bot_comprobante_nuevo: { ok: true, id: 'l1', mode: 'activo' },
    })
    comprueba(r.fns.includes('bot_comprobante_nuevo') && r.despertado === 1, 'la captura de la inicial va al lector')
    comprueba(!r.textos.some((t) => /confirmad/i.test(t)), 'sin «confirmado»', r.textos.join(' | '))
  }
  {
    const r = await correr({ boton: 'paciente:pagar', texto: 'Pagar mi cuota' }, contexto(), { bot_paciente_resumen: ESPERANDO })
    comprueba(
      r.textos[0]?.startsWith('💳 *Tu inicial*\n$56,96 · págala antes de las 16:30 ⏰'),
      '«Pagar mi cuota» con la orden esperando: la inicial y su hora',
      r.textos[0],
    )
  }
  {
    const r = await correr({ boton: 'paciente:financiamientos', texto: 'Mi saldo y cuotas' }, contexto(), { bot_paciente_resumen: ESPERANDO })
    const envio = r.llamadas.find((l) => l.fn === 'helios_whatsapp_patient_text')?.args
    comprueba(
      String(envio?.p_text).includes('⏳ Inicial $56,96 · págala antes de las 16:30\n⏳ 1.ª cuota $28,48') &&
        String(envio?.p_text).includes('🔔 Tu pago en cuotas se activa en cuanto confirmemos tu inicial.'),
      '«Mi saldo y cuotas» con la orden esperando',
      String(envio?.p_text),
    )
    comprueba(
      JSON.stringify(envio?.p_buttons) === JSON.stringify([{ id: 'paciente:pagar', title: 'Pagar mi cuota' }]),
      'con el botón «Pagar mi cuota»',
      JSON.stringify(envio?.p_buttons),
    )
  }

  console.log('«Sí» otra vez, con la orden esperando la inicial')
  const YA_ACEPTO = '✅ ¡Ya aceptaste tu pago en cuotas, Lia! Solo falta tu inicial para activarlo 👇\n\n💳 *Tu inicial*\n$56,96 · págala antes de las 16:30 ⏰'
  for (const texto of ['Sí', 'sí, acepto', 'Acepto']) {
    const r = await correr({ texto }, contexto(), { bot_paciente_resumen: ESPERANDO })
    comprueba(
      r.textos.length === 1 && r.textos[0].startsWith(YA_ACEPTO) && r.textos[0].trimEnd().endsWith('⭐ Recuerda pagar a tiempo para subir de nivel y disponer de mayores beneficios.'),
      `«${texto}» escrito: ya aceptó, falta la inicial, con el bloque de pago (un solo mensaje)`,
      r.textos.join(' | '),
    )
    comprueba(!r.guardados.some((g) => g.p_menu === true), 'sin el menú genérico')
  }
  {
    // Con una vencida de las últimas 12 h, manda la orden que espera.
    const r = await correr({ texto: 'si' }, contexto({ vencida_texto: 'esta solicitud venció' }), { bot_paciente_resumen: ESPERANDO })
    comprueba(r.textos.length === 1 && r.textos[0].startsWith(YA_ACEPTO), 'antes que la orden vencida', r.textos.join(' | '))
  }
  {
    const r = await correr({ texto: 'si' }, contexto({ vencida_texto: 'esta solicitud venció' }), {
      bot_paciente_resumen: { ...ESPERANDO, financiamientos: [] },
    })
    comprueba(r.textos[0] === 'esta solicitud venció', 'sin orden esperando: la vencida, como antes', r.textos[0])
  }
  {
    const r = await correr({ texto: 'si' }, contexto(), {
      bot_paciente_resumen: { ...ESPERANDO, financiamientos: [{ ...ESPERANDO.financiamientos[0], estado: 'confirmed' }] },
    })
    // Desde el 2026-11-20 un «sí» suelto es cortesía: ya no recibe el menú.
    comprueba(r.res === null && r.textos.length === 0, 'sin orden esperando ni vencida: nada (es cortesía)', JSON.stringify(r.res))
  }
  {
    const r = await correr({ texto: 'si' }, contexto({ perfiles: [PERFIL, { ...PERFIL, id: 'p2' }] }), { bot_paciente_resumen: ESPERANDO })
    comprueba(!r.fns.includes('bot_paciente_resumen'), 'un teléfono de varios pacientes sin elegir: no enseña nada sin la cédula')
  }
  {
    const r = await correr({ texto: 'no' }, contexto(), { bot_paciente_resumen: ESPERANDO })
    comprueba(!r.textos.some((t) => t.startsWith('✅ ¡Ya aceptaste')), 'un «no» no recibe el recordatorio')
  }

  console.log('El botón «Sí» otra vez (index.ts)')
  comprueba(
    esUnSiRepetido('si', { ok: false, reason: 'no_pendiente', status: 'awaiting_down_payment' }),
    'lo que devuelve helios_patient_decision con la orden esperando: se recuerda',
  )
  comprueba(
    !esUnSiRepetido('si', { ok: false, reason: 'no_pendiente', status: 'confirmed' }) &&
      !esUnSiRepetido('si', { ok: false, reason: 'no_pendiente', status: 'expired' }) &&
      !esUnSiRepetido('no', { ok: false, reason: 'no_pendiente', status: 'awaiting_down_payment' }) &&
      !esUnSiRepetido('si', { ok: true, status: 'awaiting_down_payment', down_payment_due_at: 'x' }) &&
      !esUnSiRepetido('si', null),
    'lo demás no (la vencida ya la contesta la base; el «Sí» que acepta, también)',
  )
  {
    const llamadas: Llamada[] = []
    const rpc = async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
      llamadas.push({ fn, args })
      if (fn === 'bot_paciente_contexto') return contexto({ humano: true }) as T
      if (fn === 'bot_paciente_resumen') return ESPERANDO as T
      return null as T
    }
    const m: EventoDeMensaje = {
      kind: 'message', id: 'wamid.2', from: '584140009501', type: 'interactive', texto: 'Sí',
      boton: 'confirmar:0b0e4a52-6a0c-4c55-9a3f-2b8a1c1d2e3f', adjunto: null, raw: {},
    }
    const res = await recordarLaInicial({ rpc, mensaje: m })
    const textos = llamadas.filter((l) => l.fn === 'helios_whatsapp_patient_text').map((l) => String(l.args.p_text))
    comprueba(
      res?.paso === 'ya_acepto' && textos.length === 1 && textos[0].startsWith(YA_ACEPTO),
      'el botón: el mismo recordatorio, también con una persona atendiendo (pulsó el botón)',
      textos.join(' | '),
    )
  }

  console.log('\nLa cortesía no pide respuesta (2026-11-20)')
  for (const texto of ['Gracias', 'ok gracias', 'Sí', '👍']) {
    const r = await correr({ texto }, contexto())
    comprueba(r.res === null && r.textos.length === 0, `«${texto}»: no contesta el menú`, r.textos.join(' | '))
  }
  {
    const r = await correr({ type: 'reaction', texto: null }, contexto())
    comprueba(r.res === null && r.textos.length === 0, 'una reacción: nada')
  }
  {
    const r = await correr({ texto: 'gracias' }, contexto({ estado: 'cedula', perfiles: [PERFIL, { ...PERFIL, id: 'p2' }] }))
    comprueba(r.res === null && r.textos.length === 0, 'esperando la cédula, un «gracias» no la vuelve a pedir', r.textos.join(' | '))
  }
  {
    const r = await correr({ texto: 'Hola, tengo una duda' }, contexto())
    comprueba((r.res as { paso?: string } | null)?.paso === 'menu' && r.textos.length === 1, 'una pregunta sí recibe el menú')
  }
  {
    const r = await correr({ texto: 'Sí' }, contexto({ vencida_texto: 'Tu orden venció' }))
    comprueba(r.textos[0] === 'Tu orden venció', 'un «sí» a una orden vencida sigue contestándose', r.textos.join(' | '))
  }

  if (fallos > 0) {
    console.log(`\n${fallos} fallo(s)`)
    process.exit(1)
  }
  console.log('\nTodo bien')
}

main()
