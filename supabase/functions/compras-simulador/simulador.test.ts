/**
 * Pruebas del simulador de compras: el mismo flujo del bot, con el transporte
 * del simulador y una base de mentira.
 *
 *   npx tsx supabase/functions/compras-simulador/simulador.test.ts
 */
import { ProveedorAmazonMock } from '../whatsapp-webhook/compras/catalogo_mock.ts'
import { crearTransporteSimulador } from '../whatsapp-webhook/compras/transporte_simulador.ts'
import type { PersonalCompra } from '../whatsapp-webhook/compras/flujo.ts'
import { armarMensaje, ejecutarTurno, leerPeticion, proveedorListo } from './logica.ts'
import type { Peticion } from './logica.ts'

let fallos = 0
function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const PERSONAL: PersonalCompra = {
  id: 's1',
  phone_e164: '+584140000001',
  user_id: 'u1',
  staff_name: 'Ana',
  role: 'gerente',
  merchant_id: 'm1',
  merchant_name: 'Dra. Ana Lara',
}
const ID1 = '11111111-1111-4111-8111-111111111111'
const CONFIG = {
  catalog_provider: 'mock',
  tax_usa_pct: 7,
  service_fee_pct: 8,
  air_rate_per_lb_usd: 6.5,
  air_min_usd: 15,
  sea_rate_per_ft3_usd: 24,
  sea_min_usd: 35,
  fallback_weight_lb: 2,
  quote_ttl_hours: 48,
  fx_rate_usd: 100,
  accounts_block: 'BNC',
}

type Llamada = { fn: string; args: Record<string, unknown> }

/** Una sesión en memoria y las llamadas anotadas. */
function crearBase(respuestas: Record<string, unknown> = {}, inicial: { state: string; data: Record<string, unknown> } = { state: 'menu', data: {} }) {
  const llamadas: Llamada[] = []
  let sesion = { ...inicial }
  const rpc = async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
    llamadas.push({ fn, args })
    if (fn === 'sim_compra_sesion') return { ...sesion, nueva: false } as T
    if (fn === 'sim_compra_sesion_guardar') {
      sesion = { state: String(args.p_state), data: args.p_data as Record<string, unknown> }
      return null as T
    }
    if (fn === 'bot_compra_config') return CONFIG as T
    const r = respuestas[fn]
    if (r instanceof Error) throw r
    return (r ?? null) as T
  }
  return { rpc, llamadas, sesion: () => sesion }
}

type Turno = Extract<Peticion, { accion: 'turno' }>

async function turno(base: ReturnType<typeof crearBase>, p: Partial<Turno>, id = 'turno-1') {
  const peticion: Turno = { accion: 'turno', phone: '+584140000001', ...p }
  const r = await ejecutarTurno({
    rpc: base.rpc,
    personal: PERSONAL,
    peticion,
    idDelTurno: id,
    proveedorDe: (n) => (n === 'mock' ? new ProveedorAmazonMock() : null),
  })
  const salientes = base.llamadas.filter((l) => l.fn === 'sim_compra_mensaje' && l.args.p_direction === 'out').map((l) => l.args)
  return { ...r, salientes, ultimo: salientes.at(-1) }
}

