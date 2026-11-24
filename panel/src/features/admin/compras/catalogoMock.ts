import type { AjustesComprasConfig, MetodoEnvioCompra } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// Catálogo Amazon mock (24 productos médicos realistas) + motor de búsqueda,
// extractor de ASIN, normalizador ES→EN, detector de restricciones aduanales
// y cotizador exacto en USD y bolívares BCV.
// ═══════════════════════════════════════════════════════════════════════════

export type ProductoCatalogoMock = {
  asin: string
  title: string
  category: string
  brand: string
  priceUsd: number
  rating: number
  reviewCount: number
  variantLabel: string | null
  weightLb: number | null
  volumetricWeightLb: number | null
  volumeFt3: number | null
  weightEstimated: boolean
  restrictedFlag: boolean
  restrictedReason: string | null
  productUrl: string
  imageUrl: string
  keywords: ReadonlyArray<string>
}

export type CotizacionCompra = {
  unitPriceUsd: number
  quantity: number
  subtotalUsd: number
  taxUsaUsd: number
  shippingMethod: MetodoEnvioCompra
  billableWeightLb: number
  billableVolumeFt3: number
  weightEstimated: boolean
  shippingUsd: number
  serviceFeeUsd: number
  totalUsd: number
  bcvRate: number | null
  totalVes: number | null
}

