/**
 * Pruebas unitarias e integración del motor de Compras en Amazon para médicos
 * (parser, traductor médico ES→EN, restricciones aduanales, cotizador exacto,
 * catálogo mock/Rainforest y flujo conversacional completo en `bot.ts`).
 *
 *   npx tsx supabase/functions/whatsapp-webhook/compras/compras.test.ts
 */

import { atenderAlPersonal } from '../bot.ts'
import type { Personal } from '../bot.ts'
import type { EventoDeMensaje } from '../logica.ts'
import {
  evaluarRestriccionMedica,
  extraerAsinDeTexto,
  normalizarBusquedaMedica,
} from './amazon_parser.ts'
import { CATALOGO_MEDICO_MOCK, ProveedorAmazonMock } from './catalogo_mock.ts'
import {
  ProveedorRainforest,
  crearProveedorCatalogo,
  parsearDimensionesAPulgadas,
  parsearPesoALibras,
} from './catalogo_rainforest.ts'
import { calcularCotizacion, recomendarEnvio, redondearCentavos } from './cotizador.ts'
import type { ProveedorCatalogo, TarifasCompra } from './tipos.ts'

type CardMeta = {
  card_index: number
  type: string
  header: { type: string; image: { link: string } }
  body: { text: string }
  action: { buttons: Array<{ type: string; reply: { id: string; title: string } }> }
}

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

/** Vocabulario prohibido hacia médicos y externos (CLAUDE.md). */
const PROHIBIDO = /pr[eé]stamo|financiamiento|financiar|cr[eé]dito|\bfee\b/i

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
  accountsBlock:
    'Pago Móvil:\nBNC (0191)\nRIF: J-50123456-7\nTel: 0412-5551234\nSolo en bolívares a la tasa BCV de hoy.',
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
  fx_rate_usd: 100,
  accounts_block: TARIFAS.accountsBlock,
}

type Llamada = { fn: string; args: Record<string, unknown> }

const todosLosTextosEmitidos: string[] = []

async function correr(
  mensaje: Partial<EventoDeMensaje>,
  sesion: { state: string; data: Record<string, unknown>; nueva?: boolean },
  respuestas: Record<string, unknown | ((args: Record<string, unknown>) => unknown)> = {},
  proveedor: ProveedorCatalogo = new ProveedorAmazonMock(),
) {
  const llamadas: Llamada[] = []
  const rpc = async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
    llamadas.push({ fn, args })
    if (fn === 'bot_session') return { nueva: false, ...sesion } as T
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

  const res = await atenderAlPersonal({ rpc, personal: PERSONAL, mensaje: m, proveedor })
  const textos = llamadas.filter((l) => l.fn === 'helios_whatsapp_text').map((l) => String(l.args.p_text))
  const carruseles = llamadas.filter((l) => l.fn === 'helios_whatsapp_carousel').map((l) => l.args)
  const guardados = llamadas.filter((l) => l.fn === 'bot_session_save').map((l) => l.args)

  for (const t of textos) todosLosTextosEmitidos.push(t)
  for (const c of carruseles) {
    todosLosTextosEmitidos.push(String(c.p_body ?? ''))
    for (const card of (c.p_cards as CardMeta[]) ?? []) {
      todosLosTextosEmitidos.push(card.body.text, card.action.buttons[0]?.reply.title ?? '')
    }
  }

  return { res, llamadas, textos, carruseles, guardados }
}

