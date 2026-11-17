#!/usr/bin/env node
// npm run recolectar -- [--limite N] [--fuentes a,b] [--pausa S] [--salida DIR] [--desde-cero] [--listar]

import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

import { FUENTES } from './fuentes/index.mjs';
import { ClienteHttp } from './http.mjs';
import { correrRecoleccion } from './recolector.mjs';

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..');
const PAUSA_MINIMA_S = 2;

const { values: opciones } = parseArgs({
  options: {
    limite: { type: 'string' },
    fuentes: { type: 'string' },
    pausa: { type: 'string', default: String(PAUSA_MINIMA_S) },
    salida: { type: 'string', default: join(RAIZ, 'salida') },
    'desde-cero': { type: 'boolean', default: false },
    listar: { type: 'boolean', default: false },
  },
});

if (opciones.listar) {
  for (const fuente of FUENTES) {
    console.log(`${fuente.id.padEnd(10)} ${fuente.estado.padEnd(8)} ${fuente.motivo ?? ''}`);
  }
  process.exit(0);
}

const limite = opciones.limite === undefined ? null : Number(opciones.limite);
if (limite !== null && !(Number.isInteger(limite) && limite > 0)) {
  console.error('--limite debe ser un entero mayor que 0.');
  process.exit(1);
}
const pausa = Number(opciones.pausa);
if (!(pausa >= PAUSA_MINIMA_S)) {
  console.error(`--pausa debe ser de al menos ${PAUSA_MINIMA_S} segundos.`);
  process.exit(1);
}

let fuentes = FUENTES;
if (opciones.fuentes) {
  const pedidas = opciones.fuentes.split(',').map((id) => id.trim());
  const desconocida = pedidas.find((id) => !FUENTES.some((fuente) => fuente.id === id));
  if (desconocida) {
    console.error(`Fuente desconocida: ${desconocida}. Usa --listar para verlas.`);
    process.exit(1);
  }
  fuentes = FUENTES.filter((fuente) => pedidas.includes(fuente.id));
}

const resumen = await correrRecoleccion({
  fuentes,
  cliente: new ClienteHttp({ pausaMs: pausa * 1000 }),
  dirSalida: opciones.salida,
  limite,
  desdeCero: opciones['desde-cero'],
  log: (mensaje) => console.log(mensaje),
});

console.log(JSON.stringify({ ...resumen, fuentes: undefined }, null, 2));
if (!resumen.archivo) {
  console.error('No se generó ningún CSV: no hay filas de ninguna fuente activa. Revisa FUENTES.md.');
  process.exit(3);
}
if (resumen.hay_fallas) process.exit(2);
