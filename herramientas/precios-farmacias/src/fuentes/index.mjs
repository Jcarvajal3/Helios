// Registro de fuentes. Añadir o quitar una es añadir o quitar su entrada.
//
// Una fuente «pausada» no se lee jamás: el recolector muestra el motivo y sigue.
// Pasar una a «activa» exige el sí de Javier después de leer FUENTES.md, porque
// hoy todas prohíben esta recolección o la someten a licencia.

import { crearFuenteVtex } from './vtex.mjs';

// Criterio de «solo medicamentos» en SAAS, sobre su propio árbol «Medicamentos».
// Fuera: 60202 Antioxidante y todo 603 Bienestar Integral (vitaminas, productos
// naturales y suplementos). Dermocosmética y Papeletas solo con clase terapéutica.
const CATEGORIAS_SAAS = [
  { ruta: '6/601/60101' }, // RX
  { ruta: '6/601/60102' }, // Hospitalarios
  { ruta: '6/602/60201' }, // Antigripales y analgésicos
  { ruta: '6/602/60203' }, // Antiinflamatorios
  { ruta: '6/602/60204' }, // Antisépticos
  { ruta: '6/602/60205' }, // Digestivos
  { ruta: '6/602/60206', exigeClaseTerapeutica: true }, // Dermocosmética
  { ruta: '6/602/60207', exigeClaseTerapeutica: true }, // Papeletas y envasados
];

export const FUENTES = [
  {
    id: 'keiti',
    nombre: 'keiti',
    estado: 'pausada',
    motivo: 'Sus términos (§5) someten la extracción automatizada a licencia de pago; falta la decisión de Javier.',
  },
  crearFuenteVtex({
    id: 'saas',
    nombre: 'Farmacia SAAS',
    base: 'https://www.farmaciasaas.com',
    categorias: CATEGORIAS_SAAS,
    estado: 'pausada',
    motivo: 'Sus términos (/tyc) prohíben reproducir, copiar o usar el contenido sin consentimiento escrito.',
  }),
  crearFuenteVtex({
    id: 'locatel',
    nombre: 'Locatel',
    base: 'https://www.locatel.com.ve',
    // Farmacia > Medicamentos según el informe previo; sin probar en volumen.
    categorias: [{ ruta: '2/21' }],
    estado: 'pausada',
    motivo: 'Sus términos prohíben anunciar públicamente el contenido o distribuirlo con fines comerciales.',
  }),
  {
    id: 'farmatodo',
    nombre: 'Farmatodo',
    estado: 'pausada',
    motivo: 'Sus términos prohíben reproducir o copiar el contenido sin autorización; sin adaptador escrito.',
  },
  {
    id: 'farmabien',
    nombre: 'FarmaBien',
    estado: 'pausada',
    motivo: 'Responde 429 con un desafío de seguridad de Vercel; no se evade y no hay adaptador.',
  },
];
