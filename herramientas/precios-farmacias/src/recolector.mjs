// Recorre las fuentes activas, guarda lo leído página a página para poder
// reanudar sin repetir y entrega el CSV.

import { appendFile, mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { aCsv, fechaCompacta, horaCaracas, prepararFilas } from './filas.mjs';
import { BloqueoError } from './http.mjs';

async function leerSiExiste(ruta) {
  try {
    return await readFile(ruta, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

async function escribirAtomico(ruta, contenido) {
  await writeFile(`${ruta}.tmp`, contenido, 'utf8');
  await rename(`${ruta}.tmp`, ruta);
}

// Caché de una fuente en un día: filas leídas y hasta dónde se llegó. Primero se
// añaden las filas y luego se guarda el avance; si algo se corta entre ambos, se
// relee una página y la deduplicación limpia lo repetido.
class Cache {
  constructor(directorio) {
    this.directorio = directorio;
    this.rutaFilas = join(directorio, 'filas.jsonl');
    this.rutaAvance = join(directorio, 'avance.json');
  }

  async cargar() {
    await mkdir(this.directorio, { recursive: true });
    const avance = await leerSiExiste(this.rutaAvance);
    const filas = await leerSiExiste(this.rutaFilas);
    this.avance = avance ? JSON.parse(avance) : { segmentos: {}, descartes: {} };
    this.filas = filas ? filas.split('\n').filter(Boolean).map((linea) => JSON.parse(linea)) : [];
  }

  async guardarPagina(clave, pagina, siguiente) {
    if (pagina.filas.length) {
      await appendFile(this.rutaFilas, pagina.filas.map((fila) => `${JSON.stringify(fila)}\n`).join(''), 'utf8');
      this.filas.push(...pagina.filas);
    }
    const anterior = this.avance.segmentos[clave] ?? { leidos: 0 };
    this.avance.segmentos[clave] = {
      desde: siguiente ?? 0,
      completo: siguiente === null,
      leidos: anterior.leidos + pagina.leidos,
      total: pagina.total,
    };
    for (const [motivo, cantidad] of Object.entries(pagina.descartes ?? {})) {
      this.avance.descartes[motivo] = (this.avance.descartes[motivo] ?? 0) + cantidad;
    }
    await escribirAtomico(this.rutaAvance, JSON.stringify(this.avance, null, 2));
  }
}

async function recolectarFuente(fuente, { cliente, cache, limite, reloj, log }) {
  const segmentos = await fuente.segmentos(cliente);
  for (const segmento of segmentos) {
    const previo = cache.avance.segmentos[segmento.clave];
    if (previo?.completo) continue;
    let desde = previo?.desde ?? 0;
    while (desde !== null) {
      if (limite && cache.filas.length >= limite) return 'limite';
      const pagina = await fuente.leerPagina(cliente, segmento, desde, horaCaracas(reloj()));
      await cache.guardarPagina(segmento.clave, pagina, pagina.siguiente);
      log(`${fuente.id} ${segmento.clave}: ${desde + pagina.leidos}/${pagina.total} productos, ${cache.filas.length} filas`);
      desde = pagina.siguiente;
    }
  }
  return 'completa';
}

function contarPor(filas, campo) {
  const cuentas = {};
  for (const fila of filas) cuentas[fila[campo]] = (cuentas[fila[campo]] ?? 0) + 1;
  return cuentas;
}

export async function correrRecoleccion({
  fuentes,
  cliente,
  dirSalida,
  limite = null,
  desdeCero = false,
  reloj = () => new Date(),
  log = () => {},
}) {
  const dia = fechaCompacta(reloj());
  const leidas = [];
  const resumenFuentes = {};
  let hayIncompletas = false;
  let hayFallas = false;

  for (const fuente of fuentes) {
    if (fuente.estado !== 'activa') {
      resumenFuentes[fuente.id] = { estado: 'pausada', motivo: fuente.motivo };
      log(`${fuente.id}: en pausa. ${fuente.motivo}`);
      continue;
    }
    const directorio = join(dirSalida, '.cache', dia, fuente.id);
    if (desdeCero) await rm(directorio, { recursive: true, force: true });
    const cache = new Cache(directorio);
    await cache.cargar();
    try {
      const resultado = await recolectarFuente(fuente, { cliente, cache, limite, reloj, log });
      if (resultado === 'limite') hayIncompletas = true;
      resumenFuentes[fuente.id] = { estado: resultado };
    } catch (error) {
      hayIncompletas = true;
      hayFallas = true;
      const estado = error instanceof BloqueoError ? 'bloqueada' : 'fallo';
      resumenFuentes[fuente.id] = { estado, motivo: error.message };
      log(`${fuente.id}: ${estado}. ${error.message} Se sigue con las demás.`);
    }
    Object.assign(resumenFuentes[fuente.id], { segmentos: cache.avance.segmentos, descartes: cache.avance.descartes });
    if (limite && cache.filas.length > limite) hayIncompletas = true;
    leidas.push(...(limite ? cache.filas.slice(0, limite) : cache.filas));
  }

  const { filas, excluidas, duplicadas, rechazos } = prepararFilas(leidas);
  const resumen = {
    fecha: dia,
    generado_en: horaCaracas(reloj()),
    archivo: null,
    filas: filas.length,
    por_farmacia: contarPor(filas, 'farmacia'),
    por_moneda: contarPor(filas, 'moneda'),
    excluidas,
    duplicadas,
    rechazos,
    fuentes: resumenFuentes,
    peticiones: cliente.peticiones,
    hay_fallas: hayFallas,
  };
  if (!filas.length) return resumen;

  await mkdir(dirSalida, { recursive: true });
  // Una lectura incompleta nunca lleva el nombre del CSV definitivo.
  const base = `precios-${dia}${hayIncompletas ? '-parcial' : ''}`;
  resumen.archivo = join(dirSalida, `${base}.csv`);
  await escribirAtomico(resumen.archivo, aCsv(filas));
  await escribirAtomico(join(dirSalida, `${base}.resumen.json`), JSON.stringify(resumen, null, 2));
  return resumen;
}