async function main() {
  console.log('1. Parser de URLs y ASIN de Amazon')
  {
    comprueba(
      extraerAsinDeTexto('https://www.amazon.com/3M-Littmann-Classic-III/dp/B00QES9K4G/ref=sr_1_1') === 'B00QES9K4G',
      'URL completa /dp/ASIN',
    )
    comprueba(
      extraerAsinDeTexto('https://www.amazon.com/gp/product/b0157i0q8c?th=1') === 'B0157I0Q8C',
      'URL /gp/product/ en minúsculas → mayúsculas',
    )
    comprueba(
      extraerAsinDeTexto('https://smile.amazon.com/gp/aw/d/B07PQ8WTC4') === 'B07PQ8WTC4',
      'URL smile.amazon.com/gp/aw/d/',
    )
    comprueba(
      extraerAsinDeTexto('https://amzn.com/B07S2H3XBB') === 'B07S2H3XBB',
      'URL corta amzn.com/ASIN',
    )
    comprueba(
      extraerAsinDeTexto('B00QES9K4G') === 'B00QES9K4G',
      'ASIN puro empezando por B0',
    )
    comprueba(
      extraerAsinDeTexto('asin: 1264268505') === '1264268505',
      'ISBN-10 con prefijo asin:',
    )
    comprueba(
      extraerAsinDeTexto('V12345678') === null && extraerAsinDeTexto('04141234567') === null,
      'no confunde cédula ni teléfono venezolano con ASIN',
    )
    comprueba(
      extraerAsinDeTexto('estetoscopio littmann') === null,
      'texto normal devuelve null',
    )
  }

  console.log('\n2. Traductor médico ES → EN')
  {
    const est = normalizarBusquedaMedica('Estetoscopio Littmann')
    comprueba(
      est.consultaEn.includes('stethoscope') && est.consultaEn.includes('littmann'),
      'estetoscopio → stethoscope manteniendo marca',
      est.consultaEn,
    )
    const ten = normalizarBusquedaMedica('Tensiómetro digital Omron')
    comprueba(
      ten.consultaEn.includes('blood pressure monitor') && ten.consultaEn.includes('omron'),
      'tensiómetro digital → blood pressure monitor',
      ten.consultaEn,
    )
    const oxi = normalizarBusquedaMedica('Oxímetro de pulso')
    comprueba(oxi.consultaEn.includes('pulse oximeter'), 'oxímetro → pulse oximeter', oxi.consultaEn)

    const lam = normalizarBusquedaMedica('Lámpara frontal quirúrgica')
    comprueba(lam.consultaEn.includes('headlamp'), 'lámpara frontal → headlamp', lam.consultaEn)

    const uni = normalizarBusquedaMedica('Uniformes médicos FIGS')
    comprueba(uni.consultaEn.includes('scrubs') && uni.consultaEn.includes('figs'), 'uniformes → scrubs', uni.consultaEn)

    const gua = normalizarBusquedaMedica('Guantes de nitrilo')
    comprueba(gua.consultaEn.includes('nitrile') && gua.consultaEn.includes('gloves'), 'guantes de nitrilo → nitrile gloves', gua.consultaEn)
  }

  console.log('\n3. Detector de restricciones médicas y aduanales')
  {
    comprueba(
      !evaluarRestriccionMedica('3M Littmann Classic III Monitoring Stethoscope', 'Estetoscopios').restringido,
      'estetoscopio no está restringido',
    )
    comprueba(
      !evaluarRestriccionMedica('Accu-Chek Guide Blood Glucose Meter for Diabetes Monitoring', 'Diagnóstico').restringido,
      'glucómetro doméstico no está restringido',
    )
    comprueba(
      evaluarRestriccionMedica('Sterile Absorbable Surgical Suture Vicryl 3-0 with Needle').restringido,
      'sutura absorbible Vicryl → restringida',
    )
    comprueba(
      evaluarRestriccionMedica('Rapid Diagnostic Test Kit Chemical Reagent Strips').restringido,
      'kit reactivos / prueba rápida → restringido',
    )
    comprueba(
      evaluarRestriccionMedica('Dental Local Anesthetic Cartridges Lidocaine 2% + Sterile Syringes').restringido,
      'anestesia dental y jeringas estériles → restringido',
    )
    comprueba(
      evaluarRestriccionMedica('Ácido hialurónico relleno dérmico inyectable 1mL').restringido,
      'ácido hialurónico relleno → restringido',
    )
    comprueba(
      evaluarRestriccionMedica('Toxina botulínica vial estéril').restringido,
      'toxina botulínica → restringida',
    )
    comprueba(
      evaluarRestriccionMedica('Defibrillator with high capacity lithium battery pack 200Wh').restringido,
      'batería de litio de alta capacidad / desfibrilador → restringido',
    )
  }

  console.log('\n4. Cotizador aéreo, marítimo, volumétrico y fallback')
  {
    const littmann = CATALOGO_MEDICO_MOCK.find((p) => p.asin === 'B00QES9K4G')!
    const cotAereo = calcularCotizacion(littmann, TARIFAS, 'aereo', 1)
    // Peso real 1.1 lb, vol = (13*6.5*2)/139 = 1.22 lb -> 1.22 * 6.5 = 7.93 < airMin 15 -> 15
    comprueba(cotAereo.volumetricWeightLb === 1.22, 'peso volumétrico exacto (13*6.5*2/139 = 1.22)', String(cotAereo.volumetricWeightLb))
    comprueba(cotAereo.shippingUsd === 15, 'aéreo aplica mínimo $15 en paquete liviano', String(cotAereo.shippingUsd))
    comprueba(cotAereo.taxUsaUsd === 7.35, 'tax USA 7% de $104,95 = $7,35', String(cotAereo.taxUsaUsd))
    comprueba(cotAereo.serviceFeeUsd === 8.4, 'gestión Helios 8% de $104,95 = $8,40', String(cotAereo.serviceFeeUsd))
    comprueba(
      cotAereo.totalUsd === redondearCentavos(104.95 + 7.35 + 15 + 8.4) && cotAereo.totalUsd === 135.7,
      'total aéreo exacto = $135,70',
      String(cotAereo.totalUsd),
    )
    comprueba(cotAereo.totalVes === 13570, 'total en Bs a tasa 100 = Bs 13.570,00', String(cotAereo.totalVes))
    comprueba(recomendarEnvio(littmann) === 'aereo', 'estetoscopio recomienda aéreo')

    // Volumétrico > peso real y > airMinUsd
    const cajaLivianaGrande = {
      titulo: 'Lámpara liviana voluminosa',
      categoria: 'Consultorio',
      precioUsd: 100,
      pesoLb: 4,
      dimensionesIn: { largo: 20, ancho: 15, alto: 10 }, // 3000/139 = 21.58 lb
    }
    const cotVol = calcularCotizacion(cajaLivianaGrande, TARIFAS, 'aereo', 1)
    comprueba(cotVol.volumetricWeightLb === 21.58, 'volumétrico = 21,58 lb', String(cotVol.volumetricWeightLb))
    comprueba(cotVol.shippingUsd === redondearCentavos(21.58 * 6.5), 'aéreo cobra peso volumétrico (21,58 × $6,50)', String(cotVol.shippingUsd))
    comprueba(recomendarEnvio(cajaLivianaGrande) === 'maritimo', 'peso volumétrico > 15 lb recomienda marítimo')

    // Equipo pesado: Autoclave 18L (68.5 lb, 24.5×18.5×16.5 in = 4.3279 ft3)
    const autoclave = CATALOGO_MEDICO_MOCK.find((p) => p.asin === 'B09X7T2M5W')!
    const cotMar = calcularCotizacion(autoclave, TARIFAS, 'maritimo', 1)
    const cotAirPesado = calcularCotizacion(autoclave, TARIFAS, 'aereo', 1)
    comprueba(recomendarEnvio(autoclave) === 'maritimo', 'autoclave 18L recomienda marítimo')
    comprueba(cotMar.volumeFt3 === 4.3279, 'volumen autoclave = 4,3279 ft³', String(cotMar.volumeFt3))
    comprueba(cotMar.shippingUsd === redondearCentavos(4.3279 * 24), 'envío marítimo autoclave = $103,87', String(cotMar.shippingUsd))
    comprueba(cotMar.totalUsd < cotAirPesado.totalUsd, 'marítimo resulta mucho más económico que aéreo en autoclave')

    // Producto SIN peso listado -> fallback
    const guantes = CATALOGO_MEDICO_MOCK.find((p) => p.asin === 'B0B3K9M1Z4')!
    const cotFallback = calcularCotizacion(guantes, TARIFAS, 'aereo', 1)
    const cotFallbackMar = calcularCotizacion(guantes, TARIFAS, 'maritimo', 1)
    comprueba(cotFallback.weightEstimated === true && cotFallback.weightLb === 2, 'sin peso usa fallback 2 lb y marca weightEstimated')
    comprueba(cotFallbackMar.shippingUsd === 35, 'marítimo sin dimensiones usa 0,5 ft³ → mínimo $35', String(cotFallbackMar.shippingUsd))
  }

  console.log('\n5. Catálogo Mock (24 productos) y adaptador Rainforest')
  {
    comprueba(CATALOGO_MEDICO_MOCK.length === 24, 'catálogo mock tiene exactamente 24 productos médicos', String(CATALOGO_MEDICO_MOCK.length))
    const mock = new ProveedorAmazonMock()
    const resEst = await mock.buscar('estetoscopio', 4)
    comprueba(resEst.length === 3 && resEst[0].asin === 'B00QES9K4G', 'búsqueda «estetoscopio» devuelve los 3 Littmann')
    const resUrl = await mock.buscar('https://www.amazon.com/dp/B09X7T2M5W')
    comprueba(resUrl.length === 1 && resUrl[0].asin === 'B09X7T2M5W', 'búsqueda por URL devuelve el producto exacto')

    comprueba(crearProveedorCatalogo('mock', '').nombre === 'mock', 'fábrica devuelve mock por defecto')
    comprueba(crearProveedorCatalogo('rainforest', '').nombre === 'mock', 'rainforest sin API key cae seguro a mock')
    comprueba(crearProveedorCatalogo('rainforest', 'test-key').nombre === 'rainforest', 'rainforest con API key instancia ProveedorRainforest')

    comprueba(parsearPesoALibras('14.4 ounces') === 0.9, 'parsea onzas → libras (14.4 oz = 0.9 lb)')
    comprueba(parsearPesoALibras('2.5 kilograms') === 5.51, 'parsea kg → libras (2.5 kg = 5.51 lb)')
    const dimsCm = parsearDimensionesAPulgadas('25.4 x 12.7 x 5.08 cm')
    comprueba(dimsCm?.largo === 10 && dimsCm?.ancho === 5 && dimsCm?.alto === 2, 'parsea cm → pulgadas')

    // Prueba de ProveedorRainforest con fetch simulado
    const rf = new ProveedorRainforest('fake-key', 'amazon.com', (async (input: string | URL | Request) => {
      const url = String(input)
      const body = url.includes('type=search')
        ? {
            search_results: [
              {
                asin: 'B0TEST0001',
                title: 'Test Medical Otoscope LED',
                price: { value: 95.5 },
                image: 'https://example.com/img.png',
                link: 'https://www.amazon.com/dp/B0TEST0001',
                rating: 4.8,
                ratings_total: 420,
                is_prime: true,
              },
            ],
          }
        : {
            product: {
              asin: 'B0TEST0001',
              title: 'Test Medical Otoscope LED',
              buybox_winner: { price: { value: 95.5 }, is_prime: true, availability: { type: 'in_stock' } },
              specifications: [
                { name: 'Item Weight', value: '16 ounces' },
                { name: 'Package Dimensions', value: '10 x 5 x 2 inches' },
              ],
              variants: [{ title: 'Negro' }, { title: 'Azul' }],
              feature_bullets: ['Iluminación LED clínica'],
            },
          }
      return new Response(JSON.stringify(body), { status: 200, headers: { 'Content-Type': 'application/json' } })
    }) as typeof fetch)

    const rfBuscar = await rf.buscar('otoscopio', 4)
    comprueba(rfBuscar.length === 1 && rfBuscar[0].asin === 'B0TEST0001', 'Rainforest buscar parsea search_results')
    const rfDet = await rf.detalle('B0TEST0001')
    comprueba(
      rfDet?.pesoLb === 1 && rfDet?.dimensionesIn?.largo === 10 && rfDet?.variantes.length === 2,
      'Rainforest detalle parsea peso, dimensiones y variantes',
    )
  }

  console.log('\n6. Flujo conversacional completo en bot.ts (búsqueda → carrusel → aéreo/marítimo → pago captura y datos)')
  {
    // 6a. Menú principal tiene los 3 botones de Meta + mención a «ayuda»
    const rMenu = await correr({ texto: 'hola' }, { state: 'menu', data: {}, nueva: true })
    const botonesMenu = rMenu.llamadas.find((l) => l.fn === 'helios_whatsapp_text')?.args.p_buttons as Array<{ id: string; title: string }>
    comprueba(
      botonesMenu?.length === 3 &&
        botonesMenu[0].id === 'menu:nuevo' &&
        botonesMenu[1].id === 'menu:mis' &&
        botonesMenu[2].id === 'menu:comprar' &&
        botonesMenu[2].title === 'Comprar en Amazon',
      'menú principal actualizado con 3 botones incluyendo «Comprar en Amazon»',
      JSON.stringify(botonesMenu),
    )
    comprueba((rMenu.textos[0] ?? '').toLowerCase().includes('ayuda'), 'el saludo aclara que se puede escribir «ayuda»')

    // 6b. Pulsar «Comprar en Amazon» → compra_buscar
    const rIni = await correr({ boton: 'menu:comprar', texto: 'Comprar en Amazon' }, { state: 'menu', data: {} })
    comprueba(rIni.guardados.at(-1)?.p_state === 'compra_buscar', 'menu:comprar pasa a estado compra_buscar')

    // 6c. Buscar «estetoscopio» → carrusel de 3 cards (incluso si caché falla no se rompe!)
    const rBus = await correr(
      { texto: 'estetoscopio' },
      { state: 'compra_buscar', data: {} },
      {
        bot_compra_cache_get: new Error('cache_offline'),
        bot_compra_cache_set: new Error('cache_offline'),
      },
    )
    comprueba(rBus.carruseles.length === 1, 'búsqueda con múltiples resultados llama helios_whatsapp_carousel')
    const cards = (rBus.carruseles[0]?.p_cards as CardMeta[]) ?? []
    comprueba(
      cards.length === 3 &&
        cards[0].header.image.link.startsWith('https://') &&
        cards[0].action.buttons[0]?.reply.id === 'compra:ver:B00QES9K4G' &&
        cards[0].body.text.includes('$104,95') &&
        cards[0].body.text.includes('Est. VE:'),
      'carrusel Meta muestra foto, precio base, estimado en Venezuela y botón compra:ver:<ASIN>',
      JSON.stringify(cards[0]),
    )
    comprueba(rBus.guardados.at(-1)?.p_state === 'compra_resultados', 'guarda estado compra_resultados')

    // 6d. Resultado único («autoclave») → fallback a helios_whatsapp_text
    const rUno = await correr({ texto: 'autoclave' }, { state: 'compra_buscar', data: {} })
    comprueba(
      rUno.carruseles.length === 0 && rUno.textos.length === 1 && rUno.textos[0].includes('Autoclave'),
      'con 1 solo resultado, enviarCarrusel hace fallback limpio a helios_whatsapp_text',
    )

    // 6e. Pegar link directo de Amazon desde el menú → salta directo a compra_envio
    const rLink = await correr(
      { texto: 'https://www.amazon.com/dp/B0B3K9M1Z4' },
      { state: 'menu', data: {} },
    )
    comprueba(
      rLink.guardados.at(-1)?.p_state === 'compra_envio' &&
        (rLink.textos[0] ?? '').includes('Peso estimado: 2 lb'),
      'link directo desde el menú salta a compra_envio y avisa cuando el peso es estimado',
      rLink.textos[0],
    )

    // 6f. Elegir card `compra:ver:B00QES9K4G` → compra_envio con Aéreo vs Marítimo
    const sesionRes = rBus.guardados.at(-1)?.p_data as Record<string, unknown>
    const rVer = await correr(
      { boton: 'compra:ver:B00QES9K4G', texto: 'Ver y cotizar' },
      { state: 'compra_resultados', data: sesionRes },
    )
    const tEnvio = rVer.textos[0] ?? ''
    comprueba(
      rVer.guardados.at(-1)?.p_state === 'compra_envio' &&
        tEnvio.includes('Aéreo') &&
        tEnvio.includes('Marítimo') &&
        tEnvio.includes('$135,70') &&
        tEnvio.includes('Bs 13.570,00'),
      'compra_envio muestra comparación Aéreo vs Marítimo en USD y Bs BCV',
      tEnvio,
    )

    // 6g. Elegir Aéreo → compra_confirmar con desglose completo
    const sesionEnvio = rVer.guardados.at(-1)?.p_data as Record<string, unknown>
    const rConf = await correr(
      { boton: 'compra:envio:aereo', texto: 'Envío aéreo' },
      { state: 'compra_envio', data: sesionEnvio },
    )
    const tConf = rConf.textos[0] ?? ''
    comprueba(
      rConf.guardados.at(-1)?.p_state === 'compra_confirmar' &&
        tConf.includes('Producto: $104,95') &&
        tConf.includes('Tax USA (7%): $7,35') &&
        tConf.includes('Envío a Venezuela: $15') &&
        tConf.includes('Gestión Helios (8%): $8,40') &&
        tConf.includes('*Total: $135,70*') &&
        tConf.includes('*Bs 13.570,00*'),
      'compra_confirmar muestra desglose completo USD y Bs BCV',
      tConf,
    )

    // 6h. Cambiar envío → vuelve a compra_envio → elegir Marítimo
    const sesionConf = rConf.guardados.at(-1)?.p_data as Record<string, unknown>
    const rCamb = await correr(
      { boton: 'compra:cambiar_envio', texto: 'Cambiar envío' },
      { state: 'compra_confirmar', data: sesionConf },
    )
    comprueba(rCamb.guardados.at(-1)?.p_state === 'compra_envio', 'compra:cambiar_envio regresa a compra_envio')

    const rMar = await correr(
      { boton: 'compra:envio:maritimo', texto: 'Envío marítimo' },
      { state: 'compra_envio', data: rCamb.guardados.at(-1)?.p_data as Record<string, unknown> },
    )
    comprueba(
      rMar.guardados.at(-1)?.p_state === 'compra_confirmar' && (rMar.textos[0] ?? '').includes('Envío: *Marítimo*'),
      'permite cambiar a envío marítimo antes de confirmar',
    )

    // 6i. Confirmar compra normal → bot_compra_crear → compra_pago con payment_block
    const rCrear = await correr(
      { boton: 'compra:confirmar', texto: 'Confirmar compra', id: 'wamid.crear.1' },
      { state: 'compra_confirmar', data: sesionConf },
      {
        bot_compra_crear: {
          request_id: 'pur-1001',
          request_number: 1001,
          status: 'esperando_pago',
          restricted_flag: false,
          total_usd: 135.7,
          quoted_ves: 13570,
          payment_block: TARIFAS.accountsBlock,
        },
      },
    )
    const callCrear = rCrear.llamadas.find((l) => l.fn === 'bot_compra_crear')
    comprueba(
      Boolean(callCrear) &&
        callCrear?.args.p_asin === 'B00QES9K4G' &&
        callCrear?.args.p_product_title === '3M Littmann Classic III Monitoring Stethoscope, Black Edition (27 inch)' &&
        callCrear?.args.p_shipping_method === 'aereo' &&
        callCrear?.args.p_restricted_flag === false &&
        callCrear?.args.p_channel === 'whatsapp',
      'bot_compra_crear recibe parámetros exactos del contrato SQL',
      JSON.stringify(callCrear?.args),
    )
    comprueba(
      rCrear.guardados.at(-1)?.p_state === 'compra_pago' &&
        (rCrear.textos[0] ?? '').includes('#C-1001') &&
        (rCrear.textos[0] ?? '').includes('BNC (0191)'),
      'compra aprobada pasa a compra_pago enviando el payment_block de la base',
      rCrear.textos[0],
    )

    // 6j. Reportar pago por foto/PDF adjunto en compra_pago
    const sesionPago = rCrear.guardados.at(-1)?.p_data as Record<string, unknown>
    const rFoto = await correr(
      { type: 'image', id: 'wamid.foto.1', adjunto: { id: 'media-999', mime: 'image/jpeg' } },
      { state: 'compra_pago', data: sesionPago },
      { bot_compra_reportar_pago: { report_id: 'rep-1', status: 'reported' } },
    )
    const callFoto = rFoto.llamadas.find((l) => l.fn === 'bot_compra_reportar_pago')
    comprueba(
      callFoto?.args.p_request_id === 'pur-1001' &&
        callFoto?.args.p_method === 'pago_movil' &&
        callFoto?.args.p_receipt_path === 'compras/pur-1001/media-999' &&
        callFoto?.args.p_wa_message_id === 'wamid.foto.1',
      'foto adjunta llama bot_compra_reportar_pago con p_request_id, p_receipt_path compras/... y p_wa_message_id',
      JSON.stringify(callFoto?.args),
    )

    // 6k. Reportar pago escribiendo datos de Pago Móvil (reutilizando datos_pago.ts)
    const rPedirDatos = await correr(
      { boton: 'compra:datos_pago', texto: 'Escribir datos' },
      { state: 'compra_pago', data: sesionPago },
    )
    comprueba(rPedirDatos.guardados.at(-1)?.p_state === 'compra_pago_datos', 'compra:datos_pago pasa a compra_pago_datos')

    const rParcial = await correr(
      { texto: 'Banesco\n04141234567' },
      { state: 'compra_pago_datos', data: rPedirDatos.guardados.at(-1)?.p_data as Record<string, unknown> },
    )
    comprueba(
      rParcial.guardados.at(-1)?.p_state === 'compra_pago_datos' &&
        (rParcial.textos[0] ?? '').includes('referencia'),
      'si falta la referencia, pide solo lo que falta',
      rParcial.textos[0],
    )

    const rCompleto = await correr(
      { texto: '123456789012', id: 'wamid.datos.2' },
      { state: 'compra_pago_datos', data: rParcial.guardados.at(-1)?.p_data as Record<string, unknown> },
      { bot_compra_reportar_pago: { report_id: 'rep-2', status: 'reported' } },
    )
    const callDatos = rCompleto.llamadas.find((l) => l.fn === 'bot_compra_reportar_pago')
    comprueba(
      callDatos?.args.p_request_id === 'pur-1001' &&
        callDatos?.args.p_method === 'pago_movil' &&
        callDatos?.args.p_bank === 'Banesco' &&
        callDatos?.args.p_payer_phone === '04141234567' &&
        callDatos?.args.p_reference === '123456789012',
      'datos completos de Pago Móvil registran el pago vía bot_compra_reportar_pago',
      JSON.stringify(callDatos?.args),
    )
  }

  console.log('\n7. Producto restringido → revisión aduanal')
  {
    const rVer = await correr(
      { texto: 'https://www.amazon.com/dp/B09D4S7V2X' },
      { state: 'menu', data: {} },
    )
    comprueba(
      (rVer.textos[0] ?? '').includes('Revisión aduanal'),
      'muestra advertencia aduanal en compra_envio para suturas estériles',
      rVer.textos[0],
    )
    const rEnv = await correr(
      { boton: 'compra:envio:aereo', texto: 'Envío aéreo' },
      { state: 'compra_envio', data: rVer.guardados.at(-1)?.p_data as Record<string, unknown> },
    )
    const rRestr = await correr(
      { boton: 'compra:confirmar', texto: 'Confirmar compra', id: 'wamid.restr.1' },
      { state: 'compra_confirmar', data: rEnv.guardados.at(-1)?.p_data as Record<string, unknown> },
      {
        bot_compra_crear: {
          request_id: 'pur-1002',
          request_number: 1002,
          status: 'revision_aduanal',
          restricted_flag: true,
          restricted_reason: 'Insumo médico invasivo o estéril: requiere revisión aduanal y sanitaria antes de pagar.',
        },
      },
    )
    const tRestr = rRestr.textos[0] ?? ''
    comprueba(
      tRestr.includes('#C-1002') &&
        tRestr.includes('revisión aduanal') &&
        rRestr.guardados.at(-1)?.p_state !== 'compra_pago',
      'producto restringido queda en revision_aduanal sin pasar a pago todavía',
      tRestr,
    )
  }

  console.log('\n8. Mis compras')
  {
    const rMis = await correr(
      { texto: 'mis compras' },
      { state: 'menu', data: {} },
      {
        bot_compra_mis_solicitudes: [
          {
            request_number: 1001,
            product_title: '3M Littmann Classic III Monitoring Stethoscope',
            total_usd: 135.7,
            status: 'esperando_pago',
          },
          {
            request_number: 1002,
            product_title: 'Sterile Absorbable Surgical Suture Vicryl 3-0',
            total_usd: 88.6,
            status: 'revision_aduanal',
          },
        ],
      },
    )
    const tMis = rMis.textos[0] ?? ''
    comprueba(
      tMis.includes('#C-1001') &&
        tMis.includes('$135,70') &&
        tMis.includes('Esperando pago') &&
        tMis.includes('#C-1002') &&
        tMis.includes('En revisión aduanal'),
      'mis compras lista #C-1001, producto, monto y estado legible en español',
      tMis,
    )
  }

  console.log('\n9. Cero palabras prohibidas (CLAUDE.md)')
  {
    const infractores = todosLosTextosEmitidos.filter((t) => PROHIBIDO.test(t))
    comprueba(
      infractores.length === 0,
      `cero vocabulario prohibido en ${todosLosTextosEmitidos.length} mensajes/tarjetas emitidos`,
      infractores.join(' | '),
    )
  }

  if (fallos > 0) {
    console.log(`\n${fallos} fallo(s)`)
    process.exit(1)
  }
  console.log('\nTODO BIEN')
}

main()
