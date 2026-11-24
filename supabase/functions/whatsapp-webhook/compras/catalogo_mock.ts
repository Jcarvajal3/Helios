// ═══════════════════════════════════════════════════════════════════════════
// Helios — Catálogo Amazon Mock (24 productos médicos realistas)
//
// Implementa `ProveedorCatalogo` para pruebas, desarrollo y demos sin
// depender de credenciales externas. Incluye estetoscopios, diagnóstico,
// uniformes/consultorio, libros médicos, equipos pesados para marítimo,
// un artículo sin peso listado (fallback) y artículos con restricción
// sanitaria/aduanal.
// ═══════════════════════════════════════════════════════════════════════════

import { normalizar } from '../logica.ts'
import { extraerAsinDeTexto, normalizarBusquedaMedica } from './amazon_parser.ts'
import type { ProductoDetalle, ProductoResumen, ProveedorCatalogo } from './tipos.ts'

type ProductoMockInterno = ProductoDetalle & {
  etiquetas: string[]
}

function img(etiqueta: string, color = '0f766e'): string {
  return `https://placehold.co/600x600/${color}/ffffff.png?text=${encodeURIComponent(etiqueta)}`
}

export const CATALOGO_MEDICO_MOCK: ReadonlyArray<ProductoMockInterno> = [
  // ── Estetoscopios (3) ──────────────────────────────────────────────────
  {
    asin: 'B00QES9K4G',
    titulo: '3M Littmann Classic III Monitoring Stethoscope, Black Edition (27 inch)',
    precioUsd: 104.95,
    imagenUrl: img('Littmann Classic III'),
    url: 'https://www.amazon.com/dp/B00QES9K4G',
    rating: 4.8,
    resenas: 18420,
    categoria: 'Estetoscopios',
    prime: true,
    pesoLb: 1.1,
    dimensionesIn: { largo: 13.0, ancho: 6.5, alto: 2.0 },
    variantes: ['Negro (Black Edition)', 'Azul Marino', 'Borgoña'],
    disponible: true,
    descripcionCorta: 'Doble campana en acero inoxidable para evaluación de adultos y pediatría, diafragma sintonizable.',
    etiquetas: ['estetoscopio', 'fonendoscopio', 'littmann', 'classic 3', 'classic iii', '3m', 'stethoscope', 'consulta'],
  },
  {
    asin: 'B0157I0Q8C',
    titulo: '3M Littmann Cardiology IV Diagnostic Stethoscope, Champagne-Finish',
    precioUsd: 219.99,
    imagenUrl: img('Littmann Cardiology IV', '115e59'),
    url: 'https://www.amazon.com/dp/B0157I0Q8C',
    rating: 4.9,
    resenas: 9840,
    categoria: 'Estetoscopios',
    prime: true,
    pesoLb: 1.4,
    dimensionesIn: { largo: 14.5, ancho: 6.8, alto: 2.1 },
    variantes: ['Champagne / Negro', 'Negro Mate', 'Azul Marino'],
    disponible: true,
    descripcionCorta: 'Alta sensibilidad acústica para cardiología y medicina interna, tubo de doble lumen.',
    etiquetas: ['estetoscopio', 'fonendoscopio', 'littmann', 'cardiology', 'cardiologia', 'iv', '4', '3m', 'stethoscope'],
  },
  {
    asin: 'B001CCINO4',
    titulo: '3M Littmann Lightweight II S.E. Stethoscope, Ceil Blue',
    precioUsd: 58.5,
    imagenUrl: img('Littmann Lightweight II', '0d9488'),
    url: 'https://www.amazon.com/dp/B001CCINO4',
    rating: 4.7,
    resenas: 7120,
    categoria: 'Estetoscopios',
    prime: true,
    pesoLb: 0.7,
    dimensionesIn: { largo: 12.8, ancho: 6.2, alto: 1.8 },
    variantes: ['Azul Cielo', 'Negro', 'Borgoña'],
    disponible: true,
    descripcionCorta: 'Modelo ultraligero con campana en forma de gota para toma de tensión y evaluación general.',
    etiquetas: ['estetoscopio', 'littmann', 'lightweight', 'liviano', 'economico', 'stethoscope'],
  },

  // ── Diagnóstico (7) ────────────────────────────────────────────────────
  {
    asin: 'B07PQ8WTC4',
    titulo: 'Zacurate Pro Series 500DL Fingertip Pulse Oximeter Blood Oxygen Saturation Monitor',
    precioUsd: 24.95,
    imagenUrl: img('Oximetro Zacurate'),
    url: 'https://www.amazon.com/dp/B07PQ8WTC4',
    rating: 4.7,
    resenas: 54200,
    categoria: 'Diagnóstico',
    prime: true,
    pesoLb: 0.35,
    dimensionesIn: { largo: 4.5, ancho: 3.2, alto: 2.0 },
    variantes: ['Negro', 'Azul Marino', 'Blanco'],
    disponible: true,
    descripcionCorta: 'Lectura rápida de SpO2 y frecuencia cardíaca con pantalla LED, funda de silicón y pilas incluidas.',
    etiquetas: ['oximetro', 'pulsioximetro', 'saturacion', 'spo2', 'zacurate', 'masimo', 'pulse oximeter', 'diagnostico'],
  },
  {
    asin: 'B07S2H3XBB',
    titulo: 'OMRON Platinum Blood Pressure Monitor, Upper Arm Digital Cuff with Bluetooth',
    precioUsd: 89.99,
    imagenUrl: img('Omron Platinum'),
    url: 'https://www.amazon.com/dp/B07S2H3XBB',
    rating: 4.6,
    resenas: 12650,
    categoria: 'Diagnóstico',
    prime: true,
    pesoLb: 2.2,
    dimensionesIn: { largo: 8.2, ancho: 6.5, alto: 4.8 },
    variantes: ['Brazalete estándar (22-42 cm)'],
    disponible: true,
    descripcionCorta: 'Tensiómetro digital de brazo con doble pantalla, 200 memorias y sincronización Bluetooth.',
    etiquetas: ['tensiometro', 'esfigmomanometro', 'presion arterial', 'omron', 'platinum', 'blood pressure monitor', 'digital'],
  },
  {
    asin: 'B0051R3H3O',
    titulo: 'Welch Allyn Pocket Plus LED Otoscope with Hard Case',
    precioUsd: 168.0,
    imagenUrl: img('Otoscopio Welch Allyn', '134e4a'),
    url: 'https://www.amazon.com/dp/B0051R3H3O',
    rating: 4.8,
    resenas: 2190,
    categoria: 'Diagnóstico',
    prime: true,
    pesoLb: 0.9,
    dimensionesIn: { largo: 8.0, ancho: 4.2, alto: 2.2 },
    variantes: ['Onyx (Negro)', 'Azul Marino', 'Blanco'],
    disponible: true,
    descripcionCorta: 'Otoscopio de bolsillo con iluminación LED SureColor de fibra óptica y estuche rígido.',
    etiquetas: ['otoscopio', 'orl', 'oido', 'welch allyn', 'otoscope', 'pocket', 'diagnostico'],
  },
  {
    asin: 'B00MUK6M82',
    titulo: 'Braun ThermoScan 7 Digital Infrared Ear Thermometer IRT6520',
    precioUsd: 54.99,
    imagenUrl: img('Braun ThermoScan 7'),
    url: 'https://www.amazon.com/dp/B00MUK6M82',
    rating: 4.7,
    resenas: 31400,
    categoria: 'Diagnóstico',
    prime: true,
    pesoLb: 0.85,
    dimensionesIn: { largo: 8.4, ancho: 5.1, alto: 2.4 },
    variantes: ['IRT6520 con 21 protectores'],
    disponible: true,
    descripcionCorta: 'Termómetro infrarrojo de oído con punta precalentada y guía de fiebre por edad.',
    etiquetas: ['termometro', 'infrarrojo', 'braun', 'thermoscan', 'fiebre', 'pediatria', 'thermometer', 'infrared'],
  },
  {
    asin: 'B078W2R5M1',
    titulo: 'Accu-Chek Guide Blood Glucose Meter for Diabetes Monitoring',
    precioUsd: 32.5,
    imagenUrl: img('Glucometro Accu-Chek'),
    url: 'https://www.amazon.com/dp/B078W2R5M1',
    rating: 4.6,
    resenas: 8930,
    categoria: 'Diagnóstico',
    prime: true,
    pesoLb: 0.65,
    dimensionesIn: { largo: 6.2, ancho: 4.4, alto: 2.5 },
    variantes: ['Medidor Accu-Chek Guide'],
    disponible: true,
    descripcionCorta: 'Glucómetro digital con pantalla retroiluminada, puerto iluminado y conectividad Bluetooth.',
    etiquetas: ['glucometro', 'glucosa', 'glicemia', 'diabetes', 'accu chek', 'glucometer', 'glucose meter'],
  },
  {
    asin: 'B08K3M7P4L',
    titulo: 'LED Surgical Medical Headlamp 5W Rechargeable Adjustable Spot Light',
    precioUsd: 79.0,
    imagenUrl: img('Lampara Frontal LED', '155e75'),
    url: 'https://www.amazon.com/dp/B08K3M7P4L',
    rating: 4.5,
    resenas: 1340,
    categoria: 'Diagnóstico',
    prime: true,
    pesoLb: 1.25,
    dimensionesIn: { largo: 8.5, ancho: 7.0, alto: 4.0 },
    variantes: ['5W Luz Blanca 5500K', '5W con filtro amarillo'],
    disponible: true,
    descripcionCorta: 'Lámpara frontal LED recargable con haz enfocable para procedimientos médicos y odontológicos.',
    etiquetas: ['lampara frontal', 'luz frontal', 'quirurgica', 'odontologia', 'headlamp', 'led', 'cirugia'],
  },
  {
    asin: 'B07D5F9X2Q',
    titulo: 'Welch Allyn Professional Halogen Medical Penlight with Pupil Gauge',
    precioUsd: 21.95,
    imagenUrl: img('Linterna Pupilar'),
    url: 'https://www.amazon.com/dp/B07D5F9X2Q',
    rating: 4.7,
    resenas: 4820,
    categoria: 'Diagnóstico',
    prime: true,
    pesoLb: 0.25,
    dimensionesIn: { largo: 6.0, ancho: 1.5, alto: 1.0 },
    variantes: ['Acero inoxidable'],
    disponible: true,
    descripcionCorta: 'Linterna pupilar profesional reutilizable con luz halógena cálida y escala de pupilas.',
    etiquetas: ['linterna', 'linterna pupilar', 'lampara', 'pupila', 'welch allyn', 'penlight', 'neurologia'],
  },

  // ── Uniformes y Consultorio (4) ────────────────────────────────────────
  {
    asin: 'B09M4L8K2R',
    titulo: 'FIGS Technical Collection Medical Scrubs Set (Catarina Top + Zamora Jogger)',
    precioUsd: 86.0,
    imagenUrl: img('Scrubs FIGS', '1e3a5f'),
    url: 'https://www.amazon.com/dp/B09M4L8K2R',
    rating: 4.8,
    resenas: 6540,
    categoria: 'Uniformes y Consultorio',
    prime: true,
    pesoLb: 1.3,
    dimensionesIn: { largo: 11.5, ancho: 9.0, alto: 2.2 },
    variantes: ['S - Azul Marino', 'M - Azul Marino', 'M - Negro', 'L - Negro'],
    disponible: true,
    descripcionCorta: 'Uniforme médico en tela FIONx antiarrugas, suave y elástica en 4 direcciones con bolsillos funcionales.',
    etiquetas: ['scrubs', 'uniforme', 'uniformes', 'bata', 'pijama', 'figs', 'consultorio', 'ropa medica'],
  },
  {
    asin: 'B07C9K5N8T',
    titulo: 'Crocs Specialist II Vent Medical Nursing Clogs, Slip Resistant',
    precioUsd: 49.99,
    imagenUrl: img('Crocs Medicos', '334155'),
    url: 'https://www.amazon.com/dp/B07C9K5N8T',
    rating: 4.6,
    resenas: 15200,
    categoria: 'Uniformes y Consultorio',
    prime: true,
    pesoLb: 1.8,
    dimensionesIn: { largo: 12.0, ancho: 8.0, alto: 4.5 },
    variantes: ['Negro - US 8', 'Azul Marino - US 9', 'Blanco - US 10'],
    disponible: true,
    descripcionCorta: 'Zuecos médicos ergonómicos con puntera cerrada, suela antideslizante y fáciles de desinfectar.',
    etiquetas: ['zuecos', 'crocs', 'zapatos', 'calzado medico', 'clogs', 'quirofano', 'guardia'],
  },
  {
    asin: 'B08B7T4W6J',
    titulo: 'Elite Bags Doctor Medical Briefcase and Home Visit Bag',
    precioUsd: 129.0,
    imagenUrl: img('Maletin Medico', '3f3f46'),
    url: 'https://www.amazon.com/dp/B08B7T4W6J',
    rating: 4.6,
    resenas: 920,
    categoria: 'Uniformes y Consultorio',
    prime: true,
    pesoLb: 3.8,
    dimensionesIn: { largo: 16.5, ancho: 12.0, alto: 6.5 },
    variantes: ['Negro Clásico', 'Marrón Oscuro'],
    disponible: true,
    descripcionCorta: 'Maletín médico con divisores internos acolchados, compartimento para laptop y cierre con llave.',
    etiquetas: ['maletin', 'bolso medico', 'doctor bag', 'medical bag', 'visita domiciliaria', 'consultorio'],
  },
  {
    asin: 'B08R6N3Y9V',
    titulo: '3.5x Dental Surgical Binocular Loupes 420mm Working Distance with Aluminum Case',
    precioUsd: 118.0,
    imagenUrl: img('Lupa Binocular 3.5x', '0f766e'),
    url: 'https://www.amazon.com/dp/B08R6N3Y9V',
    rating: 4.5,
    resenas: 1180,
    categoria: 'Uniformes y Consultorio',
    prime: true,
    pesoLb: 1.6,
    dimensionesIn: { largo: 9.0, ancho: 7.2, alto: 4.2 },
    variantes: ['3.5x - 420mm Negro', '3.5x - 420mm Plata'],
    disponible: true,
    descripcionCorta: 'Lupa binocular odontológica y quirúrgica 3.5x con óptica de vidrio óptico y maletín de aluminio.',
    etiquetas: ['lupa', 'lupas', 'binocular', 'odontologica', 'odontologia', 'dental', '3.5x', 'loupes', 'quirurgica'],
  },

  // ── Libros Médicos (2) ─────────────────────────────────────────────────
  {
    asin: 'B09R2H5K8M',
    titulo: "Harrison's Principles of Internal Medicine, 21st Edition (2-Volume Hardcover Set)",
    precioUsd: 245.0,
    imagenUrl: img('Harrison 21st Ed', '1d4ed8'),
    url: 'https://www.amazon.com/dp/B09R2H5K8M',
    rating: 4.8,
    resenas: 1640,
    categoria: 'Libros Médicos',
    prime: true,
    pesoLb: 14.2,
    dimensionesIn: { largo: 11.2, ancho: 8.8, alto: 4.8 },
    variantes: ['Tapa dura (2 volúmenes)'],
    disponible: true,
    descripcionCorta: 'Referencia clásica de medicina interna en 2 tomos de tapa dura, 21.ª edición actualizada.',
    etiquetas: ['libro', 'libros', 'harrison', 'medicina interna', 'internal medicine', 'textbook', 'principios'],
  },
  {
    asin: 'B09L8X3C4N',
    titulo: 'Netter Atlas of Human Anatomy: Classic Regional Approach, 8th Edition',
    precioUsd: 84.99,
    imagenUrl: img('Netter Atlas 8th Ed', '0369a1'),
    url: 'https://www.amazon.com/dp/B09L8X3C4N',
    rating: 4.9,
    resenas: 3890,
    categoria: 'Libros Médicos',
    prime: true,
    pesoLb: 5.4,
    dimensionesIn: { largo: 11.0, ancho: 8.6, alto: 1.6 },
    variantes: ['Tapa blanda (8.ª ed.)', 'Tapa dura'],
    disponible: true,
    descripcionCorta: 'Atlas ilustrado de anatomía humana por regiones con acceso digital a láminas en alta resolución.',
    etiquetas: ['libro', 'libros', 'netter', 'atlas', 'anatomia', 'anatomy', 'textbook'],
  },

  // ── Equipos Pesados / Grandes (Marítimo) (4) ───────────────────────────
  {
    asin: 'B09X7T2M5W',
    titulo: '18L Class N Tabletop Steam Autoclave Sterilizer Stainless Steel for Dental & Medical Clinic',
    precioUsd: 589.0,
    imagenUrl: img('Autoclave 18L', '475569'),
    url: 'https://www.amazon.com/dp/B09X7T2M5W',
    rating: 4.5,
    resenas: 310,
    categoria: 'Equipos Médicos',
    prime: false,
    pesoLb: 68.5,
    dimensionesIn: { largo: 24.5, ancho: 18.5, alto: 16.5 },
    variantes: ['18L - 110V (3 bandejas)', '23L - 110V'],
    disponible: true,
    descripcionCorta: 'Autoclave de vapor de mesa de 18 litros en acero inoxidable con ciclos automáticos a 121 °C y 134 °C.',
    etiquetas: ['autoclave', 'esterilizador', '18l', 'vapor', 'odontologia', 'consultorio', 'sterilizer', 'maritimo'],
  },
  {
    asin: 'B08H4P6R2K',
    titulo: 'Portable Folding Medical Examination Table Aluminum Frame with Carry Bag',
    precioUsd: 279.0,
    imagenUrl: img('Camilla Portatil', '0f766e'),
    url: 'https://www.amazon.com/dp/B08H4P6R2K',
    rating: 4.6,
    resenas: 740,
    categoria: 'Equipos Médicos',
    prime: true,
    pesoLb: 34.0,
    dimensionesIn: { largo: 37.0, ancho: 28.0, alto: 8.0 },
    variantes: ['Negro', 'Azul Médico'],
    disponible: true,
    descripcionCorta: 'Camilla plegable de examen en aluminio reforzado, tapicería lavable resistente a desinfectantes y respaldo reclinable.',
    etiquetas: ['camilla', 'camilla portatil', 'examen', 'consultorio', 'exam table', 'folding', 'estetica', 'maritimo'],
  },
  {
    asin: 'B08N9W4C7Y',
    titulo: 'Mobile Rolling LED Medical Examination Lamp with 5-Caster Stand & Gooseneck',
    precioUsd: 189.0,
    imagenUrl: img('Lampara Rodante LED', '155e75'),
    url: 'https://www.amazon.com/dp/B08N9W4C7Y',
    rating: 4.4,
    resenas: 480,
    categoria: 'Equipos Médicos',
    prime: true,
    pesoLb: 21.5,
    dimensionesIn: { largo: 28.0, ancho: 19.0, alto: 10.5 },
    variantes: ['Base rodante 5 ruedas (110V)'],
    disponible: true,
    descripcionCorta: 'Lámpara de examen rodante LED de luz fría sin sombras con cuello flexible y altura regulable.',
    etiquetas: ['lampara', 'lampara de examen', 'lampara rodante', 'pedestal', 'examination lamp', 'rolling', 'consultorio'],
  },
  {
    asin: 'B07V5G8M2L',
    titulo: 'Clinical Benchtop Lab Centrifuge 4000 RPM 8x15mL Digital Timer',
    precioUsd: 215.0,
    imagenUrl: img('Centrifuga Clinica', '334155'),
    url: 'https://www.amazon.com/dp/B07V5G8M2L',
    rating: 4.5,
    resenas: 590,
    categoria: 'Equipos de Laboratorio',
    prime: true,
    pesoLb: 18.4,
    dimensionesIn: { largo: 14.5, ancho: 13.5, alto: 12.0 },
    variantes: ['8x15 mL - 110V'],
    disponible: true,
    descripcionCorta: 'Centrífuga clínica de mesa hasta 4000 RPM para tubos de 15 mL, ideal para PRP y laboratorio clínico.',
    etiquetas: ['centrifuga', 'laboratorio', 'prp', 'plasma', 'centrifuge', 'benchtop', 'clinica'],
  },

  // ── Sin peso listado (fallback peso estimado) (1) ──────────────────────
  {
    asin: 'B0B3K9M1Z4',
    titulo: 'Nitrile Exam Gloves Powder-Free Medical Grade Box of 200 (Medium, Blue)',
    precioUsd: 19.99,
    imagenUrl: img('Guantes Nitrilo 200', '0284c7'),
    url: 'https://www.amazon.com/dp/B0B3K9M1Z4',
    rating: 4.7,
    resenas: 9400,
    categoria: 'Descartables',
    prime: true,
    pesoLb: null,
    dimensionesIn: null,
    variantes: ['S (Caja x200)', 'M (Caja x200)', 'L (Caja x200)'],
    disponible: true,
    descripcionCorta: 'Guantes de examen en nitrilo sin talco, grado médico, caja dispensadora de 200 unidades.',
    etiquetas: ['guantes', 'nitrilo', 'descartables', 'gloves', 'nitrile', 'examen', 'sin peso'],
  },

  // ── Productos con restricción sanitaria / aduanal (3) ──────────────────
  {
    asin: 'B09D4S7V2X',
    titulo: 'Sterile Absorbable Surgical Suture Vicryl 3-0 with Reverse Cutting Needle (Box of 12)',
    precioUsd: 64.0,
    imagenUrl: img('Suturas Vicryl 3-0', 'b45309'),
    url: 'https://www.amazon.com/dp/B09D4S7V2X',
    rating: 4.6,
    resenas: 210,
    categoria: 'Insumos Quirúrgicos',
    prime: false,
    pesoLb: 0.4,
    dimensionesIn: { largo: 6.0, ancho: 4.5, alto: 1.5 },
    variantes: ['3-0 (Caja x12)', '4-0 (Caja x12)'],
    disponible: true,
    descripcionCorta: 'Suturas quirúrgicas estériles absorbibles con aguja atraumática en empaque individual.',
    etiquetas: ['sutura', 'suturas', 'vicryl', 'absorbible', 'quirurgica', 'suture', 'sterile', 'aguja'],
  },
  {
    asin: 'B09F6R8T3M',
    titulo: 'Rapid Diagnostic Test Kit Chemical Reagent Strips Professional Lab Pack (50 Tests)',
    precioUsd: 48.5,
    imagenUrl: img('Kit Reactivos Lab', 'b45309'),
    url: 'https://www.amazon.com/dp/B09F6R8T3M',
    rating: 4.5,
    resenas: 340,
    categoria: 'Reactivos y Laboratorio',
    prime: false,
    pesoLb: 0.9,
    dimensionesIn: { largo: 7.5, ancho: 5.0, alto: 3.2 },
    variantes: ['Caja x50 pruebas'],
    disponible: true,
    descripcionCorta: 'Kit de pruebas rápidas con reactivos químicos para diagnóstico in vitro de uso profesional.',
    etiquetas: ['reactivo', 'reactivos', 'prueba rapida', 'pruebas rapidas', 'reagent', 'rapid test', 'laboratorio'],
  },
  {
    asin: 'B09G8A2C5P',
    titulo: 'Dental Local Anesthetic Cartridges Lidocaine 2% Epinephrine + Sterile Syringes Pack',
    precioUsd: 72.0,
    imagenUrl: img('Anestesia Dental', 'b45309'),
    url: 'https://www.amazon.com/dp/B09G8A2C5P',
    rating: 4.7,
    resenas: 155,
    categoria: 'Odontología Especializada',
    prime: false,
    pesoLb: 1.5,
    dimensionesIn: { largo: 8.0, ancho: 5.5, alto: 3.0 },
    variantes: ['Caja x50 cartuchos + jeringas'],
    disponible: true,
    descripcionCorta: 'Cartuchos de anestesia local dental con lidocaína al 2% y jeringas estériles descartables.',
    etiquetas: ['anestesia', 'anestesia dental', 'cartuchos', 'lidocaina', 'jeringa', 'jeringas', 'syringe', 'anesthetic'],
  },
]

