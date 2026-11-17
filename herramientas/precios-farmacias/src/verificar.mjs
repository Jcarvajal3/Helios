#!/usr/bin/env node
// Compara una muestra del CSV con lo que publica la ficha de cada producto.
// npm run verificar -- salida/precios-AAAAMMDD.csv [--muestra 25]

import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

import { leerCsv } from './filas.mjs';
import { ClienteHttp } from './http.mjs';

// Lee el precio del JSON-LD de la ficha.
export function precioDeFicha(html) {
  const bloques = html.matchAll(/<script[^>]*application\/ld\+json[^>]*>([\s\S]*?)<\/script>/g);
  for (const [, contenido] of bloques) {
    let datos;
    try {
      datos = JSON.parse(contenido);
    } catch {
      continue;
    }
    if (datos['@type'] !== 'Product' || !datos.offers) continue;
    const oferta = datos.offers;
    const precio = oferta.lowPrice ?? oferta.price ?? oferta.offers?.[0]?.price;
    if (precio !== undefined) return { precio: Number(precio), moneda: oferta.priceCurrency ?? null };
  }
  return null;
}

async function principal() {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: { muestra: { type: 'string', default: '25' } },
  });
  if (!positionals[0]) {
    console.error('Indica el CSV: npm run verificar -- salida/precios-AAAAMMDD.csv');
    process.exit(1);
  }
  const filas = leerCsv(await readFile(positionals[0], 'utf8'));
  const muestra = filas
    .map((fila) => ({ fila, orden: Math.random() }))
    .sort((a, b) => a.orden - b.orden)
    .slice(0, Number(values.muestra))
    .map(({ fila }) => fila);

  const cliente = new ClienteHttp();
  let iguales = 0;
  let distintos = 0;
  let sinLeer = 0;
  for (const fila of muestra) {
    const respuesta = await cliente.obtener(fila.url, { accept: 'text/html' });
    const ficha = respuesta.ok ? precioDeFicha(await respuesta.text()) : null;
    if (!ficha) {
      sinLeer += 1;
      console.log(`SIN LEER  ${fila.farmacia} | ${fila.nombre} | ${fila.url}`);
    } else if (Math.abs(ficha.precio - Number(fila.precio)) < 0.005) {
      iguales += 1;
      console.log(`IGUAL     ${fila.farmacia} | ${fila.nombre} | ${fila.precio} ${fila.moneda}`);
    } else {
      distintos += 1;
      console.log(`DISTINTO  ${fila.farmacia} | ${fila.nombre} | CSV ${fila.precio} | ficha ${ficha.precio} | ${fila.url}`);
    }
  }
  console.log(`\nMuestra ${muestra.length}: ${iguales} iguales, ${distintos} distintos, ${sinLeer} sin leer.`);
  if (distintos || sinLeer) process.exit(2);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) await principal();
