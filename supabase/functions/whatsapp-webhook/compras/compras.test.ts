/**
 * Pruebas del motor de Compras en Amazon para médicos: parser, traductor,
 * restricciones, cotizador (paridad con SQL), catálogo Rainforest, formato
 * exacto de la lista, y el flujo completo en `bot.ts` con una
 * base de mentira (cada RPC responde lo que diga la prueba y se anota).
 *
 *   npx tsx supabase/functions/whatsapp-webhook/compras/compras.test.ts
 */

import { atenderAlPersonal } from '../bot.ts'
import type { Personal } from '../bot.ts'
import type { EventoDeMensaje } from '../logica.ts'
import {
  analizarEnlaceAmazon,
  contieneEnlace,
  evaluarRestriccionMedica,
  extraerAsinDeTexto,
  normalizarBusquedaMedica,
} from './amazon_parser.ts'
import { CATALOGO_MEDICO_MOCK, ProveedorAmazonMock } from './catalogo_mock.ts'
import {
  ErrorCatalogo,
  ProveedorRainforest,
  crearProveedorCatalogo,
  parsearDimensionesAPulgadas,
  parsearPesoALibras,
} from './catalogo_rainforest.ts'
import { CANTIDAD_MAXIMA, calcularCotizacion, recomendarEnvio, redondearCentavos } from './cotizador.ts'
import { resolverEnlaceCorto } from './enlaces.ts'
import { botonObsoletoEnEstado, esIntentoDePago, normalizarTarifas } from './flujo.ts'
import { ETIQUETA_ESTADO } from './textos.ts'
import {
  construirSeccionesLista,
  partirMensaje,
  crearTransporteWhatsApp,
} from './transporte.ts'
import type { DatosCompra, ProveedorCatalogo, TarifasCompra } from './tipos.ts'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

/** Vocabulario prohibido hacia médicos y externos (CLAUDE.md). */
const PROHIBIDO = /pr[eé]stamo|financiamiento|financiar|cr[eé]dito|\bfee\b/i
const EMOJI = /\p{Extended_Pictographic}/gu

const PERSONAL: Personal = {
  id: 's1',
  phone_e164: '+584140000001',
  user_id: 'u1',
  staff_name: 'Ana',
  role: 'gerente',
  merchant_id: 'm1',
  merchant_name: 'Dra. Ana Lara',
}

const TARIFAS: TarifasCompra = {
  taxUsaPct: 7,
  serviceFeePct: 8,
  airRatePerLbUsd: 6.5,
  airMinUsd: 15,
  seaRatePerFt3Usd: 24,
  seaMinUsd: 35,
  fallbackWeightLb: 2,
  fxRateUsd: 100,
  accountsBlock: 'Pago Móvil:\nBNC (0191)\nRIF: J-50123456-7\nTel: 0412-5551234\nSolo en bolívares a la tasa BCV de hoy.',
}

const CONFIG_RPC = {
  is_enabled: true,
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
  accounts_block: TARIFAS.accountsBlock,
}

const ID1 = '11111111-1111-4111-8111-111111111111'
const ID2 = '22222222-2222-4222-8222-222222222222'

type Llamada = { fn: string; args: Record<string, unknown> }
type Resp = unknown | ((args: Record<string, unknown>) => unknown)

type Boton = { id: string; title: string }
type Emitido = { texto: string; botones: Boton[] }
const emitidos: Emitido[] = []
/** Toda llamada a la base de todos los turnos, y los botones enviados frente al estado en que quedó la sesión. */
const todasLasLlamadas: Llamada[] = []
const parejasBotonEstado: Array<{ id: string; estado: string }> = []

type Opciones = {
  proveedorDe?: (nombre: string) => ProveedorCatalogo | null
  humano?: boolean
  habilitada?: boolean
  resolverEnlace?: (u: string) => Promise<string | null>
  ahora?: () => Date
  almacen?: { subir(ruta: string, bytes: Uint8Array, mime: string): Promise<void> }
  fetchFn?: typeof fetch
}

const MOCK = new ProveedorAmazonMock()

async function correr(
  mensaje: Partial<EventoDeMensaje>,
  sesion: { state: string; data: Record<string, unknown>; nueva?: boolean },
  respuestas: Record<string, Resp> = {},
  o: Opciones = {},
) {
  const llamadas: Llamada[] = []
  const rpc = async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
    llamadas.push({ fn, args })
    if (fn === 'bot_session') return { nueva: false, ...sesion } as T
    if (fn === 'bot_compra_habilitada') return { habilitada: o.habilitada ?? true, proveedor: 'mock', piloto: false } as T
    const r = respuestas[fn]
    if (typeof r === 'function') return (await (r as (a: Record<string, unknown>) => unknown)(args)) as T
    if (r instanceof Error) throw r
    if (r === undefined && fn === 'bot_compra_config') return CONFIG_RPC as T
    return (r ?? null) as T
  }
  const m: EventoDeMensaje = {
    kind: 'message',
    id: 'wamid.compra.1',
    from: '584140000001',
    type: 'text',
    texto: null,
    boton: null,
    adjunto: null,
    raw: {},
    ...mensaje,
  }
  const res = await atenderAlPersonal({
    rpc,
    personal: PERSONAL,
    mensaje: m,
    humano: o.humano,
    proveedorDe: o.proveedorDe ?? ((n) => (n === 'mock' ? MOCK : null)),
    resolverEnlace: o.resolverEnlace,
    ahora: o.ahora,
    almacen: o.almacen,
    fetchFn: o.fetchFn,
  })
  const enviados = llamadas.filter((l) => l.fn === 'helios_whatsapp_text')
  const textos = enviados.map((l) => String(l.args.p_text))
  const listas = llamadas.filter((l) => l.fn === 'helios_whatsapp_list').map((l) => l.args)
  const guardados = llamadas.filter((l) => l.fn === 'bot_session_save').map((l) => l.args)
  for (const l of enviados) emitidos.push({ texto: String(l.args.p_text), botones: (l.args.p_buttons as Boton[]) ?? [] })
  for (const l of listas) emitidos.push({ texto: String(l.p_body ?? ''), botones: [] })
  const estado = guardados.at(-1)?.p_state as string | undefined
  todasLasLlamadas.push(...llamadas)
  // El toque llegará con el estado en que QUEDÓ la sesión al final del turno.
  const estadoFinal = estado ?? sesion.state
  const idsEnviados = [
    ...enviados.flatMap((l) => ((l.args.p_buttons as Boton[]) ?? []).map((b) => b.id)),
    ...listas.flatMap((l) => ((l.p_sections as Array<{ rows: Array<{ id: string }> }>) ?? []).flatMap((sec) => sec.rows.map((f) => f.id))),
  ]
  for (const id of idsEnviados) parejasBotonEstado.push({ id, estado: estadoFinal })
  const datos = (guardados.at(-1)?.p_data ?? {}) as DatosCompra
  const botones = (enviados.at(-1)?.args.p_buttons ?? []) as Boton[]
  const fns = llamadas.map((l) => l.fn)
  return { res, llamadas, textos, listas, guardados, estado, datos, botones, fns }
}

/** Una sesión de pago abierta. */
function sesionPago(extra: Partial<DatosCompra> = {}): { state: string; data: Record<string, unknown> } {
  return {
    state: 'compra_pago',
    data: { compraId: ID1, compraNumero: '#C-1001', compraTotalUsd: 135.7, compraVenceEn: '2099-01-01T00:00:00Z', datosPago: {}, ...extra },
  }
}

async function sesionDeEnvio(asin = 'B00QES9K4G') {
  const r = await correr({ texto: `https://www.amazon.com/dp/${asin}` }, { state: 'menu', data: {} })
  return r
}