function aResumen(p: ProductoMockInterno): ProductoResumen {
  return {
    asin: p.asin,
    titulo: p.titulo,
    precioUsd: p.precioUsd,
    imagenUrl: p.imagenUrl,
    url: p.url,
    rating: p.rating,
    resenas: p.resenas,
    categoria: p.categoria,
    prime: p.prime,
    pesoLb: p.pesoLb,
    dimensionesIn: p.dimensionesIn ?? null,
  }
}

function aDetalle(p: ProductoMockInterno): ProductoDetalle {
  return {
    ...aResumen(p),
    variantes: [...p.variantes],
    disponible: p.disponible,
    descripcionCorta: p.descripcionCorta,
  }
}

/**
 * Proveedor local de catálogo Amazon con 24 artículos médicos realistas y
 * búsqueda por relevancia ES/EN + coincidencia directa por ASIN.
 */
export class ProveedorAmazonMock implements ProveedorCatalogo {
  readonly nombre = 'mock'

  async buscar(query: string, limite = 4): Promise<ProductoResumen[]> {
    const tope = Math.max(1, Math.min(10, Math.floor(limite)))
    const asinDirecto = extraerAsinDeTexto(query)
    if (asinDirecto) {
      const exacto = CATALOGO_MEDICO_MOCK.find((p) => p.asin === asinDirecto)
      return exacto ? [aResumen(exacto)] : []
    }

    const { original, consultaEn, tokens } = normalizarBusquedaMedica(query)
    if (tokens.length === 0) return []

    const origNorm = normalizar(original)
    const enNorm = normalizar(consultaEn)

    const puntuados = CATALOGO_MEDICO_MOCK.map((p) => {
      const tituloNorm = normalizar(p.titulo)
      const catNorm = normalizar(p.categoria)
      const descNorm = normalizar(p.descripcionCorta)
      const etiquetasNorm = p.etiquetas.map((e) => normalizar(e))
      const bolsaEtiquetas = ` ${etiquetasNorm.join(' ')} `

      let puntos = 0
      if (origNorm.length >= 3 && (tituloNorm.includes(origNorm) || bolsaEtiquetas.includes(` ${origNorm} `))) {
        puntos += 45
      }
      if (enNorm.length >= 3 && tituloNorm.includes(enNorm)) {
        puntos += 40
      }

      for (const token of tokens) {
        const rePalabra = new RegExp(`(^|\\s)${token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`)
        if (etiquetasNorm.some((e) => e === token || rePalabra.test(e))) {
          puntos += 25
        }
        if (rePalabra.test(tituloNorm)) {
          puntos += 20
        } else if (token.length >= 4 && tituloNorm.includes(token)) {
          puntos += 12
        }
        if (rePalabra.test(catNorm)) {
          puntos += 10
        }
        if (rePalabra.test(descNorm)) {
          puntos += 6
        }
      }

      if (puntos > 0) {
        // Desempate sutil por reputación del producto
        puntos += (p.rating ?? 0) * 0.5 + Math.min((p.resenas ?? 0) / 100000, 1)
      }

      return { producto: p, puntos }
    })

    return puntuados
      .filter((x) => x.puntos > 0)
      .sort((a, b) => b.puntos - a.puntos)
      .slice(0, tope)
      .map((x) => aResumen(x.producto))
  }

  async detalle(asin: string): Promise<ProductoDetalle | null> {
    const limpio = (extraerAsinDeTexto(asin) ?? asin.trim().toUpperCase())
    const encontrado = CATALOGO_MEDICO_MOCK.find((p) => p.asin === limpio)
    return encontrado ? aDetalle(encontrado) : null
  }
}