async function main() {
  console.log('Petición')
  {
    comprueba('accion' in leerPeticion({ accion: 'diagnostico' }), 'diagnóstico')
    comprueba('error' in leerPeticion({ accion: 'turno', phone: '0414' }), 'teléfono sin E.164: error')
    comprueba('error' in leerPeticion({ accion: 'x' }), 'acción desconocida: error')
    comprueba('error' in leerPeticion({ accion: 'turno', phone: '+584140000001', adjunto: { receipt_path: '../etc/passwd' } }), 'ruta de comprobante fuera de compras/simulador: error')
    const ok = leerPeticion({ accion: 'turno', phone: '+584140000001', adjunto: { receipt_path: `compras/simulador/${ID1}.png` } })
    comprueba('adjunto' in ok && ok.adjunto?.receipt_path === `compras/simulador/${ID1}.png`, 'ruta válida')
    const m = armarMensaje({ accion: 'turno', phone: '+584140000001', respuesta: { id: 'compra:mis', title: 'Mis compras' } }, 'u-1')
    comprueba(m.boton === 'compra:mis' && m.texto === 'Mis compras' && m.from === '584140000001', 'una respuesta es un toque de botón (id + título)')
    comprueba(proveedorListo('mock', false) && !proveedorListo('rainforest', false) && proveedorListo('rainforest', true), 'proveedor_listo')
  }

  console.log('\nEl turno corre el flujo real')
  {
    const base = crearBase()
    const inicio = await turno(base, {})
    comprueba(inicio.estado === 'menu' && inicio.ultimo?.p_kind === 'buttons', 'sin texto: abre el menú de compras con botones')
    const botones = (inicio.ultimo?.p_payload as { buttons: Array<{ id: string; title: string }> }).buttons
    comprueba(botones.map((b) => b.id).join() === 'menu:comprar,compra:mis', 'menú: Comprar en Amazon · Mis compras', JSON.stringify(botones))

    const busca = await turno(base, { texto: 'estetoscopio' }, 't2')
    comprueba(busca.ultimo?.p_kind === 'carousel' && busca.estado === 'compra_resultados', 'texto libre en el menú = búsqueda → carrusel')
    const cards = (busca.ultimo?.p_payload as { cards: Array<{ image_url: string; body: string; button: { id: string; title: string } }> }).cards
    comprueba(cards.length === 3 && cards[0].button.id === 'compra:v:B00QES9K4G' && cards[0].button.title === 'Cotizar' && cards[0].image_url.startsWith('https://') && cards[0].body.startsWith('1. '), 'payload canónico del carrusel {cards:[{image_url,body,button:{id,title}}]}', JSON.stringify(cards[0]))
    comprueba(base.llamadas.some((l) => l.fn === 'sim_compra_mensaje' && l.args.p_direction === 'in' && l.args.p_kind === 'text' && l.args.p_body === 'estetoscopio'), 'registra el mensaje entrante')

    const toca = await turno(base, { respuesta: { id: 'compra:v:B00QES9K4G', title: 'Cotizar' } }, 't3')
    comprueba(toca.estado === 'compra_envio' && toca.ultimo?.p_kind === 'buttons', 'tocar una tarjeta cotiza')
    comprueba(base.llamadas.some((l) => l.fn === 'sim_compra_mensaje' && l.args.p_direction === 'in' && JSON.stringify(l.args.p_payload) === JSON.stringify({ reply_id: 'compra:v:B00QES9K4G' })), 'el toque entra como texto con {reply_id}')
    await turno(base, { respuesta: { id: 'compra:envio:aereo', title: 'Envío aéreo' } }, 't4')

    const crear = await turno(
      crearBase({ bot_compra_crear: { request_id: ID1, request_number: 1001, status: 'esperando_pago', total_usd: 135.7, payment_block: 'BNC (0191)' } }, base.sesion()),
      { respuesta: { id: 'compra:confirmar', title: 'Confirmar compra' } },
      'uuid-del-turno',
    )
    comprueba(crear.estado === 'compra_pago', 'confirmar crea la solicitud')

    const pegarLink = await turno(crearBase(), { texto: 'https://www.amazon.com/dp/B0B3K9M1Z4' }, 't5')
    comprueba(pegarLink.estado === 'compra_envio', 'pegar un enlace desde el menú cotiza')
    const menu = await turno(crearBase({}, { state: 'compra_envio', data: {} }), { texto: 'menú' }, 't6')
    comprueba(menu.estado === 'menu', '«menú» vuelve al menú')
  }

  console.log('\nLa solicitud, el comprobante y la lista')
  {
    const base = crearBase({ bot_compra_crear: { request_id: ID1, request_number: 1001, status: 'esperando_pago', total_usd: 135.7, payment_block: 'BNC' } })
    await turno(base, { texto: 'https://www.amazon.com/dp/B00QES9K4G' }, 'a')
    await turno(base, { respuesta: { id: 'compra:envio:aereo', title: 'Envío aéreo' } }, 'b')
    await turno(base, { respuesta: { id: 'compra:confirmar', title: 'Confirmar compra' } }, 'uuid-confirmar')
    const crear = base.llamadas.find((l) => l.fn === 'bot_compra_crear')
    comprueba(crear?.args.p_channel === 'simulador' && crear.args.p_idempotency_key === 'uuid-confirmar', "bot_compra_crear con p_channel='simulador' y un uuid por turno como clave", JSON.stringify(crear?.args))

    const base2 = crearBase({ bot_compra_reportar_pago: { report_id: 'r1' } }, base.sesion())
    const foto = await turno(base2, { adjunto: { receipt_path: `compras/simulador/${ID1}.png` } }, 'wa-1')
    const rep = base2.llamadas.find((l) => l.fn === 'bot_compra_reportar_pago')
    comprueba(rep?.args.p_receipt_path === `compras/simulador/${ID1}.png` && rep.args.p_wa_message_id === 'wa-1', 'el comprobante del simulador va tal cual a reportar_pago', JSON.stringify(rep?.args))
    comprueba(base2.llamadas.some((l) => l.fn === 'sim_compra_mensaje' && l.args.p_direction === 'in' && l.args.p_kind === 'image' && JSON.stringify(l.args.p_payload) === JSON.stringify({ receipt_path: `compras/simulador/${ID1}.png` })), 'el adjunto entra como image {receipt_path}')
    comprueba(foto.ultimo?.p_body === 'Recibimos tu comprobante de #C-1001. Lo verificamos y te aviso por aquí.', 'respuesta al comprobante', String(foto.ultimo?.p_body))

    const mis = await turno(
      crearBase({
        bot_compra_mis_solicitudes: [{ request_id: ID1, request_number: 1024, product_title: 'Estetoscopio Littmann Classic III', status: 'esperando_pago', total_usd: 135.7, created_at: '2026-11-24T15:00:00Z' }],
      }),
      { respuesta: { id: 'compra:mis', title: 'Mis compras' } },
      'c',
    )
    const payload = mis.ultimo?.p_payload as { button: string; sections: Array<{ title: string; rows: Array<{ id: string; title: string; description: string }> }> }
    comprueba(mis.ultimo?.p_kind === 'list' && payload.button === 'Ver compras' && payload.sections[0].rows[0].id === `compra:det:${ID1}`, '«Mis compras» es una lista interactiva {button, sections:[{title, rows}]}', JSON.stringify(mis.ultimo))
    comprueba(payload.sections[0].rows[0].title.length <= 24 && payload.sections[0].rows[0].description === 'Esperando tu pago · $135,70 · mar 24/11', 'fila: título ≤24, descripción «estado · monto · fecha»', JSON.stringify(payload.sections[0].rows[0]))
  }

  console.log('\nNunca toca WhatsApp')
  {
    const base = crearBase({ bot_compra_mis_solicitudes: [], bot_compra_cancelar: { request_number: 1 }, bot_compra_pedir_persona: null })
    await turno(base, {}, '1')
    await turno(base, { texto: 'estetoscopio' }, '2')
    await turno(base, { respuesta: { id: 'compra:mis', title: 'Mis compras' } }, '3')
    await turno(base, { texto: 'persona' }, '4')
    const prohibidas = base.llamadas.filter((l) => /^helios_whatsapp_|^bot_session|^helios_dispatch/.test(l.fn))
    comprueba(prohibidas.length === 0, 'ningún helios_whatsapp_*, bot_session* ni helios_dispatch_*', prohibidas.map((l) => l.fn).join())
    const fns = new Set(base.llamadas.map((l) => l.fn))
    comprueba([...fns].every((f) => f.startsWith('sim_compra_') || f.startsWith('bot_compra_')), 'solo RPC sim_compra_* y bot_compra_*', [...fns].join())
  }

  console.log('\nEl simulador no se mezcla con las solicitudes reales')
  {
    const SEIS = ['bot_compra_pendiente_de_pago', 'bot_compra_mis_solicitudes', 'bot_compra_detalle', 'bot_compra_cancelar', 'bot_compra_recotizar', 'bot_compra_reportar_pago']
    const detalle = { request_id: ID1, request_number: 1024, status: 'esperando_pago', total_usd: 135.7, quote_expires_at: '2099-01-01T00:00:00Z', vencida: false, payment_block: 'BNC' }
    const pago = { compraId: ID1, compraNumero: '#C-1024', compraVenceEn: '2099-01-01T00:00:00Z', datosPago: {} }
    const base = crearBase({
      bot_compra_mis_solicitudes: [{ request_id: ID1, request_number: 1024, product_title: 'Estetoscopio', status: 'esperando_pago', total_usd: 135.7, created_at: '2026-11-24T15:00:00Z' }],
      bot_compra_detalle: detalle,
      bot_compra_pendiente_de_pago: { request_id: ID1, request_number: 1024, total_usd: 135.7, quote_expires_at: '2099-01-01T00:00:00Z', vencida: false },
      bot_compra_cancelar: { request_number: 1024 },
      bot_compra_recotizar: { request_id: ID1, request_number: 1024, total_usd: 140, total_anterior_usd: 135.7, quote_expires_at: '2099-01-02T00:00:00Z', payment_block: 'BNC' },
      bot_compra_reportar_pago: { report_id: 'r1' },
    })
    await turno(base, { respuesta: { id: 'compra:mis', title: 'Mis compras' } }, 'm1')
    await turno(base, { respuesta: { id: `compra:det:${ID1}`, title: '#C-1024' } }, 'm2')
    await turno(base, { respuesta: { id: 'compra:recotizar', title: 'Actualizar' } }, 'm3')
    await turno(base, { respuesta: { id: 'compra:cancelar_pedir', title: 'Cancelar compra' } }, 'm4')
    await turno(base, { respuesta: { id: 'compra:cancelar_si', title: 'Sí, cancelar' } }, 'm5')
    const conPago = crearBase({ bot_compra_pendiente_de_pago: { request_id: ID1, request_number: 1024, total_usd: 135.7, quote_expires_at: '2099-01-01T00:00:00Z', vencida: false }, bot_compra_reportar_pago: { report_id: 'r1' } }, { state: 'menu', data: {} })
    await turno(conPago, { adjunto: { receipt_path: `compras/simulador/${ID1}.png` } }, 'm6')
    await turno(crearBase({}, { state: 'compra_pago', data: pago }), { texto: 'Banesco\n04141234567\n123456789012' }, 'm7')
    const todas = [...base.llamadas, ...conPago.llamadas].filter((l) => SEIS.includes(l.fn))
    comprueba(new Set(todas.map((l) => l.fn)).size >= 5 && todas.every((l) => l.args.p_channel === 'simulador'), "toda RPC de solicitudes lleva p_channel='simulador'", JSON.stringify(todas.filter((l) => l.args.p_channel !== 'simulador').map((l) => l.fn)))
    comprueba(new Set(todas.map((l) => l.fn)).has('bot_compra_pendiente_de_pago') && new Set(todas.map((l) => l.fn)).has('bot_compra_reportar_pago'), 'incluye la recuperación del pago y el reporte')
  }

  console.log('\nEl simulador parte los mensajes largos como WhatsApp')
  {
    const llamadas: Llamada[] = []
    const t = crearTransporteSimulador({
      phone: '+584140000001',
      rpc: async <T>(fn: string, args: Record<string, unknown>) => {
        llamadas.push({ fn, args })
        return null as T
      },
    })
    await t.enviar('y'.repeat(1500), [{ id: 'compra:mis', title: 'Mis compras' }])
    const out = llamadas.map((l) => l.args)
    comprueba(out.length === 2 && out[0].p_kind === 'text' && String(out[0].p_body).length === 1500 && out[1].p_kind === 'buttons' && out[1].p_body === 'Elige una opción:', 'cuerpo >1024 con botones = texto completo + «Elige una opción:» con botones', JSON.stringify(out.map((o) => [o.p_kind, String(o.p_body).length])))
    llamadas.length = 0
    await t.enviar('corto', [{ id: 'compra:mis', title: 'Mis compras' }])
    comprueba(llamadas.length === 1 && llamadas[0].args.p_kind === 'buttons', 'cuerpo corto con botones: un solo mensaje')
  }

  if (fallos > 0) {
    console.log(`\n${fallos} fallo(s)`)
    process.exit(1)
  }
  console.log('\nTODO BIEN')
}

main()
