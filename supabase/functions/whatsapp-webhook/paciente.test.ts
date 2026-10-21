/**
 * Pruebas del bot del paciente con el lector de comprobantes (docs/03), con
 * una base de mentira: cada RPC responde lo que diga la prueba y se anota.
 *
 *   npx tsx supabase/functions/whatsapp-webhook/paciente.test.ts
 */
import { atenderAlPaciente } from './paciente.ts'
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
    comprueba(r.guardados.some((g) => g.p_humano_horas === 24), 'se calla 24 h')
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
    comprueba(r.guardados.some((g) => g.p_humano_horas === 24), 'se calla 24 h como siempre')
    comprueba(r.textos[0]?.includes('Lo revisamos'), 'el acuse de siempre', r.textos[0])
  }

  console.log('Activo')
  {
    const r = await correr(FOTO, contexto({ lector: 'activo' }), {
      bot_comprobante_nuevo: { ok: true, id: 'l1', mode: 'activo' },
    })
    const encolada = r.llamadas.find((l) => l.fn === 'bot_comprobante_nuevo')?.args
    comprueba(encolada?.p_media_id === 'media-1' && encolada?.p_mime === 'image/jpeg' && encolada?.p_quiet === false, 'encola la captura con su adjunto')
    comprueba(!r.guardados.some((g) => g.p_humano_horas === 24), 'no se calla')
    comprueba(r.textos[0]?.includes('Lo estamos verificando'), 'el acuse dice que lo verifica', r.textos[0])
  }
  {
    const r = await correr(FOTO, contexto({ lector: 'activo' }), {
      bot_comprobante_nuevo: { ok: false, motivo: 'tope', mode: 'activo' },
    })
    comprueba(r.guardados.some((g) => g.p_humano_horas === 24) && r.despertado === 0, 'pasado el tope, como siempre')
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
    comprueba(r.guardados.some((g) => g.p_humano_horas === 24) && r.textos[0]?.includes('Alguien de nuestro equipo'), 'a la tercera, al equipo', r.textos[0])
  }
  {
    const r = await correr(
      { texto: 'Banco: Banesco\nTeléfono: 04141234567\nReferencia: 001234567890' },
      contexto({ lector: 'activo', estado: 'datos_pago', borrador: {} }),
      { bot_comprobante_datos: { ok: true, id: 'l9', outcome: 'monto_no_cuadra' } },
    )
    comprueba(r.guardados.some((g) => g.p_humano_horas === 24), 'si la base no puede, lo ve una persona')
  }

  if (fallos > 0) {
    console.log(`\n${fallos} fallo(s)`)
    process.exit(1)
  }
  console.log('\nTodo bien')
}

main()