async function main() {
  console.log('1. Parser de URLs y ASIN de Amazon')
  {
    const e = extraerAsinDeTexto
    comprueba(e('https://www.amazon.com/3M-Littmann-Classic-III/dp/B00QES9K4G/ref=sr_1_1') === 'B00QES9K4G', 'URL completa /dp/ASIN')
    comprueba(e('https://www.amazon.com/gp/product/b0157i0q8c?th=1') === 'B0157I0Q8C', 'URL /gp/product/ en minúsculas → mayúsculas')
    comprueba(e('https://smile.amazon.com/gp/aw/d/B07PQ8WTC4') === 'B07PQ8WTC4', 'URL smile.amazon.com/gp/aw/d/')
    comprueba(e('https://amzn.com/B07S2H3XBB') === 'B07S2H3XBB', 'URL corta amzn.com/ASIN')
    comprueba(e('https://www.amazon.com/-/es/Estetoscopio-Littmann/dp/B00QES9K4G/ref=sr_1_1?th=1') === 'B00QES9K4G', 'URL /-/es/Nombre/dp/ASIN')
    comprueba(e('https://www.amazon.es/dp/B07PQ8WTC4') === 'B07PQ8WTC4', 'otra tienda (amazon.es) también da el ASIN')
    comprueba(e('https://www.amazon.com.mx/gp/product/B07PQ8WTC4') === 'B07PQ8WTC4', 'amazon.com.mx')
    comprueba(e('https://evilamazon.com/dp/B00QES9K4G') === null, 'host no anclado a Amazon: nada')
    comprueba(e('https://example.com/amazon.com/dp/B00QES9K4G') === null, 'amazon.com en la ruta de otro sitio: nada')
    comprueba(e('B00QES9K4G') === 'B00QES9K4G', 'ASIN puro empezando por B0')
    comprueba(e('asin: 1264268505') === '1264268505', 'ISBN-10 con prefijo asin:')
    comprueba(e('V12345678') === null && e('04141234567') === null, 'no confunde cédula ni teléfono venezolano con ASIN')
    comprueba(e('estetoscopio littmann') === null, 'texto normal devuelve null')
    const corto = analizarEnlaceAmazon('mira esto https://amzn.to/3xYzAbc gracias')
    comprueba(corto?.corto === true && corto.asin === null && corto.url.startsWith('https://amzn.to/'), 'amzn.to es un enlace corto sin ASIN')
    comprueba(analizarEnlaceAmazon('https://a.co/d/abc123')?.corto === true, 'a.co es corto')
    comprueba(analizarEnlaceAmazon('https://amzn.eu/d/abc123')?.corto === true, 'amzn.eu es corto')
    comprueba(analizarEnlaceAmazon('https://www.amazon.es/dp/B07PQ8WTC4')?.esAmazonCom === false, 'amazon.es no es la tienda .com')
    comprueba(contieneEnlace('https://example.com/x') && !contieneEnlace('estetoscopio littmann'), 'contieneEnlace')
  }

  console.log('\n2. Traductor médico ES → EN')
  {
    const est = normalizarBusquedaMedica('Estetoscopio Littmann')
    comprueba(est.consultaEn.includes('stethoscope') && est.consultaEn.includes('littmann'), 'estetoscopio → stethoscope', est.consultaEn)
    const ten = normalizarBusquedaMedica('Tensiómetro digital Omron')
    comprueba(ten.consultaEn.includes('blood pressure monitor') && ten.consultaEn.includes('omron'), 'tensiómetro digital', ten.consultaEn)
    comprueba(normalizarBusquedaMedica('Oxímetro de pulso').consultaEn.includes('pulse oximeter'), 'oxímetro')
    comprueba(normalizarBusquedaMedica('Guantes de nitrilo').consultaEn.includes('nitrile'), 'guantes de nitrilo')
  }

  console.log('\n3. Restricciones médicas y aduanales')
  {
    comprueba(!evaluarRestriccionMedica('3M Littmann Classic III Monitoring Stethoscope', 'Estetoscopios').restringido, 'estetoscopio no restringido')
    comprueba(evaluarRestriccionMedica('Sterile Absorbable Surgical Suture Vicryl 3-0 with Needle').restringido, 'sutura → restringida')
    comprueba(evaluarRestriccionMedica('Dental Local Anesthetic Cartridges Lidocaine 2% + Sterile Syringes').restringido, 'anestesia dental → restringida')
    comprueba(evaluarRestriccionMedica('Toxina botulínica vial estéril').restringido, 'toxina botulínica → restringida')
  }

  console.log('\n4. Cotizador (paridad con helios_purchase_calculate)')
  {
    const littmann = CATALOGO_MEDICO_MOCK.find((p) => p.asin === 'B00QES9K4G')!
    const c = calcularCotizacion(littmann, TARIFAS, 'aereo', 1)
    comprueba(c.volumetricWeightLb === 1.22 && c.shippingUsd === 15 && c.taxUsaUsd === 7.35 && c.serviceFeeUsd === 8.4, 'aéreo liviano: mínimo $15, tax y gestión exactos')
    comprueba(c.totalUsd === 135.7 && c.totalVes === 13570, 'total $135,70 → Bs 13.570,00')
    comprueba(recomendarEnvio(littmann) === 'aereo', 'estetoscopio recomienda aéreo')
    const grande = { titulo: 'Lámpara', categoria: 'Consultorio', precioUsd: 100, pesoLb: 4, dimensionesIn: { largo: 20, ancho: 15, alto: 10 } }
    comprueba(calcularCotizacion(grande, TARIFAS, 'aereo', 1).shippingUsd === redondearCentavos(21.58 * 6.5), 'aéreo cobra el peso volumétrico')
    const autoclave = CATALOGO_MEDICO_MOCK.find((p) => p.asin === 'B09X7T2M5W')!
    comprueba(calcularCotizacion(autoclave, TARIFAS, 'maritimo', 1).shippingUsd === redondearCentavos(4.3279 * 24), 'marítimo por ft³')
    comprueba(recomendarEnvio(autoclave) === 'maritimo', 'autoclave recomienda marítimo')

    // Paridad de cantidad: 1..50 como SQL.
    comprueba(calcularCotizacion(littmann, TARIFAS, 'aereo', 99).quantity === CANTIDAD_MAXIMA, 'cantidad 99 → 50')
    comprueba(calcularCotizacion(littmann, TARIFAS, 'aereo', 0).quantity === 1 && calcularCotizacion(littmann, TARIFAS, 'aereo', -3).quantity === 1, 'cantidad 0 o negativa → 1')
    // weightEstimated: solo si faltan el peso real Y el volumétrico.
    const sinNada = { titulo: 'x', categoria: 'y', precioUsd: 50, pesoLb: null, dimensionesIn: null }
    const soloDims = { ...sinNada, dimensionesIn: { largo: 10, ancho: 10, alto: 10 } }
    const soloPeso = { ...sinNada, pesoLb: 3 }
    comprueba(calcularCotizacion(sinNada, TARIFAS, 'aereo').weightEstimated === true, 'sin peso ni dimensiones → estimado')
    comprueba(calcularCotizacion(soloDims, TARIFAS, 'aereo').weightEstimated === false, 'con dimensiones (volumétrico) pero sin peso → NO estimado')
    comprueba(calcularCotizacion(soloPeso, TARIFAS, 'aereo').weightEstimated === false && calcularCotizacion(soloPeso, TARIFAS, 'aereo').weightRealLb === 3, 'con peso real → no estimado')
    comprueba(calcularCotizacion(sinNada, TARIFAS, 'maritimo').shippingUsd === 35, 'marítimo sin dimensiones: 0,5 ft³ → mínimo')
    // Cantidad × peso: aéreo 3 u × 4 lb = 12 lb × 6,5 = 78.
    comprueba(calcularCotizacion(soloPeso, TARIFAS, 'aereo', 3).shippingUsd === 58.5, 'aéreo multiplica el peso por la cantidad', String(calcularCotizacion(soloPeso, TARIFAS, 'aereo', 3).shippingUsd))
    // Tarifas: sin tasa no hay cotización.
    comprueba(normalizarTarifas({ ...CONFIG_RPC, fx_rate_usd: null }) === null, 'sin tasa BCV → no hay tarifas (nunca se inventa)')
    comprueba(normalizarTarifas({ ...CONFIG_RPC, air_rate_per_lb_usd: undefined }) === null, 'falta una tarifa → no hay tarifas')
    comprueba(normalizarTarifas(CONFIG_RPC)?.fxRateUsd === 100, 'tarifas completas')
  }

  console.log('\n5. Catálogo: mock, Rainforest y fábrica')
  {
    comprueba(CATALOGO_MEDICO_MOCK.length === 24, 'catálogo mock con 24 productos')
    comprueba(crearProveedorCatalogo('mock', '')?.nombre === 'mock', 'fábrica: mock')
    comprueba(crearProveedorCatalogo('rainforest', '') === null, 'fábrica: rainforest SIN clave → null (jamás cae a mock)')
    comprueba(crearProveedorCatalogo('rainforest', 'k')?.nombre === 'rainforest', 'fábrica: rainforest con clave')
    comprueba(crearProveedorCatalogo('otro', 'k') === null, 'fábrica: proveedor desconocido → null')

    comprueba(parsearPesoALibras('14.4 ounces') === 0.9, '14.4 oz = 0,9 lb')
    comprueba(parsearPesoALibras('2.5 kilograms') === 5.51, '2.5 kg = 5,51 lb')
    comprueba(parsearPesoALibras('1,200 grams') === 2.65, '«1,200 grams» es 1.200 g (separador de miles) = 2,65 lb', String(parsearPesoALibras('1,200 grams')))
    comprueba(parsearPesoALibras('1,5 kg') === 3.31, '«1,5 kg» es coma decimal = 3,31 lb', String(parsearPesoALibras('1,5 kg')))
    comprueba(parsearPesoALibras('1 lb 4 oz') === 1.25, '«1 lb 4 oz» = 1,25 lb', String(parsearPesoALibras('1 lb 4 oz')))
    comprueba(parsearPesoALibras('5 pounds (2.27 kg)') === 5, 'dos medidas equivalentes: la primera', String(parsearPesoALibras('5 pounds (2.27 kg)')))
    comprueba(parsearPesoALibras('sin peso') === null, 'sin unidad → null')
    const dimsCm = parsearDimensionesAPulgadas('25.4 x 12.7 x 5.08 cm')
    comprueba(dimsCm?.largo === 10 && dimsCm?.ancho === 5 && dimsCm?.alto === 2, 'cm → pulgadas')
    const dimsD = parsearDimensionesAPulgadas('1.18"D x 2.36"W x 1.57"H')
    comprueba(dimsD?.largo === 1.18 && dimsD?.alto === 1.57, 'formato Amazon «1.18"D x 2.36"W x 1.57"H»', JSON.stringify(dimsD))

    const respuesta = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
    const fakeFetch = (fn: (url: string) => Response | Promise<Response>) => (async (input: string | URL | Request) => fn(String(input))) as typeof fetch

    const rf = new ProveedorRainforest(
      'clave-secreta',
      'amazon.com',
      fakeFetch((url) =>
        url.includes('type=search')
          ? respuesta({
              request_info: { success: true },
              search_results: [
                { asin: 'B0TEST0001', title: 'Test Medical Otoscope LED', price: { value: 95.5 }, image: 'https://example.com/img.png', link: 'https://www.amazon.com/dp/B0TEST0001', rating: 4.8, ratings_total: 420, is_prime: true },
                { asin: 'B0TEST0002', title: 'Sin precio', image: 'https://example.com/2.png' },
                { asin: 'B0TEST0003', title: 'Sin foto', price: { value: 10 } },
              ],
            })
          : respuesta({
              request_info: { success: true },
              product: {
                asin: 'B0TEST0001',
                title: 'Test Medical Otoscope LED',
                buybox_winner: { price: { value: 95.5 }, is_prime: true, availability: { type: 'in_stock' } },
                specifications: [
                  { name: 'Weight Capacity', value: '300 pounds' },
                  { name: 'Package Weight', value: '2 pounds' },
                  { name: 'Item Weight', value: '16 ounces' },
                  { name: 'Package Dimensions', value: '10 x 5 x 2 inches' },
                ],
                variants: [{ title: 'Negro' }, { title: 'Azul' }],
                feature_bullets: ['Iluminación LED clínica'],
              },
            }),
      ),
    )
    const buscado = await rf.buscar('otoscopio', 4)
    comprueba(buscado.length === 2 && buscado[0].asin === 'B0TEST0001', 'buscar: descarta los resultados sin precio')
    comprueba(buscado[1].imagenUrl === '', 'sin foto: imagenUrl vacía (no se inventa un placeholder)', buscado[1].imagenUrl)
    const det = await rf.detalle('B0TEST0001')
    comprueba(det?.pesoLb === 1 && det.dimensionesIn?.largo === 10 && det.variantes.length === 2, 'detalle: «Item Weight» manda sobre «Weight Capacity» y «Package Weight»', JSON.stringify(det?.pesoLb))
    comprueba(det?.imagenUrl === '', 'detalle sin imagen: vacía, sin placeholder de terceros')

    const sinPrecio = new ProveedorRainforest('k', 'amazon.com', fakeFetch(() => respuesta({ request_info: { success: true }, product: { title: 'Algo', buybox_winner: { availability: { type: 'in_stock' } } } })))
    const dSin = await sinPrecio.detalle('B0TEST0009')
    comprueba(dSin?.disponible === false, 'sin precio → disponible=false')
    const pesoTop = new ProveedorRainforest('k', 'amazon.com', fakeFetch(() => respuesta({ request_info: { success: true }, product: { title: 'A', weight: '540 g', buybox_winner: { price: { value: 5 } } } })))
    comprueba((await pesoTop.detalle('B0TEST0010'))?.pesoLb === 1.19, '`weight` de producto («540 g») = 1,19 lb')

    async function falla(f: typeof fetch): Promise<ErrorCatalogo | null> {
      try {
        await new ProveedorRainforest('clave-secreta', 'amazon.com', f).buscar('estetoscopio')
        return null
      } catch (e) {
        return e instanceof ErrorCatalogo ? e : null
      }
    }
    const e429 = await falla(fakeFetch(() => respuesta({}, 429)))
    comprueba(e429?.tipo === 'limite', '429 → error «limite» distinto', e429?.tipo)
    const e500 = await falla(fakeFetch(() => respuesta({}, 500)))
    comprueba(e500?.tipo === 'http', '500 → error «http»')
    const eRechazo = await falla(fakeFetch(() => respuesta({ request_info: { success: false, message: 'x' } }, 200)))
    comprueba(eRechazo?.tipo === 'rechazo', 'HTTP 200 con success:false → error «rechazo»', eRechazo?.tipo)
    const eRed = await falla((async (u: string | URL | Request) => {
      throw new TypeError(`fetch failed ${String(u)}`)
    }) as typeof fetch)
    comprueba(eRed?.tipo === 'red' && !/clave-secreta|api_key|http/i.test(eRed.message), 'error de red: sin URL ni clave en el mensaje', eRed?.message)
    const eTiempo = await falla((async () => {
      throw new DOMException('timeout', 'TimeoutError')
    }) as typeof fetch)
    comprueba(eTiempo?.tipo === 'timeout', 'timeout → error «timeout»')
    let senal: AbortSignal | null | undefined
    await new ProveedorRainforest('k', 'amazon.com', (async (_u: string | URL | Request, init?: RequestInit) => {
      senal = init?.signal
      return respuesta({ request_info: { success: true }, search_results: [] })
    }) as typeof fetch).buscar('estetoscopio')
    comprueba(senal instanceof AbortSignal, 'la consulta lleva AbortSignal.timeout')
  }

  console.log('\n6. Formato exacto de la lista (Meta Cloud API)')
  {
    const sec = construirSeccionesLista('Tus compras', Array.from({ length: 12 }, (_, i) => ({ id: `compra:det:${i}`, title: `#C-10${i} · ${'Producto largo '.repeat(3)}`, description: 'x'.repeat(100) })))
    comprueba(
      sec.length === 1 && sec[0].rows.length === 10 && sec[0].rows.every((r) => r.title.length <= 24 && r.description.length <= 72),
      'lista: ≤10 filas, título ≤24 y descripción ≤72',
    )
    comprueba(Object.keys(sec[0].rows[0]).sort().join() === 'description,id,title', 'fila de lista: {id,title,description}')

    // El transporte de WhatsApp manda exactamente eso a la RPC.
    const llamadas: Llamada[] = []
    const t = crearTransporteWhatsApp({
      rpc: async <T>(fn: string, args: Record<string, unknown>) => {
        llamadas.push({ fn, args })
        return null as T
      },
      personal: { phone_e164: '+584140000001', user_id: 'u1' },
    })
    await t.enviar('x'.repeat(1500), [{ id: 'a', title: 'Un título larguísimo de botón' }])
    comprueba(llamadas.length === 2 && (llamadas[0].args.p_buttons as Boton[]).length === 0 && (llamadas[1].args.p_buttons as Boton[])[0].title.length <= 20, 'cuerpo >1024 con botones: texto aparte y botones aparte, título ≤20')
    await t.enviarLista('Tus compras', 'Ver compras', [{ id: 'compra:det:1', title: '#C-1', description: 'En camino' }])
    const secs = llamadas[2].args.p_sections as Array<{ rows: Array<{ id: string; description: string }> }>
    comprueba(llamadas[2].fn === 'helios_whatsapp_list' && llamadas[2].args.p_button === 'Ver compras' && secs[0].rows[0].id === 'compra:det:1' && secs[0].rows[0].description === 'En camino', 'WhatsApp: la lista se encola con helios_whatsapp_list', JSON.stringify(llamadas[2]))
    const falla = crearTransporteWhatsApp({
      rpc: async <T>(fn: string, args: Record<string, unknown>) => {
        llamadas.push({ fn, args })
        if (fn === 'helios_whatsapp_list') throw { code: '22023' }
        return null as T
      },
      personal: { phone_e164: '+584140000001', user_id: 'u1' },
    })
    const antes = llamadas.length
    const errOriginal = console.error
    console.error = () => {}
    await falla.enviarLista('Tus compras', 'Ver compras', [{ id: 'compra:det:1', title: '#C-1', description: 'En camino' }])
    console.error = errOriginal
    comprueba(llamadas[antes + 1]?.fn === 'helios_whatsapp_text' && String(llamadas[antes + 1].args.p_text).includes('1. #C-1'), 'WhatsApp: si la RPC de lista falla, sale como texto numerado')
  }

  console.log('\n7. Habilitación por número: apagado = exactamente el menú anterior')
  {
    const off = await correr({ texto: 'hola' }, { state: 'menu', data: {}, nueva: true }, {}, { habilitada: false })
    comprueba(off.botones.map((b) => b.id).join() === 'menu:nuevo,menu:mis,menu:ayuda' && off.botones[2].title === 'Ayuda', 'apagado: botones Nuevo · Mis · Ayuda', JSON.stringify(off.botones))
    comprueba(off.textos[0].endsWith('¿Qué quieres hacer?') && !off.textos[0].includes('ayuda'), 'apagado: el saludo de siempre, sin «ayuda»', off.textos[0])
    const tres = await correr({ texto: '3' }, { state: 'menu', data: {} }, {}, { habilitada: false })
    comprueba(tres.textos[0]?.startsWith('Así funciona') && !tres.textos[0].includes('Amazon'), 'apagado: «3» es la ayuda, sin mención a Amazon', tres.textos[0])
    const comprar = await correr({ boton: 'menu:comprar', texto: 'Comprar en Amazon' }, { state: 'menu', data: {} }, {}, { habilitada: false })
    comprueba(comprar.textos[0]?.startsWith('No entendí') && !comprar.fns.some((f) => f.startsWith('bot_compra_c')), 'apagado: «Comprar» no entra a compras', comprar.textos[0])
    const link = await correr({ texto: 'https://www.amazon.com/dp/B0B3K9M1Z4' }, { state: 'menu', data: {} }, {}, { habilitada: false })
    comprueba(link.textos[0]?.startsWith('No entendí'), 'apagado: pegar un enlace no cotiza')
    const vieja = await correr({ texto: 'estetoscopio' }, { state: 'compra_buscar', data: {} }, {}, { habilitada: false })
    comprueba(vieja.textos[0]?.startsWith('No entendí'), 'apagado: una sesión de compra vieja no sigue')
    const rpcFalla = await correr({ texto: 'hola' }, { state: 'menu', data: {}, nueva: true }, { bot_compra_habilitada: new Error('boom') })
    comprueba(rpcFalla.botones[2]?.title === 'Comprar en Amazon' || rpcFalla.botones[2]?.title === 'Ayuda', 'si la base falla no se cae (rama apagada o encendida)')

    const on = await correr({ texto: 'hola' }, { state: 'menu', data: {}, nueva: true })
    comprueba(on.botones.map((b) => b.id).join() === 'menu:nuevo,menu:mis,menu:comprar' && on.textos[0].includes('«ayuda»'), 'encendido: Comprar en Amazon y mención a «ayuda»', JSON.stringify(on.botones))
    const ayuda = await correr({ texto: 'ayuda' }, { state: 'menu', data: {} })
    comprueba(ayuda.textos[0].includes('Comprar en Amazon'), 'encendido: la ayuda menciona las compras')
    const gate = ayuda.llamadas.find((l) => l.fn === 'bot_compra_habilitada')
    comprueba(gate?.args.p_phone === '+584140000001', 'bot_compra_habilitada(p_phone)')
  }

  console.log('\n8. Búsqueda → lista numerada → detalle')
  let sesionResultados: Record<string, unknown> = {}
  {
    const ini = await correr({ boton: 'menu:comprar', texto: 'Comprar en Amazon' }, { state: 'menu', data: {} })
    comprueba(ini.estado === 'compra_buscar', 'menu:comprar → compra_buscar')

    const r = await correr({ texto: 'estetoscopio' }, { state: 'compra_buscar', data: {} }, { bot_compra_cache_get: new Error('x'), bot_compra_cache_set: new Error('x') })
    const c = r.listas[0]
    const filas = ((c?.p_sections ?? []) as Array<{ rows: Array<{ id: string; title: string; description: string }> }>)[0]?.rows ?? []
    const cuerpo = String(c?.p_body ?? '')
    comprueba(r.listas.length === 1 && filas.length === 3 && r.textos.length === 0, 'varios resultados → UNA lista (helios_whatsapp_list) con 3 filas, sin carrusel ni texto aparte', JSON.stringify(r.fns))
    comprueba(!r.fns.includes('helios_whatsapp_carousel'), 'jamás se usa helios_whatsapp_carousel')
    comprueba(
      cuerpo.startsWith('Encontré 3 opciones para «estetoscopio». Elige una para cotizarla. Si no es lo que buscas, escribe otra búsqueda.'),
      'el cuerpo empieza con el conteo y la consulta',
      cuerpo,
    )
    comprueba(
      cuerpo.includes('1. 3M Littmann') && cuerpo.includes('\nAmazon: $104,95 · Puesto en Venezuela aprox.: $135,70') && cuerpo.includes('\n\n2. ') && cuerpo.includes('\n\n3. '),
      'el cuerpo resume cada resultado numerado con «Amazon» y «Puesto en Venezuela aprox.»',
      cuerpo,
    )
    comprueba(cuerpo.length <= 1024, 'el cuerpo no pasa de 1024 caracteres', String(cuerpo.length))
    comprueba(c.p_button === 'Ver opciones', 'botón «Ver opciones»')
    comprueba(
      filas[0].id === 'compra:v:B00QES9K4G' && filas[0].title.startsWith('1. ') && filas[1].title.startsWith('2. ') && filas[0].description === 'Amazon $104,95 · Venezuela aprox. $135,70',
      'filas: id compra:v:<ASIN>, título «N. …» y descripción «Amazon $… · Venezuela aprox. $…»',
      JSON.stringify(filas[0]),
    )
    comprueba(filas.every((f) => f.id.length <= 200 && f.title.length <= 24 && f.description.length <= 72), 'filas: id ≤200, título ≤24 y descripción ≤72')
    const sec1 = ((c?.p_sections ?? []) as Array<{ title: string }>)[0]
    comprueba(sec1.title.length <= 24 && (c.p_button as string).length <= 20, 'sección ≤24 y botón ≤20')
    comprueba(r.estado === 'compra_resultados', 'guarda compra_resultados')
    sesionResultados = r.datos as Record<string, unknown>

    // Escribir un número válido.
    const n2 = await correr({ texto: '2' }, { state: 'compra_resultados', data: sesionResultados })
    comprueba(n2.estado === 'compra_envio', 'escribir «2» elige la segunda opción')
    const n9 = await correr({ texto: '9' }, { state: 'compra_resultados', data: sesionResultados })
    comprueba(n9.estado === undefined || n9.estado === 'compra_resultados', 'un número fuera de lo visible no elige nada')
    comprueba((n9.textos[0] ?? '').includes('del 1 al 3'), '…y dice el rango visible', n9.textos[0])

    // Títulos larguísimos y consulta larga: el cuerpo se acorta, nunca pasa de 1024.
    const largos: ProveedorCatalogo = {
      nombre: 'mock',
      buscar: async (q, l) => (await MOCK.buscar(q, l)).map((p) => ({ ...p, titulo: `${p.titulo} ${'extra largo '.repeat(40)}` })),
      detalle: (a) => MOCK.detalle(a),
    }
    const lg = await correr({ texto: 'estetoscopio '.repeat(5).trim() }, { state: 'compra_buscar', data: {} }, {}, { proveedorDe: () => largos })
    const cuerpoLg = String(lg.listas[0]?.p_body ?? '')
    comprueba(lg.listas.length === 1 && cuerpoLg.length > 0 && cuerpoLg.length <= 1024 && cuerpoLg.includes('3. '), 'títulos larguísimos: el cuerpo se acorta y sigue ≤1024 con todos los resultados', String(cuerpoLg.length))

    // Sin fotos: igual, una lista (las fotos ya no hacen falta).
    const sinFoto: ProveedorCatalogo = {
      nombre: 'mock',
      buscar: async (q, l) => (await MOCK.buscar(q, l)).map((p) => ({ ...p, imagenUrl: '' })),
      detalle: (a) => MOCK.detalle(a),
    }
    const sf = await correr({ texto: 'estetoscopio' }, { state: 'compra_buscar', data: {} }, {}, { proveedorDe: () => sinFoto })
    comprueba(sf.listas.length === 1 && sf.textos.length === 0, 'sin fotos también sale la lista', JSON.stringify(sf.fns))

    // Si la RPC de la lista falla, el mismo cuerpo sale como texto numerado y la sesión sigue.
    const errLista = console.error
    console.error = () => {}
    const sinLista = await correr({ texto: 'estetoscopio' }, { state: 'compra_buscar', data: {} }, { helios_whatsapp_list: Object.assign(new Error('helios_whatsapp_list: x'), { code: '22023' }) })
    console.error = errLista
    comprueba(sinLista.estado === 'compra_resultados' && sinLista.textos.length === 1 && sinLista.textos[0].includes('1. 3M Littmann') && sinLista.textos[0].includes('Responde con el número de la opción.') && !sinLista.fns.includes('helios_whatsapp_carousel'), 'lista caída: texto numerado, el turno sigue', sinLista.textos[0])
    comprueba(sinLista.llamadas.filter((l) => l.fn === 'helios_whatsapp_list').length === 1, 'la lista se intenta una sola vez')

    // Un botón de una búsqueda anterior (ASIN que ya no está) no cotiza nada.
    const viejo = await correr({ boton: 'compra:v:B0XXXXXXXX', texto: 'Cotizar' }, { state: 'compra_resultados', data: sesionResultados })
    comprueba((viejo.textos[0] ?? '').startsWith('Esa opción ya no está activa'), 'una fila vieja (ASIN que no está en la búsqueda actual) es un botón obsoleto', viejo.textos[0])
    const fueraDeEstado = await correr({ boton: 'compra:v:B00QES9K4G', texto: 'Cotizar' }, { state: 'compra_buscar', data: {} })
    comprueba((fueraDeEstado.textos[0] ?? '').startsWith('Esa opción ya no está activa'), 'una fila tocada fuera de compra_resultados es un botón obsoleto', fueraDeEstado.textos[0])

    // Un solo resultado → directo al detalle.
    const uno = await correr({ texto: 'autoclave' }, { state: 'compra_buscar', data: {} })
    comprueba(uno.listas.length === 0 && uno.estado === 'compra_envio' && uno.textos[0].includes('Autoclave'), 'un solo resultado va directo al detalle')

    // Ver detalle desde una fila de la lista.
    const ver = await correr({ boton: 'compra:v:B00QES9K4G', texto: 'Cotizar' }, { state: 'compra_resultados', data: sesionResultados })
    const t = ver.textos[0]
    comprueba(ver.estado === 'compra_envio', 'tocar una fila de la lista → compra_envio')
    comprueba(!t.includes('Bs') && !/bol[ií]vares/i.test(t), 'el detalle NO lleva bolívares', t)
    comprueba(t.includes('• *Aéreo* · $135,70 · llega en 7–12 días') && t.includes('• *Marítimo* · $') && t.includes('llega en 3–5 semanas'), 'aéreo y marítimo con todo incluido y ETA', t)
    comprueba(t.includes('Elige cómo traerlo (todo incluido):') && t.includes('Todo incluido = producto + impuesto EE. UU. + envío + gestión Helios.'), 'explica «todo incluido»', t)
    comprueba(t.includes('Peso: 1,10 lb'), 'muestra el peso', t)
    comprueba(ver.botones.map((b) => b.title).join() === 'Envío aéreo,Envío marítimo,Buscar otro', 'botones del detalle', JSON.stringify(ver.botones))

    const auto = await correr({ texto: 'https://www.amazon.com/dp/B09X7T2M5W' }, { state: 'menu', data: {} })
    comprueba(/Te recomiendo marítimo: ahorras \$\d+/.test(auto.textos[0]), 'recomienda marítimo y dice cuánto ahorra', auto.textos[0])

    const sinPeso = await correr({ texto: 'https://www.amazon.com/dp/B0B3K9M1Z4' }, { state: 'menu', data: {} })
    comprueba(sinPeso.textos[0].includes('Amazon no publica el peso; calculo con 2 lb y, si pesa más al llegar al almacén, te aviso antes de cobrar la diferencia.'), 'peso estimado: aviso exacto', sinPeso.textos[0])

    const restr = await correr({ texto: 'https://www.amazon.com/dp/B09D4S7V2X' }, { state: 'menu', data: {} })
    comprueba(restr.textos[0].includes('revisión aduanal (aprox. 1 día hábil) antes de poder pagarlo'), 'restringido: avisa de la revisión ANTES de confirmar', restr.textos[0])
    const restrConf = await correr({ boton: 'compra:envio:aereo', texto: 'Envío aéreo' }, { state: 'compra_envio', data: restr.datos })
    comprueba(restrConf.botones[0].title === 'Pedir revisión', 'restringido: el botón dice «Pedir revisión»', JSON.stringify(restrConf.botones))
  }

  console.log('\n9. Cantidad')
  {
    const env = await sesionDeEnvio('B00QES9K4G')
    const x3 = await correr({ texto: 'x3' }, { state: 'compra_envio', data: env.datos })
    comprueba(x3.estado === 'compra_envio' && x3.datos.cantidad === 3 && x3.textos[0].includes('Cantidad: 3'), '«x3» en el detalle recalcula con 3 unidades', x3.textos[0])
    const u = await correr({ texto: '4 unidades' }, { state: 'compra_envio', data: env.datos })
    comprueba(u.datos.cantidad === 4, '«4 unidades»')
    const uno = await correr({ texto: '1' }, { state: 'compra_envio', data: env.datos })
    comprueba(uno.estado === 'compra_confirmar' && uno.datos.envio === 'aereo', '«1» sigue siendo «aéreo» en el detalle')
    const mil = await correr({ texto: 'x50' }, { state: 'compra_envio', data: env.datos })
    comprueba(/persona/.test(mil.textos[0]) && mil.datos.cantidad === 1, 'más de 10: ofrece una persona', mil.textos[0])

    const conf = await correr({ boton: 'compra:envio:aereo', texto: 'Envío aéreo' }, { state: 'compra_envio', data: env.datos })
    const t = conf.textos[0]
    comprueba(
      t.includes('• Producto · $104,95') && t.includes('• Impuesto EE. UU. · $7,35') && t.includes('• Envío aéreo · $15') && t.includes('• Gestión Helios · $8,40') && t.includes('*Total: $135,70*'),
      'confirmación itemizada: Producto · Impuesto EE. UU. · Envío aéreo · Gestión Helios · Total',
      t,
    )
    comprueba(t.includes('Llega en 7–12 días') && /Precio válido hasta \w{3} \d\d\/\d\d \d\d:\d\d\./.test(t), 'ETA y «Precio válido hasta» en hora de Caracas', t)
    comprueba(!t.includes('Bs') && conf.botones.map((b) => b.title).join() === 'Confirmar compra,Cambiar envío,Cambiar cantidad', 'sin bolívares; botones Confirmar / Cambiar envío / Cambiar cantidad', JSON.stringify(conf.botones))
    const cc = await correr({ boton: 'compra:cantidad', texto: 'Cambiar cantidad' }, { state: 'compra_confirmar', data: conf.datos })
    comprueba(cc.estado === 'compra_cantidad' && cc.textos[0] === '¿Cuántas unidades? Escribe un número del 1 al 10.', 'compra_cantidad', cc.textos[0])
    const cn = await correr({ texto: '3' }, { state: 'compra_cantidad', data: cc.datos })
    comprueba(cn.estado === 'compra_confirmar' && cn.datos.cantidad === 3, 'un número en compra_cantidad vuelve a la confirmación con la cantidad nueva')
    const cx = await correr({ texto: 'abc' }, { state: 'compra_cantidad', data: cc.datos })
    comprueba(cx.textos[0].includes('del 1 al 10'), 'cantidad inválida se repite')
  }

  console.log('\n10. Confirmar: bot_compra_crear (idempotente), total del servidor y pago')
  {
    const env = await sesionDeEnvio()
    const conf = await correr({ boton: 'compra:envio:aereo', texto: 'Envío aéreo' }, { state: 'compra_envio', data: env.datos })
    const crear = await correr(
      { boton: 'compra:confirmar', texto: 'Confirmar compra', id: 'wamid.crear.1' },
      { state: 'compra_confirmar', data: conf.datos },
      { bot_compra_crear: { request_id: ID1, request_number: 1001, status: 'esperando_pago', restricted_flag: false, total_usd: 135.7, quoted_ves: 13570, quote_expires_at: '2099-01-01T16:30:00Z', payment_block: '💳 *Datos para pagar*\nTotal: *$135,70* · *Bs 13.570,00*\nBNC (0191)' } },
    )
    const llamada = crear.llamadas.find((l) => l.fn === 'bot_compra_crear')
    comprueba(
      llamada?.args.p_asin === 'B00QES9K4G' && llamada.args.p_shipping_method === 'aereo' && llamada.args.p_channel === 'whatsapp' && llamada.args.p_idempotency_key === 'wamid.crear.1' && llamada.args.p_session_total_usd === 135.7,
      'bot_compra_crear con p_idempotency_key = id del mensaje, p_session_total_usd y p_channel whatsapp',
      JSON.stringify(llamada?.args),
    )
    comprueba(llamada?.args.p_weight_lb === 1.1 && llamada.args.p_weight_estimated === false, 'pasa el peso real y p_weight_estimated=false')
    comprueba(crear.estado === 'compra_pago' && crear.datos.compraId === ID1 && crear.datos.compraNumero === '#C-1001', 'compra_pago con la solicitud', JSON.stringify(crear.datos))
    comprueba(crear.textos.join('\n').includes('Solicitud #C-1001 creada · *$135,70*') && crear.textos.join('\n').includes('BNC (0191)') && crear.textos.join('\n').includes('Precio válido hasta'), 'usa el total y el bloque de pago del servidor, con validez', crear.textos.join('\n'))
    comprueba(crear.botones.map((b) => b.title).join() === 'Ya pagué,Escribir datos,Mis compras', 'botones de pago')

    const cambio = await correr(
      { boton: 'compra:confirmar', id: 'wamid.crear.2' },
      { state: 'compra_confirmar', data: conf.datos },
      { bot_compra_crear: { request_id: ID1, request_number: 1001, status: 'esperando_pago', total_usd: 140, total_cambio: true, payment_block: 'BNC' } },
    )
    comprueba(cambio.textos.join('\n').includes('Ojo: el total final es $140'), 'total_cambio: avisa que el total del servidor es otro', cambio.textos.join('\n'))

    // Las tarifas cambiaron desde la cotización: se muestra el precio nuevo y NO se crea.
    const nuevoPrecio = await correr(
      { boton: 'compra:confirmar', id: 'wamid.crear.3' },
      { state: 'compra_confirmar', data: conf.datos },
      { bot_compra_config: { ...CONFIG_RPC, fx_rate_usd: 100, air_min_usd: 30 } },
    )
    comprueba(!nuevoPrecio.fns.includes('bot_compra_crear') && nuevoPrecio.textos[0].includes('El precio cambió: antes $135,70, ahora $150,70') && nuevoPrecio.estado === 'compra_confirmar', 'al confirmar se vuelve a leer la configuración: si cambió el precio, se muestra y no se crea', nuevoPrecio.textos[0])

    const sinTasa = await correr(
      { boton: 'compra:confirmar', id: 'wamid.crear.4' },
      { state: 'compra_confirmar', data: conf.datos },
      { bot_compra_config: { ...CONFIG_RPC, fx_rate_usd: null } },
    )
    comprueba(!sinTasa.fns.includes('bot_compra_crear') && sinTasa.textos[0].includes('no puedo cotizar'), 'sin tasa BCV no se crea nada y se dice', sinTasa.textos[0])

    const restr = await correr({ texto: 'https://www.amazon.com/dp/B09D4S7V2X' }, { state: 'menu', data: {} })
    const restrEnv = await correr({ boton: 'compra:envio:aereo' }, { state: 'compra_envio', data: restr.datos })
    const r2 = await correr(
      { boton: 'compra:confirmar', id: 'wamid.restr.1' },
      { state: 'compra_confirmar', data: restrEnv.datos },
      { bot_compra_crear: { request_id: ID2, request_number: 1002, status: 'revision_aduanal', restricted_flag: true } },
    )
    comprueba(r2.textos[0].includes('#C-1002') && r2.textos[0].includes('revisión aduanal') && r2.estado !== 'compra_pago', 'restringido: queda en revisión aduanal, sin pago')
  }

  console.log('\n11. Comprobante: se baja de 360dialog y se guarda en payment-receipts')
  {
    const subidos: Array<{ ruta: string; bytes: number; mime: string }> = []
    const fetchFn = (async (input: string | URL | Request) => {
      const url = String(input)
      if (url.endsWith('/media-999')) return new Response(JSON.stringify({ url: 'https://lookaside.fbsbx.com/whatsapp_business/attachments/?mid=1' }), { status: 200 })
      return new Response(new Uint8Array([1, 2, 3, 4]), { status: 200 })
    }) as typeof fetch
    const almacen = { subir: async (ruta: string, bytes: Uint8Array, mime: string) => void subidos.push({ ruta, bytes: bytes.length, mime }) }
    const foto = await correr(
      { type: 'image', id: 'wamid.foto.1', adjunto: { id: 'media-999', mime: 'image/jpeg' } },
      sesionPago(),
      { lector_config: { d360_api_key: 'K', d360_base_url: 'https://waba.360dialog.io/v1/media' }, bot_compra_reportar_pago: { report_id: 'r1' } },
      { almacen, fetchFn },
    )
    const rep = foto.llamadas.find((l) => l.fn === 'bot_compra_reportar_pago')
    comprueba(subidos.length === 1 && subidos[0].ruta === `compras/${ID1}/media-999.jpg` && subidos[0].bytes === 4, 'sube el archivo a compras/<solicitud>/<media>.jpg', JSON.stringify(subidos))
    comprueba(rep?.args.p_receipt_path === `compras/${ID1}/media-999.jpg` && rep.args.p_wa_message_id === 'wamid.foto.1' && rep.args.p_amount_ves === null, 'bot_compra_reportar_pago con la ruta REAL y p_wa_message_id', JSON.stringify(rep?.args))
    comprueba(foto.textos[0] === 'Recibimos tu comprobante de #C-1001. Lo verificamos y te aviso por aquí.', 'confirmación del comprobante', foto.textos[0])

    const ya = await correr({ type: 'image', id: 'wamid.foto.1', adjunto: { id: 'media-999', mime: 'image/jpeg' } }, sesionPago(), { lector_config: { d360_api_key: 'K', d360_base_url: 'https://waba.360dialog.io/v1/media' }, bot_compra_reportar_pago: { ya_registrado: true } }, { almacen, fetchFn })
    comprueba(ya.textos[0].includes('ya lo habíamos recibido'), 'ya_registrado: no duplica y lo dice')

    const sinAlmacen = await correr({ type: 'image', id: 'wamid.foto.2', adjunto: { id: 'media-999', mime: 'image/jpeg' } }, sesionPago(), { lector_config: { d360_api_key: 'K', d360_base_url: 'https://x' } }, { fetchFn })
    comprueba(!sinAlmacen.fns.includes('bot_compra_reportar_pago') && sinAlmacen.textos[0].includes('No pude guardar tu comprobante'), 'si no se puede guardar, no se reporta y se pide de nuevo')

    const datos = await correr({ texto: 'Banesco\n04141234567\n123456789012', id: 'wamid.datos.1' }, sesionPago(), { bot_compra_reportar_pago: { report_id: 'r2' } })
    const repD = datos.llamadas.find((l) => l.fn === 'bot_compra_reportar_pago')
    comprueba(repD?.args.p_bank === 'Banesco' && repD.args.p_payer_phone === '04141234567' && repD.args.p_wa_message_id === 'wamid.datos.1', 'datos escritos: reportar_pago con p_wa_message_id')
    comprueba(datos.textos[0].includes('Registramos tu Pago Móvil de #C-1001') && datos.textos[0].endsWith('Si pagaste un monto distinto, dímelo.'), 'datos escritos: dice «Si pagaste un monto distinto, dímelo.»', datos.textos[0])

    const vencida = await correr({ type: 'image', id: 'wamid.foto.3', adjunto: { id: 'media-999', mime: 'image/png' } }, sesionPago(), {
      lector_config: { d360_api_key: 'K', d360_base_url: 'https://waba.360dialog.io/v1/media' },
      bot_compra_reportar_pago: Object.assign(new Error('bot_compra_reportar_pago: cotizacion_vencida: la cotización venció'), { code: 'P0001' }),
    }, { almacen, fetchFn })
    comprueba(vencida.textos[0].includes('venció') && vencida.botones.map((b) => b.title).join() === 'Actualizar,Cancelar compra,Mis compras', 'cotizacion_vencida del servidor: ofrece actualizar', vencida.textos[0])
  }

  console.log('\n12. El pago no se pierde (sesión vencida, «ayuda», «menú»)')
  {
    const pend = { request_id: ID1, request_number: 1001, total_usd: 135.7, quote_expires_at: '2099-01-01T00:00:00Z', vencida: false, status: 'esperando_pago' }
    const subidos: string[] = []
    const fetchFn = (async (input: string | URL | Request) =>
      String(input).endsWith('/media-7')
        ? new Response(JSON.stringify({ url: 'https://l.test/x?mid=1' }), { status: 200 })
        : new Response(new Uint8Array([9]), { status: 200 })) as typeof fetch
    const almacen = { subir: async (ruta: string) => void subidos.push(ruta) }
    const cfg = { lector_config: { d360_api_key: 'K', d360_base_url: 'https://waba.360dialog.io/v1/media' } }

    const foto = await correr({ type: 'image', id: 'wamid.f9', adjunto: { id: 'media-7', mime: 'image/jpeg' } }, { state: 'menu', data: {}, nueva: true }, { bot_compra_pendiente_de_pago: pend, bot_compra_reportar_pago: { report_id: 'r' }, ...cfg }, { almacen, fetchFn })
    comprueba(foto.fns.includes('bot_compra_pendiente_de_pago') && foto.llamadas.find((l) => l.fn === 'bot_compra_reportar_pago')?.args.p_request_id === ID1, 'sesión vencida (menú nuevo): un comprobante recupera la solicitud y la reporta')
    const botonYa = await correr({ boton: 'compra:ya_pague', texto: 'Ya pagué' }, { state: 'menu', data: {} }, { bot_compra_pendiente_de_pago: pend })
    comprueba(botonYa.estado === 'compra_pago' && botonYa.textos[0].includes('foto o el PDF'), '«Ya pagué» fuera de compra_pago: retoma el pago', botonYa.textos[0])
    const enBuscar = await correr({ boton: 'compra:datos_pago', texto: 'Escribir datos' }, { state: 'compra_buscar', data: {} }, { bot_compra_pendiente_de_pago: pend })
    comprueba(enBuscar.estado === 'compra_pago_datos', '«Escribir datos» desde otro paso de compra también recupera', enBuscar.estado)
    const datosTxt = await correr({ texto: 'datos' }, { state: 'menu', data: {} }, { bot_compra_pendiente_de_pago: pend })
    comprueba(datosTxt.estado === 'compra_pago_datos', '«datos» escrito en el menú retoma el pago')
    const ninguna = await correr({ boton: 'compra:ya_pague' }, { state: 'menu', data: {} }, { bot_compra_pendiente_de_pago: null })
    comprueba(ninguna.textos[0].includes('No tengo una compra esperando tu pago'), 'sin solicitud abierta: lo dice', ninguna.textos[0])
    const adjuntoSuelto = await correr({ type: 'image', adjunto: { id: 'm', mime: 'image/jpeg' } }, { state: 'menu', data: {} }, { bot_compra_pendiente_de_pago: null })
    comprueba(adjuntoSuelto.textos[0].startsWith('No entendí'), 'un adjunto sin compra abierta: «No entendí» como siempre')
    comprueba(esIntentoDePago({ texto: null, boton: null, adjunto: { id: 'x' } }) && esIntentoDePago({ texto: 'Ya pagué', boton: null, adjunto: null }) && !esIntentoDePago({ texto: 'estetoscopio', boton: null, adjunto: null }), 'esIntentoDePago')

    // «ayuda» desde el pago: no se pierde (se recupera luego).
    const ayuda = await correr({ texto: 'ayuda' }, sesionPago())
    comprueba(ayuda.estado === 'menu', '«ayuda» lleva al menú (la solicitud sigue abierta en la base)')
  }

  console.log('\n13. Menú, cancelar y cancelación real')
  {
    const antes = await correr({ boton: 'compra:menu', texto: 'Volver al menú' }, { state: 'compra_envio', data: {} })
    comprueba(antes.estado === 'menu' && antes.textos[0].includes('¿Qué quieres hacer?'), '«Volver al menú» antes de la solicitud: menú')
    const cancelarAntes = await correr({ texto: 'cancelar' }, { state: 'compra_confirmar', data: {} })
    comprueba(cancelarAntes.textos[0].startsWith('Listo, no se registró nada.') && !cancelarAntes.fns.includes('bot_compra_cancelar'), '«Cancelar» antes de la solicitud: «Listo, no se registró nada.»', cancelarAntes.textos[0])
    const menuPago = await correr({ boton: 'compra:menu', texto: 'Volver al menú' }, sesionPago({ compraVenceEn: '2026-11-26T20:30:00Z' }))
    comprueba(menuPago.textos[0].includes('Tu solicitud #C-1001 sigue abierta hasta el jue 26/11 16:30. La retomas desde «Mis compras».') && !menuPago.fns.includes('bot_compra_cancelar'), '«Volver al menú» con solicitud: sigue abierta, sin cancelar', menuPago.textos[0])
    const cancelarPago = await correr({ texto: 'cancelar' }, sesionPago())
    comprueba(cancelarPago.textos[0].includes('sigue abierta') && !cancelarPago.fns.includes('bot_compra_cancelar'), '«cancelar» en el pago no descarta la solicitud', cancelarPago.textos[0])
    const pedir = await correr({ texto: 'cancelar compra' }, sesionPago())
    comprueba(pedir.estado === 'compra_cancelar' && pedir.textos[0] === '¿Cancelo la solicitud #C-1001? Aún no has pagado.' && pedir.botones.map((b) => b.title).join() === 'Sí, cancelar,No, seguir', '«cancelar compra» pide confirmar', pedir.textos[0])
    const si = await correr({ boton: 'compra:cancelar_si', texto: 'Sí, cancelar' }, { state: 'compra_cancelar', data: pedir.datos }, { bot_compra_cancelar: { request_number: 1001, status: 'cancelado' } })
    const llam = si.llamadas.find((l) => l.fn === 'bot_compra_cancelar')
    comprueba(llam?.args.p_request_id === ID1 && llam.args.p_phone === '+584140000001' && si.textos[0].includes('cancelé la solicitud #C-1001'), 'bot_compra_cancelar(p_phone, p_request_id)', JSON.stringify(llam?.args))
    const no = await correr({ boton: 'compra:cancelar_no', texto: 'No, seguir' }, { state: 'compra_cancelar', data: pedir.datos })
    comprueba(no.estado === 'compra_pago' && !no.fns.includes('bot_compra_cancelar'), '«No, seguir» vuelve al pago')
    const err = await correr({ boton: 'compra:cancelar_si' }, { state: 'compra_cancelar', data: pedir.datos }, { bot_compra_cancelar: Object.assign(new Error('bot_compra_cancelar: Ya no se puede cancelar'), { code: '22023' }) })
    comprueba(err.textos[0] === 'No pudimos completarlo en este momento. Inténtalo de nuevo en unos minutos.' && !err.textos[0].includes('Ya no se puede'), 'un error de la base que no se reconoce NO se muestra crudo (queda en el log)', err.textos[0])
  }

  console.log('\n14. Cotización vencida y recotizar')
  {
    const pasada = sesionPago({ compraVenceEn: '2020-01-01T00:00:00Z' })
    const v = await correr({ boton: 'compra:ya_pague', texto: 'Ya pagué' }, pasada)
    comprueba(v.textos[0].startsWith('La cotización de #C-1001 venció. ¿La actualizo con el precio de hoy?') && v.botones.map((b) => b.title).join() === 'Actualizar,Cancelar compra,Mis compras', 'compra_pago vencida: ofrece actualizar', v.textos[0])
    const rc = await correr({ boton: 'compra:recotizar', texto: 'Actualizar' }, pasada, { bot_compra_recotizar: { request_id: ID1, request_number: 1001, total_usd: 150, total_anterior_usd: 135.7, quote_expires_at: '2099-01-02T00:00:00Z', payment_block: 'BNC (0191)' } })
    const llam = rc.llamadas.find((l) => l.fn === 'bot_compra_recotizar')
    comprueba(llam?.args.p_request_id === ID1 && rc.textos[0].includes('pasó de $135,70 a $150') && rc.textos[0].includes('BNC (0191)') && rc.estado === 'compra_pago', 'recotizar: muestra el cambio y el bloque de pago nuevo', rc.textos[0])
    const stale = await correr({ boton: 'compra:recotizar' }, { state: 'compra_envio', data: {} })
    comprueba(stale.textos[0].startsWith('Esa opción ya no está activa.'), '«Actualizar» fuera de su estado es obsoleto')
  }

  console.log('\n15. Después de un rechazo: compra:reenviar:<id>')
  {
    const r = await correr({ boton: `compra:reenviar:${ID1}`, texto: 'Enviar comprobante' }, { state: 'menu', data: {} }, { bot_compra_detalle: { request_id: ID1, request_number: 1001, status: 'esperando_pago', total_usd: 135.7, quote_expires_at: '2099-01-01T00:00:00Z', vencida: false } })
    comprueba(r.estado === 'compra_pago' && r.datos.compraId === ID1 && r.textos[0].includes('nuevo comprobante') && r.llamadas.some((l) => l.fn === 'bot_compra_detalle'), 'reenviar deja la sesión en compra_pago y pide otro comprobante', r.textos[0])
    const mala = await correr({ boton: 'compra:reenviar:xyz' }, { state: 'menu', data: {} })
    comprueba(mala.textos[0].startsWith('Esa opción ya no está activa'), 'id inválido: obsoleto')
  }

  console.log('\n16. Botones viejos: cada compra:* solo vale en su estado')
  {
    const env = await sesionDeEnvio()
    const casos: Array<[string, string, Record<string, unknown>, string]> = [
      ['compra:v:B00QES9K4G', 'compra_envio', env.datos as Record<string, unknown>, 'compra_envio'],
      ['compra:confirmar', 'compra_envio', env.datos as Record<string, unknown>, 'compra_envio'],
      ['compra:envio:aereo', 'compra_buscar', {}, 'compra_buscar'],
      ['compra:cambiar_envio', 'compra_pago', sesionPago().data, 'compra_pago'],
      ['compra:cantidad', 'compra_envio', env.datos as Record<string, unknown>, 'compra_envio'],
      ['compra:cancelar_si', 'compra_pago', sesionPago().data, 'compra_pago'],
      ['compra:pagar', 'compra_pago', sesionPago().data, 'compra_pago'],
      ['compra:recotizar', 'compra_buscar', {}, 'compra_buscar'],
      ['compra:v:B00QES9K4G', 'compra_pago', sesionPago().data, 'compra_pago'],
      ['compra:inventado', 'compra_buscar', {}, 'compra_buscar'],
    ]
    for (const [boton, state, data] of casos) {
      const r = await correr({ boton, texto: 'x' }, { state, data })
      comprueba(
        r.textos[0]?.startsWith('Esa opción ya no está activa.') && !r.fns.some((f) => f === 'bot_compra_crear' || f === 'bot_compra_cancelar' || f === 'bot_compra_recotizar'),
        `${boton} en ${state}: obsoleto, no ejecuta nada`,
        r.textos[0],
      )
    }
    const conSolicitud = await correr({ boton: 'compra:confirmar' }, sesionPago())
    comprueba(conSolicitud.textos[0].includes('Seguimos con tu compra #C-1001.') && conSolicitud.textos.length === 2, 'obsoleto con solicitud abierta: nombra la compra y repite el paso', conSolicitud.textos.join(' | '))
    const reenvia = await correr({ boton: 'compra:v:B00QES9K4G' }, { state: 'compra_envio', data: env.datos })
    comprueba(reenvia.textos.length === 2 && reenvia.textos[1].includes('Elige cómo traerlo'), 'obsoleto: re-envía el paso actual', reenvia.textos.join(' | '))
  }

  console.log('\n17. Búsquedas que no deben costar dinero')
  {
    let llamadas = 0
    const contador: ProveedorCatalogo = { nombre: 'mock', buscar: async (q, l) => (llamadas++, MOCK.buscar(q, l)), detalle: async (a) => (llamadas++, MOCK.detalle(a)) }
    const o = { proveedorDe: () => contador }
    const gracias = await correr({ texto: 'gracias' }, { state: 'compra_buscar', data: {} }, {}, o)
    comprueba(gracias.res === null && gracias.textos.length === 0 && llamadas === 0, '«gracias» no busca ni contesta')
    const corto = await correr({ texto: 'ab' }, { state: 'compra_buscar', data: {} }, {}, o)
    comprueba(corto.textos[0].includes('entre 3 y 80') && llamadas === 0, 'menos de 3 caracteres: no busca')
    const largo = await correr({ texto: 'a'.repeat(120) }, { state: 'compra_buscar', data: {} }, {}, o)
    comprueba(largo.textos[0].includes('entre 3 y 80') && llamadas === 0, 'más de 80 caracteres: no busca')
    const foto = await correr({ type: 'image', texto: 'estetoscopio littmann', adjunto: { id: 'm', mime: 'image/jpeg' } }, { state: 'compra_buscar', data: {} }, { bot_compra_pendiente_de_pago: null }, o)
    comprueba(llamadas === 0 && !foto.fns.includes('bot_compra_config'), 'el pie de una foto nunca se usa como búsqueda')
    const humano = await correr({ texto: 'te mando la foto ahora mismo' }, { state: 'compra_buscar', data: {} }, {}, { ...o, humano: true })
    comprueba(humano.res === null && humano.textos.length === 0 && llamadas === 0, 'con una persona atendiendo: el texto libre no busca ni contesta')
    const humanoLink = await correr({ texto: 'https://www.amazon.com/dp/B00QES9K4G' }, { state: 'compra_buscar', data: {} }, {}, { ...o, humano: true })
    comprueba(humanoLink.estado === 'compra_envio', 'con una persona atendiendo, un enlace sí se cotiza')
    const cortesiaEnvio = await correr({ texto: 'ok gracias' }, { state: 'compra_envio', data: humanoLink.datos }, {}, o)
    comprueba(cortesiaEnvio.res === null && cortesiaEnvio.textos.length === 0, 'una cortesía en un paso no recibe respuesta')
    const largoClave = await correr({ texto: 'estetoscopio '.repeat(6).trim() }, { state: 'compra_buscar', data: {} }, {}, o)
    const clave = String(largoClave.llamadas.find((l) => l.fn === 'bot_compra_cache_get')?.args.p_key ?? '')
    comprueba(clave.length > 0 && clave.length <= 100, 'la clave de caché tiene largo acotado', String(clave.length))
  }

  console.log('\n18. Entradas inválidas seguidas → «persona»')
  {
    const env = await sesionDeEnvio()
    const a = await correr({ texto: 'no sé' }, { state: 'compra_envio', data: env.datos })
    comprueba(!a.textos[0].includes('escribe «persona»') && !!a.guardados.at(-1)?.p_data && (a.datos.invalidos ?? 0) === 1, 'primer intento inválido: se repite', a.textos[0])
    const b = await correr({ texto: 'no sé' }, { state: 'compra_envio', data: a.datos })
    comprueba(b.textos[0].endsWith('Si prefieres, escribe «persona» y te ayudamos.'), 'segundo intento seguido: ofrece «persona»', b.textos[0])
    const p = await correr({ texto: 'persona' }, { state: 'compra_envio', data: b.datos }, { bot_compra_pedir_persona: null })
    const llam = p.llamadas.find((l) => l.fn === 'bot_compra_pedir_persona')
    comprueba(llam?.args.p_phone === '+584140000001' && p.textos[0] === 'Listo, avisé al equipo de Helios. Te escriben por aquí en horario de atención.', 'bot_compra_pedir_persona + mensaje', JSON.stringify(llam?.args))
    const bt = await correr({ boton: 'compra:persona', texto: 'Hablar con alguien' }, sesionPago(), { bot_compra_pedir_persona: null })
    comprueba(bt.llamadas.find((l) => l.fn === 'bot_compra_pedir_persona')?.args.p_request_id === ID1, 'con solicitud abierta, la persona recibe su id')
    for (const t of ['asesor', 'hablar con alguien']) {
      const x = await correr({ texto: t }, { state: 'menu', data: {} }, { bot_compra_pedir_persona: null })
      comprueba(x.fns.includes('bot_compra_pedir_persona'), `«${t}» pide una persona`)
    }
  }

  console.log('\n19. Fallas del catálogo y de la configuración')
  {
    const falla = (tipo: 'timeout' | 'limite' | 'red'): ProveedorCatalogo => ({
      nombre: 'rainforest',
      buscar: async () => {
        throw new ErrorCatalogo(tipo, 'rainforest: x')
      },
      detalle: async () => {
        throw new ErrorCatalogo(tipo, 'rainforest: x')
      },
    })
    const cfgRf = { bot_compra_config: { ...CONFIG_RPC, catalog_provider: 'rainforest' } }
    for (const tipo of ['timeout', 'red'] as const) {
      const r = await correr({ texto: 'estetoscopio' }, { state: 'compra_buscar', data: {} }, cfgRf, { proveedorDe: () => falla(tipo) })
      comprueba(r.textos[0].startsWith('Amazon no me responde') && r.botones.some((b) => b.title === 'Hablar con alguien'), `catálogo ${tipo}: mensaje amable con «Hablar con alguien»`, r.textos[0])
    }
    const lim = await correr({ texto: 'estetoscopio' }, { state: 'compra_buscar', data: {} }, cfgRf, { proveedorDe: () => falla('limite') })
    comprueba(lim.textos[0].startsWith('Amazon recibe muchas consultas'), 'límite (429): mensaje distinto')
    const sinClave = await correr({ texto: 'estetoscopio' }, { state: 'compra_buscar', data: {} }, cfgRf, { proveedorDe: (n) => crearProveedorCatalogo(n, '') })
    comprueba(sinClave.textos[0].startsWith('Las compras en Amazon no están disponibles en este momento') && !sinClave.listas.length, 'rainforest sin clave: «no disponibles», jamás mock', sinClave.textos[0])
    const sinTasa = await correr({ texto: 'estetoscopio' }, { state: 'compra_buscar', data: {} }, { bot_compra_config: { ...CONFIG_RPC, fx_rate_usd: null } })
    comprueba(sinTasa.textos[0].includes('no puedo cotizar') && sinTasa.listas.length === 0, 'sin tasa BCV: se niega a cotizar')
    const cfgCae = await correr({ texto: 'estetoscopio' }, { state: 'compra_buscar', data: {} }, { bot_compra_config: new Error('boom') })
    comprueba(cfgCae.textos[0].includes('no puedo cotizar'), 'si la configuración no carga: se niega, sin tarifas de respaldo')
    const todo = emitidos.map((e) => e.texto).join('\n')
    comprueba(!/api_key|clave-secreta|rainforestapi\.com/i.test(todo), 'ningún mensaje filtra la clave ni la URL del proveedor')
  }

  console.log('\n20. Enlaces cortos y otras tiendas')
  {
    const ok = await correr({ texto: 'mira https://amzn.to/3xYzAbc' }, { state: 'menu', data: {} }, {}, { resolverEnlace: async () => 'https://www.amazon.com/-/es/Estetoscopio/dp/B00QES9K4G?th=1' })
    comprueba(ok.estado === 'compra_envio' && ok.textos[0].includes('3M Littmann'), 'amzn.to se resuelve y cotiza el producto')
    const mal = await correr({ texto: 'https://amzn.to/3xYzAbc' }, { state: 'compra_buscar', data: {} }, {}, { resolverEnlace: async () => null })
    comprueba(mal.textos[0] === 'Ese enlace corto no me deja ver el producto. Ábrelo y copia el enlace largo, o escríbeme el nombre.' && !mal.fns.includes('bot_compra_cache_get') && mal.listas.length === 0, 'enlace corto que no se resuelve: mensaje exacto y NO se busca la URL como texto', mal.textos[0])
    const otra = await correr({ texto: 'https://www.amazon.es/dp/B00QES9K4G' }, { state: 'menu', data: {} })
    comprueba(otra.textos[0].startsWith('Compramos en Amazon EE. UU. (amazon.com); busco ese producto allá.') && otra.estado === 'compra_envio', 'tienda que no es .com: avisa y prueba el ASIN en .com', otra.textos[0])
    const ajeno = await correr({ texto: 'https://example.com/estetoscopio-barato' }, { state: 'compra_buscar', data: {} })
    comprueba(ajeno.textos[0].startsWith('Ese enlace no es de Amazon') && ajeno.listas.length === 0, 'un enlace de otro sitio no se busca como texto')

    // El resolvedor real: sigue redirecciones manuales, solo a hosts de Amazon, con tiempo.
    const visitados: string[] = []
    const f = (async (u: string | URL | Request, init?: RequestInit) => {
      visitados.push(String(u))
      comprueba(init?.redirect === 'manual' && init.signal instanceof AbortSignal, 'resolver: redirect manual y AbortSignal')
      if (String(u).includes('amzn.to')) return new Response(null, { status: 301, headers: { location: 'https://www.amazon.com/dp/B00QES9K4G?tag=x' } })
      return new Response(null, { status: 200 })
    }) as typeof fetch
    comprueba((await resolverEnlaceCorto('https://amzn.to/abc', f)) === 'https://www.amazon.com/dp/B00QES9K4G?tag=x', 'resolverEnlaceCorto devuelve la URL con ASIN')
    const evil = (async (u: string | URL | Request) => {
      visitados.push(String(u))
      return new Response(null, { status: 302, headers: { location: 'https://evil.example.com/x' } })
    }) as typeof fetch
    comprueba((await resolverEnlaceCorto('https://amzn.to/abc', evil)) === null && !visitados.some((v) => v.includes('evil')), 'resolver: no sigue una redirección fuera de Amazon')
    comprueba((await resolverEnlaceCorto('https://example.com/x', f)) === null, 'resolver: no pide a hosts que no son de Amazon')
    const cae = (async () => {
      throw new DOMException('t', 'TimeoutError')
    }) as typeof fetch
    comprueba((await resolverEnlaceCorto('https://amzn.to/abc', cae)) === null, 'resolver: timeout → null')
  }

  console.log('\n21. Mis compras (lista) y detalle')
  {
    const filas = [
      { request_id: ID1, request_number: 1024, product_title: '3M Littmann Classic III Monitoring Stethoscope', quantity: 1, status: 'esperando_pago', total_usd: 135.7, created_at: '2026-11-24T15:00:00Z' },
      { request_id: ID2, request_number: 1025, product_title: 'Sterile Absorbable Surgical Suture', quantity: 2, status: 'en_transito', total_usd: 88.6, created_at: '2026-11-20T15:00:00Z' },
    ]
    const mis = await correr({ boton: 'compra:mis', texto: 'Mis compras' }, { state: 'compra_buscar', data: {} }, { bot_compra_mis_solicitudes: filas })
    const filasLista = (mis.listas[0]?.p_sections as Array<{ rows: Array<{ id: string; title: string; description: string }> }> | undefined)?.[0]?.rows ?? []
    const t = JSON.stringify(filasLista)
    comprueba(mis.listas.length === 1 && filasLista.length === 2 && filasLista[0].title.startsWith('#C-1024 · 3M Littmann') && filasLista[0].description.includes('Esperando tu pago · $135,70 · mar 24/11') && filasLista[1].title.startsWith('#C-1025') && filasLista[1].description.includes('En camino a Venezuela') && filasLista.every((r) => r.title.length <= 24 && r.description.length <= 72), 'lista interactiva con «#C-1024 · producto» y «estado · monto · fecha» (helios_whatsapp_list)', t)
    comprueba(mis.estado === 'compra_mis' && (mis.datos.filasMis ?? []).length === 2, 'guarda las filas visibles')
    comprueba(mis.llamadas.find((l) => l.fn === 'bot_compra_mis_solicitudes')?.args.p_limit === 10, 'pide hasta 10')
    const vacio = await correr({ texto: 'mis compras' }, { state: 'menu', data: {} }, { bot_compra_mis_solicitudes: [] })
    comprueba(vacio.textos[0].includes('Todavía no tienes compras'), 'sin compras: lo dice')

    const detalle = {
      request_id: ID1, request_number: 1024, product_title: '3M Littmann Classic III Monitoring Stethoscope', quantity: 1, status: 'esperando_pago', shipping_method: 'aereo', total_usd: 135.7,
      quote_expires_at: '2099-01-01T20:30:00Z', vencida: false, us_tracking_number: null, payment_block: 'BNC (0191)',
    }
    const d = await correr({ boton: `compra:det:${ID1}`, texto: '#C-1024' }, { state: 'compra_mis', data: mis.datos }, { bot_compra_detalle: detalle })
    comprueba(d.textos[0].includes('Estado: *Esperando tu pago*') && d.textos[0].includes('BNC (0191)') && d.botones.map((b) => b.title).join() === 'Pagar,Cancelar compra,Hablar con alguien', 'detalle esperando_pago: estado, bloque y botones Pagar / Cancelar / Hablar', d.textos[0] + JSON.stringify(d.botones))
    const dn = await correr({ texto: '2' }, { state: 'compra_mis', data: mis.datos }, { bot_compra_detalle: { ...detalle, request_id: ID2, request_number: 1025, status: 'en_transito', us_tracking_number: '1Z999' } })
    comprueba(dn.llamadas.find((l) => l.fn === 'bot_compra_detalle')?.args.p_request_id === ID2 && dn.textos[0].includes('Seguimiento en EE. UU.: 1Z999') && dn.textos[0].includes('Tiempo estimado de llegada: 7–12 días'), 'escribir «2» abre la fila 2; muestra tracking y ETA', dn.textos[0])
    const venc = await correr({ boton: `compra:det:${ID1}` }, { state: 'compra_mis', data: mis.datos }, { bot_compra_detalle: { ...detalle, vencida: true } })
    comprueba(venc.botones[0].title === 'Actualizar', 'detalle vencido: «Actualizar» en lugar de «Pagar»')
    const pagar = await correr({ boton: 'compra:pagar', texto: 'Pagar' }, { state: 'compra_detalle', data: d.datos }, { bot_compra_detalle: detalle })
    comprueba(pagar.estado === 'compra_pago' && pagar.textos[0].includes('BNC (0191)'), '«Pagar» abre el paso de pago con el bloque', pagar.textos[0])
    const cancelar = await correr({ boton: 'compra:cancelar_pedir', texto: 'Cancelar compra' }, { state: 'compra_detalle', data: d.datos })
    comprueba(cancelar.estado === 'compra_cancelar', '«Cancelar compra» desde el detalle pide confirmar')
    const etiquetas = ['Esperando tu pago', 'Verificando tu pago', 'Pago confirmado', 'Comprado en Amazon', 'En nuestro almacén en EE. UU.', 'En camino a Venezuela', 'En aduana', 'Listo para entrega', 'Entregado', 'Cancelada', 'En revisión aduanal']
    comprueba(etiquetas.every((e) => Object.values(ETIQUETA_ESTADO).includes(e)) && Object.keys(ETIQUETA_ESTADO).join() === 'revision_aduanal,esperando_pago,pago_reportado,pagado,comprado_amazon,en_almacen_usa,en_transito,en_aduana,listo_entrega,entregado,cancelado', 'etiquetas amistosas y solo estados reales de SQL')
  }

  console.log('\n22. Límites de botones y vocabulario (todo lo emitido)')
  {
    const malos = emitidos.filter((e) => e.botones.length > 3 || e.botones.some((b) => b.title.length > 20 || b.title.length === 0))
    comprueba(malos.length === 0, `≤3 botones y títulos ≤20 caracteres en ${emitidos.length} mensajes`, malos.map((m) => m.botones.map((b) => b.title).join('|')).join(' ; '))
    const largos = emitidos.filter((e) => e.botones.length > 0 && e.texto.length > 1024)
    comprueba(largos.length === 0, 'cuerpo con botones ≤1024')
    const infractores = emitidos.filter((e) => PROHIBIDO.test(e.texto))
    comprueba(infractores.length === 0, 'cero vocabulario prohibido', infractores.map((i) => i.texto).join(' | '))
    const emojis = emitidos.filter((e) => (e.texto.match(EMOJI) ?? []).length > 1)
    comprueba(emojis.length === 0, '≤1 emoji por mensaje', emojis.map((i) => i.texto).join(' | '))
    const conBs = emitidos.filter((e) => /\bBs\b|bolívares/i.test(e.texto) && !/Datos para pagar|BNC|Así funciona|Solo en bolívares/.test(e.texto))
    comprueba(conBs.length === 0, 'bolívares solo dentro del bloque de pago', conBs.map((i) => i.texto.slice(0, 80)).join(' | '))
  }

  console.log('\n23. Canal, botones vs. estado, lista caída y errores amistosos (revisión final)')
  {
    const SEIS = ['bot_compra_pendiente_de_pago', 'bot_compra_mis_solicitudes', 'bot_compra_detalle', 'bot_compra_cancelar', 'bot_compra_recotizar', 'bot_compra_reportar_pago']
    const seis = todasLasLlamadas.filter((l) => SEIS.includes(l.fn))
    comprueba(seis.length > 10 && seis.every((l) => l.args.p_channel === 'whatsapp'), `las seis RPC reciben p_channel='whatsapp' en TODOS los sitios de llamada (${seis.length} llamadas)`, JSON.stringify(seis.filter((l) => l.args.p_channel !== 'whatsapp').map((l) => l.fn)))
    comprueba(new Set(seis.map((l) => l.fn)).size === SEIS.length, 'las seis RPC se ejercitaron en las pruebas', [...new Set(seis.map((l) => l.fn))].join())

    // Botón enviado -> estado en el que queda la sesión: tiene que aceptarlo.
    const malas = parejasBotonEstado.filter((p) => botonObsoletoEnEstado(p.id, p.estado))
    comprueba(parejasBotonEstado.length > 50 && malas.length === 0, `cada botón enviado vale en el estado en que queda la sesión (${parejasBotonEstado.length} envíos)`, malas.map((m) => `${m.id}@${m.estado}`).join(' '))

    // Sitios de envío conflictivos, uno por uno (sitio -> estado -> id aceptado).
    const venc = Object.assign(new Error('bot_compra_reportar_pago: cotizacion_vencida: la cotización venció'), { code: 'P0001' })
    const envio = await sesionDeEnvio()
    const sitios: Array<[string, Awaited<ReturnType<typeof correr>>]> = [
      ['datos escritos en compra_pago_datos con cotización vencida', await correr({ texto: 'Banesco\n04141234567\n123456789012' }, { state: 'compra_pago_datos', data: sesionPago().data }, { bot_compra_reportar_pago: venc })],
      ['comprobante en compra_pago con cotización vencida', await correr({ type: 'image', id: 'wamid.v1', adjunto: { id: 'm1', mime: 'image/jpeg' } }, sesionPago(), { lector_config: { d360_api_key: 'K', d360_base_url: 'https://waba.360dialog.io/v1/media' }, bot_compra_reportar_pago: venc }, { almacen: { async subir() {} }, fetchFn: (async (input: string | URL | Request) => (String(input).endsWith('/m1') ? new Response(JSON.stringify({ url: 'https://lookaside.fbsbx.com/x' }), { status: 200 }) : new Response(new Uint8Array([1, 2, 3]), { status: 200 }))) as typeof fetch })],
      ['cantidad inválida en compra_confirmar', await correr({ texto: 'x99' }, { state: 'compra_confirmar', data: { ...envio.datos, envio: 'aereo', cantidad: 1 } })],
      ['cantidad inválida en compra_envio', await correr({ texto: 'x99' }, { state: 'compra_envio', data: envio.datos })],
    ]
    for (const [nombre, r] of sitios) {
      const ids = r.botones.map((b) => b.id)
      comprueba(r.botones.length > 0 && ids.every((id) => !botonObsoletoEnEstado(id, r.estado ?? '')), `${nombre}: [${ids.join(', ')}] aceptados en ${r.estado}`, JSON.stringify(r.botones))
    }

    // El primer toque de «Actualizar» tras la cotización vencida cuenta, venga de donde venga.
    const desdeDatos = sitios[0][1]
    comprueba(desdeDatos.estado === 'compra_pago' && desdeDatos.datos.compraVencida === true && desdeDatos.botones.some((b) => b.id === 'compra:recotizar'), 'tras cotizacion_vencida la sesión queda en compra_pago, vencida, con «Actualizar»', JSON.stringify([desdeDatos.estado, desdeDatos.datos]))
    const recot = { bot_compra_recotizar: { request_id: ID1, request_number: 1001, total_usd: 140, total_anterior_usd: 135.7, quote_expires_at: '2099-01-02T00:00:00Z', payment_block: 'BNC' } }
    const toque = await correr({ boton: 'compra:recotizar', texto: 'Actualizar' }, { state: desdeDatos.estado ?? 'compra_pago', data: desdeDatos.datos as Record<string, unknown> }, recot)
    comprueba(toque.fns.includes('bot_compra_recotizar') && !toque.textos[0].startsWith('Esa opción ya no está activa'), 'el primer toque de «Actualizar» recotiza', toque.textos[0])
    const desdePagoDatos = await correr({ boton: 'compra:recotizar', texto: 'Actualizar' }, { state: 'compra_pago_datos', data: sesionPago({ compraVencida: true }).data }, recot)
    comprueba(desdePagoDatos.fns.includes('bot_compra_recotizar'), '«Actualizar» también vale si la sesión sigue en compra_pago_datos')

    // La lista que falla (22023) no tumba el turno ni repite la búsqueda.
    const errL = console.error
    console.error = () => {}
    const caido = await correr({ texto: 'estetoscopio' }, { state: 'compra_buscar', data: {} }, { helios_whatsapp_list: Object.assign(new Error('helios_whatsapp_list: Mensaje de lista incompleto'), { code: '22023' }) })
    console.error = errL
    comprueba(caido.fns.includes('helios_whatsapp_list') && caido.estado === 'compra_resultados' && caido.textos.some((t) => t.includes('Responde con el número de la opción.')), 'lista caída (22023): el turno sigue y los resultados salen en texto numerado', caido.textos.join(' | ').slice(0, 200))
    comprueba(caido.llamadas.filter((l) => l.fn === 'helios_whatsapp_list').length === 1, 'la lista se intenta una sola vez')

    // Errores de la base en palabras del médico.
    const cancelar = (msg: string) => correr({ boton: 'compra:cancelar_si' }, { state: 'compra_cancelar', data: sesionPago().data }, { bot_compra_cancelar: Object.assign(new Error('bot_compra_cancelar: ' + msg), { code: '22023' }) })
    const e1 = await cancelar('Solo se puede cancelar una solicitud que aún no tiene pago (estado actual: pago_reportado)')
    comprueba(e1.textos[0].includes('Verificando tu pago') && !/pago_reportado|estado actual/.test(e1.textos[0]), 'el estado crudo (pago_reportado) se traduce a su etiqueta', e1.textos[0])
    const e2 = await cancelar('Esta solicitud tiene un pago reportado en revisión: no se puede cancelar')
    comprueba(e2.textos[0].startsWith('Tienes un pago en revisión'), 'un error conocido sale con texto de médico', e2.textos[0])
    const e3 = await cancelar('relation "purchase_requests" does not exist')
    comprueba(!/relation|purchase_requests/.test(e3.textos[0]), 'un texto SQL desconocido jamás llega al médico', e3.textos[0])

    // Un cuerpo largo con botones se parte igual en cualquier transporte.
    const largo = 'x'.repeat(1500)
    const partes = partirMensaje(largo, [{ id: 'compra:mis', title: 'Mis compras' }])
    comprueba(partes.length === 2 && partes[0].botones.length === 0 && partes[1].texto === 'Elige una opción:' && partes[1].botones.length === 1, 'partirMensaje: cuerpo >1024 con botones = texto + «Elige una opción:»')
    comprueba(partirMensaje(largo).length === 1 && partirMensaje('hola', [{ id: 'a', title: 'b' }]).length === 1, 'partirMensaje: sin botones o corto no se parte')
  }

  if (fallos > 0) {
    console.log(`\n${fallos} fallo(s)`)
    process.exit(1)
  }
  console.log('\nTODO BIEN')
}

main()