function crearMiniaturaSvg(etiqueta: string, subtitulo: string, acento: string): string {
  const safeLabel = etiqueta.replace(/[<>&"]/g, '')
  const safeSub = subtitulo.replace(/[<>&"]/g, '')
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="280" viewBox="0 0 400 280"><rect width="400" height="280" rx="24" fill="aliceblue"/><rect x="24" y="24" width="352" height="232" rx="18" fill="white" stroke="lightsteelblue" stroke-width="2"/><circle cx="200" cy="112" r="42" fill="${acento}" opacity="0.16"/><circle cx="200" cy="112" r="22" fill="${acento}"/><text x="200" y="186" text-anchor="middle" font-family="system-ui, sans-serif" font-size="18" font-weight="700" fill="darkslategray">${safeLabel}</text><text x="200" y="212" text-anchor="middle" font-family="system-ui, sans-serif" font-size="13" fill="slategray">${safeSub}</text></svg>`
  return `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`
}

export const CATALOGO_AMAZON_MOCK: ReadonlyArray<ProductoCatalogoMock> = [
  // ── Estetoscopios ────────────────────────────────────────────────────────
  {
    asin: 'B00QES5W92',
    title: '3M Littmann Classic III Monitoring Stethoscope, Black Edition, 27 inch',
    category: 'Diagnóstico',
    brand: '3M Littmann',
    priceUsd: 98.5,
    rating: 4.9,
    reviewCount: 41280,
    variantLabel: 'Black Edition · 27"',
    weightLb: 0.9,
    volumetricWeightLb: 1.1,
    volumeFt3: 0.08,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B00QES5W92',
    imageUrl: crearMiniaturaSvg('Littmann Classic III', 'Diagnóstico · 0,9 lb', 'steelblue'),
    keywords: ['estetoscopio', 'stethoscope', 'littmann', 'classic', 'cardiologia', 'auscultacion'],
  },
  {
    asin: 'B01972W134',
    title: '3M Littmann Cardiology IV Diagnostic Stethoscope, Champagne-Finish Chestpiece',
    category: 'Diagnóstico',
    brand: '3M Littmann',
    priceUsd: 214.0,
    rating: 4.9,
    reviewCount: 18420,
    variantLabel: 'Burgundy / Champagne · 27"',
    weightLb: 1.2,
    volumetricWeightLb: 1.4,
    volumeFt3: 0.1,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B01972W134',
    imageUrl: crearMiniaturaSvg('Littmann Cardiology IV', 'Cardiología · 1,2 lb', 'crimson'),
    keywords: ['estetoscopio', 'stethoscope', 'littmann', 'cardiology', 'cardiologia'],
  },
  {
    asin: 'B0018E7Q68',
    title: '3M Littmann Lightweight II S.E. Stethoscope, Ceil Blue, 28 inch',
    category: 'Diagnóstico',
    brand: '3M Littmann',
    priceUsd: 62.9,
    rating: 4.8,
    reviewCount: 14190,
    variantLabel: 'Ceil Blue · 28"',
    weightLb: 0.7,
    volumetricWeightLb: 0.9,
    volumeFt3: 0.07,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B0018E7Q68',
    imageUrl: crearMiniaturaSvg('Littmann Lightweight II', 'Enfermería · 0,7 lb', 'deepskyblue'),
    keywords: ['estetoscopio', 'stethoscope', 'littmann', 'lightweight', 'enfermeria'],
  },

  // ── Oxímetros ────────────────────────────────────────────────────────────
  {
    asin: 'B07PQ8WTC4',
    title: 'Zacurate Pro Series 500DL Fingertip Pulse Oximeter Blood Oxygen Saturation Monitor',
    category: 'Monitoreo',
    brand: 'Zacurate',
    priceUsd: 24.95,
    rating: 4.7,
    reviewCount: 68200,
    variantLabel: 'Mystic Black · OLED',
    weightLb: 0.3,
    volumetricWeightLb: 0.35,
    volumeFt3: 0.03,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B07PQ8WTC4',
    imageUrl: crearMiniaturaSvg('Oxímetro Zacurate 500DL', 'Monitoreo · 0,3 lb', 'teal'),
    keywords: ['oximetro', 'oximeter', 'pulsioximetro', 'saturacion', 'spo2', 'zacurate'],
  },
  {
    asin: 'B00B2P3636',
    title: 'Nonin 9590 Onyx Vantage Finger Pulse Oximeter, Clinical Grade',
    category: 'Monitoreo',
    brand: 'Nonin',
    priceUsd: 169.0,
    rating: 4.8,
    reviewCount: 2340,
    variantLabel: 'Azul clínico · Grado hospitalario',
    weightLb: 0.4,
    volumetricWeightLb: 0.4,
    volumeFt3: 0.03,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B00B2P3636',
    imageUrl: crearMiniaturaSvg('Nonin Onyx 9590', 'Grado clínico · 0,4 lb', 'royalblue'),
    keywords: ['oximetro', 'oximeter', 'nonin', 'onyx', 'spo2', 'hospitalario'],
  },
  {
    asin: 'B08H8R2K1P',
    title: 'Cromi Pediatric Fingertip Pulse Oximeter for Kids and Infants, OLED Display',
    category: 'Pediatría',
    brand: 'Cromi',
    priceUsd: 29.5,
    rating: 4.6,
    reviewCount: 3180,
    variantLabel: 'Pediátrico · Azul',
    weightLb: 0.25,
    volumetricWeightLb: 0.3,
    volumeFt3: 0.02,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B08H8R2K1P',
    imageUrl: crearMiniaturaSvg('Oxímetro Pediátrico', 'Pediatría · 0,25 lb', 'mediumseagreen'),
    keywords: ['oximetro', 'pediatrico', 'ninos', 'pediatria', 'oximeter'],
  },

  // ── Tensiómetros ─────────────────────────────────────────────────────────
  {
    asin: 'B07S2H3XBB',
    title: 'OMRON Platinum Blood Pressure Monitor, Upper Arm Cuff, Bluetooth, Dual User',
    category: 'Monitoreo',
    brand: 'OMRON',
    priceUsd: 79.99,
    rating: 4.7,
    reviewCount: 29540,
    variantLabel: 'Brazo 9"-17" · Bluetooth',
    weightLb: 1.9,
    volumetricWeightLb: 2.2,
    volumeFt3: 0.16,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B07S2H3XBB',
    imageUrl: crearMiniaturaSvg('OMRON Platinum BP5450', 'Tensiómetro · 1,9 lb', 'navy'),
    keywords: ['tensiometro', 'presion', 'baumanometro', 'esfigmomanometro', 'omron', 'blood pressure'],
  },
  {
    asin: 'B000A66C2M',
    title: 'Welch Allyn DS44-11 Integrated Aneroid Sphygmomanometer with FlexiPort Adult Cuff',
    category: 'Diagnóstico',
    brand: 'Welch Allyn',
    priceUsd: 88.0,
    rating: 4.8,
    reviewCount: 4120,
    variantLabel: 'Adulto FlexiPort · Aneroide',
    weightLb: 1.1,
    volumetricWeightLb: 1.2,
    volumeFt3: 0.09,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B000A66C2M',
    imageUrl: crearMiniaturaSvg('Welch Allyn DS44-11', 'Aneroide · 1,1 lb', 'darkslateblue'),
    keywords: ['tensiometro', 'aneroide', 'welch allyn', 'esfigmomanometro', 'presion'],
  },
  {
    asin: 'B07RYB7K2S',
    title: 'OMRON 7 Series Wireless Bluetooth Wrist Blood Pressure Monitor',
    category: 'Monitoreo',
    brand: 'OMRON',
    priceUsd: 59.95,
    rating: 4.6,
    reviewCount: 15800,
    variantLabel: 'Muñeca · Estuche rígido',
    weightLb: 0.85,
    volumetricWeightLb: 0.9,
    volumeFt3: 0.06,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B07RYB7K2S',
    imageUrl: crearMiniaturaSvg('OMRON 7 Series Muñeca', 'Monitoreo · 0,85 lb', 'steelblue'),
    keywords: ['tensiometro', 'muneca', 'omron', 'blood pressure', 'presion'],
  },

  // ── Lámparas, otoscopios y diagnóstico visual ────────────────────────────
  {
    asin: 'B01N25G9A1',
    title: 'Welch Allyn Pocket Plus LED Otoscope with Soft Case, Onyx',
    category: 'Diagnóstico',
    brand: 'Welch Allyn',
    priceUsd: 194.5,
    rating: 4.8,
    reviewCount: 1920,
    variantLabel: 'LED · Estuche Onyx',
    weightLb: 0.8,
    volumetricWeightLb: 1.0,
    volumeFt3: 0.08,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B01N25G9A1',
    imageUrl: crearMiniaturaSvg('Otoscopio Welch Allyn', 'LED Pocket Plus · 0,8 lb', 'teal'),
    keywords: ['otoscopio', 'otoscope', 'welch allyn', 'oido', 'orl', 'lampara'],
  },
  {
    asin: 'B07W5X2N8L',
    title: 'Welch Allyn Pocket LED Ophthalmoscope, SureColor LED Technology',
    category: 'Oftalmología',
    brand: 'Welch Allyn',
    priceUsd: 249.0,
    rating: 4.8,
    reviewCount: 980,
    variantLabel: 'SureColor LED · Blanco',
    weightLb: 0.85,
    volumetricWeightLb: 1.0,
    volumeFt3: 0.08,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B07W5X2N8L',
    imageUrl: crearMiniaturaSvg('Oftalmoscopio LED', 'Welch Allyn · 0,85 lb', 'indigo'),
    keywords: ['oftalmoscopio', 'ophthalmoscope', 'ojo', 'oftalmologia', 'welch allyn'],
  },
  {
    asin: 'B07P4J5M2V',
    title: 'MDF Instruments LUMiNiX II Illuminator Medical Penlight, Warm LED with Pupil Gauge',
    category: 'Diagnóstico',
    brand: 'MDF Instruments',
    priceUsd: 19.99,
    rating: 4.7,
    reviewCount: 8450,
    variantLabel: 'Luz cálida · Aluminio negro',
    weightLb: 0.25,
    volumetricWeightLb: 0.25,
    volumeFt3: 0.02,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B07P4J5M2V',
    imageUrl: crearMiniaturaSvg('Linterna MDF LUMiNiX', 'Luz cálida LED · 0,25 lb', 'darkorange'),
    keywords: ['linterna', 'lampara', 'penlight', 'pupilas', 'mdf', 'diagnostico'],
  },
  {
    asin: 'B08F3H9R6T',
    title: '3.5X Dental & Surgical Binocular Loupes with 5W Rechargeable LED Headlight',
    category: 'Cirugía y Odontología',
    brand: 'YNR Medical',
    priceUsd: 138.0,
    rating: 4.5,
    reviewCount: 1260,
    variantLabel: '3.5X · 420 mm · Luz frontal 5W',
    weightLb: 1.5,
    volumetricWeightLb: 1.9,
    volumeFt3: 0.14,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B08F3H9R6T',
    imageUrl: crearMiniaturaSvg('Lupas Quirúrgicas 3.5X', 'Con lámpara frontal · 1,5 lb', 'darkcyan'),
    keywords: ['lupa', 'loupes', 'lampara frontal', 'headlight', 'odontologia', 'cirugia'],
  },

  // ── Uniformes médicos (Scrubs) y calzado ─────────────────────────────────
  {
    asin: 'B08L5N8Q1C',
    title: 'FIGS Technical Collection Catarina One-Pocket Scrub Top & Zamora Jogger Set',
    category: 'Indumentaria',
    brand: 'FIGS',
    priceUsd: 86.0,
    rating: 4.8,
    reviewCount: 11200,
    variantLabel: 'Navy · Talla M (Set completo)',
    weightLb: 1.3,
    volumetricWeightLb: 1.5,
    volumeFt3: 0.11,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B08L5N8Q1C',
    imageUrl: crearMiniaturaSvg('Set Scrubs FIGS', 'Indumentaria · 1,3 lb', 'midnightblue'),
    keywords: ['scrubs', 'uniforme', 'mono', 'pijama quirurgica', 'figs', 'ropa medica'],
  },
  {
    asin: 'B07B4K2P7X',
    title: 'Cherokee Workwear Revolution Unisex Medical Scrub Set, Breathable Stretch',
    category: 'Indumentaria',
    brand: 'Cherokee',
    priceUsd: 49.99,
    rating: 4.7,
    reviewCount: 24300,
    variantLabel: 'Ceil Blue · Talla L',
    weightLb: 1.2,
    volumetricWeightLb: 1.4,
    volumeFt3: 0.1,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B07B4K2P7X',
    imageUrl: crearMiniaturaSvg('Scrubs Cherokee', 'Revolution Stretch · 1,2 lb', 'cornflowerblue'),
    keywords: ['scrubs', 'uniforme', 'mono', 'cherokee', 'ropa medica'],
  },
  {
    asin: 'B0014J4W5A',
    title: 'Crocs Unisex-Adult Bistro Work Clog, Slip Resistant Medical & Hospital Shoe',
    category: 'Indumentaria',
    brand: 'Crocs',
    priceUsd: 54.95,
    rating: 4.7,
    reviewCount: 38900,
    variantLabel: 'Negro · Antideslizante US 9',
    weightLb: 1.6,
    volumetricWeightLb: 2.3,
    volumeFt3: 0.22,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B0014J4W5A',
    imageUrl: crearMiniaturaSvg('Crocs Bistro Clínico', 'Antideslizante · 1,6 lb', 'darkslategray'),
    keywords: ['crocs', 'zuecos', 'calzado', 'zapatos', 'quirofano', 'bistro'],
  },

  // ── Libros médicos ───────────────────────────────────────────────────────
  {
    asin: 'B09W2Q7H8R',
    title: "Harrison's Principles of Internal Medicine, 21st Edition (Two-Volume Hardcover)",
    category: 'Bibliografía',
    brand: 'McGraw Hill',
    priceUsd: 242.0,
    rating: 4.8,
    reviewCount: 1640,
    variantLabel: '21ª Edición · Tapa dura (2 vol.)',
    weightLb: 15.8,
    volumetricWeightLb: 16.5,
    volumeFt3: 0.72,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B09W2Q7H8R',
    imageUrl: crearMiniaturaSvg("Harrison's 21st Ed.", 'Medicina Interna · 15,8 lb', 'firebrick'),
    keywords: ['libro', 'harrison', 'medicina interna', 'textbook', 'bibliografia'],
  },
  {
    asin: 'B09N9L3D5M',
    title: 'Netter Atlas of Human Anatomy: Classic Regional Approach, 8th Edition',
    category: 'Bibliografía',
    brand: 'Elsevier',
    priceUsd: 84.5,
    rating: 4.9,
    reviewCount: 4820,
    variantLabel: '8ª Edición · Tapa blanda',
    weightLb: 4.2,
    volumetricWeightLb: 4.4,
    volumeFt3: 0.19,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B09N9L3D5M',
    imageUrl: crearMiniaturaSvg('Atlas Netter 8ª Ed.', 'Anatomía Humana · 4,2 lb', 'seagreen'),
    keywords: ['libro', 'netter', 'atlas', 'anatomia', 'anatomy', 'elsevier'],
  },

  // ── Equipos pesados / voluminosos (ideales para envío marítimo) ──────────
  {
    asin: 'B07K8V4W2N',
    title: 'Master Massage 30" Portable Clinical Examination & Therapy Table, Heavy Duty Aluminum',
    category: 'Equipamiento pesado',
    brand: 'Master Clinical',
    priceUsd: 229.0,
    rating: 4.7,
    reviewCount: 5120,
    variantLabel: 'Plegable 30" · Negro clínico',
    weightLb: 36.0,
    volumetricWeightLb: 48.0,
    volumeFt3: 5.4,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B07K8V4W2N',
    imageUrl: crearMiniaturaSvg('Camilla Portátil 30"', 'Equipo pesado · 36 lb · 5,4 ft³', 'saddlebrown'),
    keywords: ['camilla', 'table', 'equipo pesado', 'maritimo', 'consultorio', 'examen'],
  },
  {
    asin: 'B08D6P3Y9K',
    title: '800D Electric Benchtop Clinical Lab Centrifuge, 4000 RPM, 6x20ml Rotor',
    category: 'Laboratorio',
    brand: 'LabPro',
    priceUsd: 164.0,
    rating: 4.5,
    reviewCount: 890,
    variantLabel: '110V · 6 tubos x 20 ml',
    weightLb: 14.5,
    volumetricWeightLb: 19.0,
    volumeFt3: 1.85,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B08D6P3Y9K',
    imageUrl: crearMiniaturaSvg('Centrífuga Clínica 800D', 'Laboratorio · 14,5 lb · 1,85 ft³', 'darkgoldenrod'),
    keywords: ['centrifuga', 'laboratorio', 'equipo pesado', 'maritimo', 'prp', 'sangre'],
  },
  {
    asin: 'B09M1X7C4P',
    title: '18L Dental & Medical Steam Autoclave Sterilizer, Stainless Steel Chamber, 110V',
    category: 'Equipamiento pesado',
    brand: 'SteriMed',
    priceUsd: 485.0,
    rating: 4.6,
    reviewCount: 410,
    variantLabel: '18 Litros · Acero inoxidable 110V',
    weightLb: 42.0,
    volumetricWeightLb: 55.0,
    volumeFt3: 6.2,
    weightEstimated: false,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B09M1X7C4P',
    imageUrl: crearMiniaturaSvg('Autoclave 18L 110V', 'Equipo pesado · 42 lb · 6,2 ft³', 'dimgray'),
    keywords: ['autoclave', 'esterilizador', 'odontologia', 'equipo pesado', 'maritimo'],
  },

  // ── Producto sin peso listado en Amazon (usa peso estimado de ajustes) ───
  {
    asin: 'B0B4K9W3T2',
    title: 'Precision 12-Piece Minor Surgery Suture & Dressing Stainless Steel Instrument Kit',
    category: 'Instrumental',
    brand: 'MedTools Pro',
    priceUsd: 44.0,
    rating: 4.6,
    reviewCount: 720,
    variantLabel: 'Acero alemán · Estuche rígido',
    weightLb: null,
    volumetricWeightLb: null,
    volumeFt3: 0.09,
    weightEstimated: true,
    restrictedFlag: false,
    restrictedReason: null,
    productUrl: 'https://www.amazon.com/dp/B0B4K9W3T2',
    imageUrl: crearMiniaturaSvg('Kit Instrumental 12 pzas', 'Peso sin listar (estimado)', 'slategray'),
    keywords: ['instrumental', 'pinzas', 'sutura', 'cirugia menor', 'sin peso', 'kit'],
  },

  // ── Artículos con restricción aduanal / sanitaria (disparan revisión) ────
  {
    asin: 'B07C9M6V1Q',
    title: 'BD 3ml Luer-Lok Sterile Disposable Syringes with 23G 1" Needles, Box of 100',
    category: 'Insumos restringidos',
    brand: 'BD Medical',
    priceUsd: 38.5,
    rating: 4.8,
    reviewCount: 2150,
    variantLabel: 'Caja x 100 · 3ml con aguja 23G',
    weightLb: 2.1,
    volumetricWeightLb: 2.4,
    volumeFt3: 0.21,
    weightEstimated: false,
    restrictedFlag: true,
    restrictedReason:
      'Insumo punzocortante estéril (jeringas con aguja): requiere validación sanitaria y permiso aduanal antes de pagar.',
    productUrl: 'https://www.amazon.com/dp/B07C9M6V1Q',
    imageUrl: crearMiniaturaSvg('Jeringas BD con Aguja', 'Requiere revisión aduanal', 'darkorange'),
    keywords: ['jeringa', 'jeringas', 'aguja', 'agujas', 'syringe', 'insumo restringido', 'restringido'],
  },
  {
    asin: 'B09R8T5V2L',
    title: 'Topical Lidocaine 5% Anesthetic Cream Clinical Pack (6 Tubes) + Wireless Ultrasound Probe',
    category: 'Insumos restringidos',
    brand: 'ClinicaRx',
    priceUsd: 310.0,
    rating: 4.7,
    reviewCount: 340,
    variantLabel: 'Pack clínico · Batería litio integrada',
    weightLb: 2.8,
    volumetricWeightLb: 3.1,
    volumeFt3: 0.24,
    weightEstimated: false,
    restrictedFlag: true,
    restrictedReason:
      'Contiene principio activo farmacéutico (lidocaína) y dispositivo médico con batería de litio: sujeto a revisión aduanal y sanitaria.',
    productUrl: 'https://www.amazon.com/dp/B09R8T5V2L',
    imageUrl: crearMiniaturaSvg('Lidocaína + Sonda Eco', 'Requiere revisión aduanal', 'crimson'),
    keywords: ['lidocaina', 'anestesico', 'farmaco', 'medicamento', 'ultrasonido', 'ecografo', 'insumo restringido', 'restringido'],
  },
]

// ── Normalizador ES → EN y extractor de ASIN ───────────────────────────────

const SINONIMOS_ES_EN: ReadonlyArray<[RegExp, string]> = [
  [/\bestetoscopio[s]?\b/g, 'stethoscope littmann'],
  [/\boximetro[s]?\b|\bpulsioximetro[s]?\b/g, 'pulse oximeter'],
  [/\btensiometro[s]?\b|\bbaumanometro[s]?\b|\besfigmomanometro[s]?\b/g, 'blood pressure omron welch allyn'],
  [/\botoscopio[s]?\b/g, 'otoscope welch allyn'],
  [/\boftalmoscopio[s]?\b/g, 'ophthalmoscope welch allyn'],
  [/\blampara[s]?\b|\blinterna[s]?\b/g, 'penlight headlight loupes'],
  [/\buniforme[s]?\b|\bmono[s]?\b|\bpijama[s]?\b/g, 'scrubs figs cherokee'],
  [/\bzueco[s]?\b|\bzapato[s]?\b/g, 'crocs bistro'],
  [/\blibro[s]?\b|\batlas\b/g, 'harrison netter anatomy textbook'],
  [/\bcamilla[s]?\b/g, 'portable examination table'],
  [/\bcentrifuga[s]?\b/g, 'centrifuge lab'],
  [/\bautoclave[s]?\b|\besterilizador[es]?\b/g, 'autoclave sterilizer'],
  [/\bequipo\s+pesado\b|\bmaritimo\b/g, 'portable table centrifuge autoclave'],
  [/\bjeringa[s]?\b|\baguja[s]?\b/g, 'syringes needles'],
  [/\blidocaina\b|\banestesico[s]?\b|\bmedicamento[s]?\b/g, 'lidocaine anesthetic'],
  [/\binsumo\s+restringido\b|\brestringido[s]?\b|\baduana\b/g, 'syringes lidocaine'],
  [/\bsin\s+peso\b|\binstrumental\b|\bpinza[s]?\b/g, 'surgery suture instrument kit'],
]

function normalizarTexto(texto: string): string {
  return texto
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .trim()
}

export function normalizarConsultaAmazon(consulta: string): string {
  let texto = normalizarTexto(consulta)
  for (const [patron, reemplazo] of SINONIMOS_ES_EN) {
    if (patron.test(texto)) {
      texto = `${texto} ${reemplazo}`
    }
  }
  return texto.replace(/\s+/g, ' ').trim()
}

/**
 * Extrae el ASIN (10 caracteres alfanuméricos, normalmente empezando por B0)
 * desde una URL de Amazon o un texto pegado.
 */
export function extraerAsinDeTexto(texto: string): string | null {
  const limpio = texto.trim()
  const porRuta = limpio.match(/(?:\/dp\/|\/gp\/product\/|\/gp\/aw\/d\/|\/product\/)([A-Z0-9]{10})/i)
  if (porRuta) return porRuta[1].toUpperCase()
  const soloAsin = limpio.match(/\b(B0[A-Z0-9]{8})\b/i)
  if (soloAsin) return soloAsin[1].toUpperCase()
  return null
}

/** Detector de posibles restricciones aduanales o sanitarias por título/categoría. */
export function detectarRestriccionAduanal(titulo: string, categoria?: string | null): {
  restricted: boolean
  reason: string | null
} {
  const base = normalizarTexto(`${titulo} ${categoria ?? ''}`)
  const reglas: ReadonlyArray<{ test: RegExp; reason: string }> = [
    {
      test: /\b(syringe|needle|jeringa|aguja|lancet|cateter|catheter)\b/,
      reason: 'Insumo médico punzocortante o invasivo: requiere revisión aduanal y sanitaria.',
    },
    {
      test: /\b(lidocaine|lidocaina|anesthetic|anestesico|insulin|insulina|medication|pharmaceutical|farmaco|ampolla|vial)\b/,
      reason: 'Producto farmacéutico o principio activo regulado: requiere permiso sanitario antes de comprar.',
    },
    {
      test: /\b(ultrasound|ecografo|x-ray|rayos x|defibrillator|desfibrilador|laser)\b/,
      reason: 'Equipo médico activo regulado: requiere verificación aduanal de importación.',
    },
    {
      test: /\b(lithium|litio|aerosol|flammable|inflamable|pressurized)\b/,
      reason: 'Mercancía con batería de litio o material peligroso: sujeto a validación de carga aérea/marítima.',
    },
  ]
  for (const regla of reglas) {
    if (regla.test.test(base)) {
      return { restricted: true, reason: regla.reason }
    }
  }
  return { restricted: false, reason: null }
}

/** Busca en el catálogo mock por ASIN, URL de Amazon o texto libre en español/inglés. */
export function buscarEnCatalogoMock(consulta: string, limite = 6): ProductoCatalogoMock[] {
  const asin = extraerAsinDeTexto(consulta)
  if (asin) {
    const exacto = CATALOGO_AMAZON_MOCK.find((p) => p.asin.toUpperCase() === asin)
    if (exacto) return [exacto]
    // Si el dev pegó una URL con un ASIN desconocido, creamos un item realista al vuelo
    // para que el flujo de pegar link Amazon siempre funcione en el simulador.
    const rest = detectarRestriccionAduanal(consulta)
    return [
      {
        asin,
        title: `Insumo médico Amazon (${asin}) — Importación directa`,
        category: 'Enlace directo',
        brand: 'Amazon USA',
        priceUsd: 89.99,
        rating: 4.7,
        reviewCount: 420,
        variantLabel: 'Estándar',
        weightLb: 1.4,
        volumetricWeightLb: 1.6,
        volumeFt3: 0.12,
        weightEstimated: false,
        restrictedFlag: rest.restricted,
        restrictedReason: rest.reason,
        productUrl: `https://www.amazon.com/dp/${asin}`,
        imageUrl: crearMiniaturaSvg(`Amazon ${asin}`, 'Enlace directo · 1,4 lb', 'steelblue'),
        keywords: [asin.toLowerCase()],
      },
    ]
  }

  const expandida = normalizarConsultaAmazon(consulta)
  if (!expandida) return CATALOGO_AMAZON_MOCK.slice(0, limite)

  const tokens = expandida.split(' ').filter((t) => t.length >= 2)
  const puntuados = CATALOGO_AMAZON_MOCK.map((item) => {
    const textoItem = normalizarTexto(
      `${item.title} ${item.brand} ${item.category} ${item.asin} ${item.keywords.join(' ')}`,
    )
    let puntos = 0
    for (const token of tokens) {
      if (textoItem.includes(token)) puntos += token.length >= 5 ? 3 : 2
      if (item.keywords.some((k) => normalizarTexto(k) === token)) puntos += 4
    }
    return { item, puntos }
  })
    .filter((x) => x.puntos > 0)
    .sort((a, b) => b.puntos - a.puntos || b.item.reviewCount - a.item.reviewCount)

  return puntuados.slice(0, limite).map((x) => x.item)
}

export function buscarProductoPorAsin(asin: string): ProductoCatalogoMock | null {
  const limpio = asin.trim().toUpperCase()
  return CATALOGO_AMAZON_MOCK.find((p) => p.asin.toUpperCase() === limpio) ?? null
}

// ── Cotizador puro en USD y bolívares BCV ──────────────────────────────────

function redondear2(n: number): number {
  return Math.round(n * 100) / 100
}

export function elegirEnvioSugerido(producto: ProductoCatalogoMock, cantidad = 1): MetodoEnvioCompra {
  const peso = (producto.volumetricWeightLb ?? producto.weightLb ?? 1.5) * cantidad
  const ft3 = (producto.volumeFt3 ?? 0.1) * cantidad
  return peso >= 15 || ft3 >= 1.5 ? 'maritimo' : 'aereo'
}

export function cotizarProductoCompra(params: {
  unitPriceUsd: number
  quantity: number
  weightLb: number | null
  volumetricWeightLb: number | null
  volumeFt3: number | null
  weightEstimated: boolean
  shippingMethod: MetodoEnvioCompra
  ajustes: Pick<
    AjustesComprasConfig,
    | 'taxUsaPct'
    | 'serviceFeePct'
    | 'airRatePerLbUsd'
    | 'airMinUsd'
    | 'seaRatePerFt3Usd'
    | 'seaMinUsd'
    | 'fallbackWeightLb'
    | 'bcvRateToday'
  >
}): CotizacionCompra {
  const qty = Math.max(1, Math.round(params.quantity))
  const subtotalUsd = redondear2(params.unitPriceUsd * qty)
  const taxUsaUsd = redondear2(subtotalUsd * (params.ajustes.taxUsaPct / 100))

  const weightEstimated =
    params.weightEstimated ||
    (params.shippingMethod === 'aereo'
      ? params.weightLb === null && (params.volumetricWeightLb ?? 0) === 0
      : params.volumeFt3 === null)
  const pesoUnitario = Math.max(
    params.weightLb ?? params.ajustes.fallbackWeightLb,
    params.volumetricWeightLb ?? 0,
  )
  const billableWeightLb = redondear2(pesoUnitario * qty)
  const ft3Unitario = Math.max(params.volumeFt3 ?? 0.5, 0.1)
  const billableVolumeFt3 = redondear2(ft3Unitario * qty)

  const shippingUsd =
    params.shippingMethod === 'maritimo'
      ? redondear2(Math.max(params.ajustes.seaMinUsd, billableVolumeFt3 * params.ajustes.seaRatePerFt3Usd))
      : redondear2(Math.max(params.ajustes.airMinUsd, billableWeightLb * params.ajustes.airRatePerLbUsd))

  const serviceFeeUsd = redondear2(subtotalUsd * (params.ajustes.serviceFeePct / 100))
  const totalUsd = redondear2(subtotalUsd + taxUsaUsd + shippingUsd + serviceFeeUsd)

  const bcvRate = params.ajustes.bcvRateToday
  const totalVes = bcvRate !== null && bcvRate > 0 ? redondear2(totalUsd * bcvRate) : null

  return {
    unitPriceUsd: params.unitPriceUsd,
    quantity: qty,
    subtotalUsd,
    taxUsaUsd,
    shippingMethod: params.shippingMethod,
    billableWeightLb,
    billableVolumeFt3,
    weightEstimated,
    shippingUsd,
    serviceFeeUsd,
    totalUsd,
    bcvRate,
    totalVes,
  }
}
