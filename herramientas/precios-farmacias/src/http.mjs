// Cliente HTTP de ritmo bajo. Una petición a la vez, con pausa por dominio,
// reintentos con espera y respeto a robots.txt. Ante un bloqueo no insiste ni
// busca otra vía: lanza BloqueoError y el recolector deja esa fuente.

import { rutaPermitida } from './robots.mjs';

export const USER_AGENT = 'precios-farmacias/0.1 (herramienta de investigacion de precios de medicamentos)';

const ESTADOS_DE_BLOQUEO = new Set([401, 402, 403, 407, 451]);
const CABECERAS_DE_DESAFIO = ['cf-mitigated', 'x-vercel-mitigated'];
const ESPERA_MAXIMA_429_MS = 5 * 60 * 1000;

export class BloqueoError extends Error {
  constructor(mensaje) {
    super(mensaje);
    this.name = 'BloqueoError';
  }
}

export class ClienteHttp {
  constructor({
    pausaMs = 2000,
    reintentos = 3,
    esperaBaseMs = 5000,
    fetch: hacerFetch = globalThis.fetch,
    esperar = (ms) => new Promise((resolver) => setTimeout(resolver, ms)),
    ahora = () => Date.now(),
  } = {}) {
    Object.assign(this, { pausaMs, reintentos, esperaBaseMs, hacerFetch, esperar, ahora });
    this.ultimaPeticion = new Map();
    this.robots = new Map();
    this.peticiones = 0;
  }

  async #respetarPausa(host) {
    const ultima = this.ultimaPeticion.get(host);
    if (ultima !== undefined) {
      const falta = ultima + this.pausaMs - this.ahora();
      if (falta > 0) await this.esperar(falta);
    }
    this.ultimaPeticion.set(host, this.ahora());
  }

  async #pedir(url, opciones) {
    const { host } = new URL(url);
    let intento = 0;
    let esperoPor429 = false;
    for (;;) {
      await this.#respetarPausa(host);
      this.peticiones += 1;
      let respuesta;
      try {
        respuesta = await this.hacerFetch(url, {
          headers: { 'User-Agent': USER_AGENT, Accept: opciones.accept },
          signal: AbortSignal.timeout(30_000),
        });
      } catch (error) {
        if (intento >= this.reintentos) throw new Error(`Sin respuesta de ${url}: ${error.message}`);
        await this.esperar(this.esperaBaseMs * 2 ** intento);
        intento += 1;
        continue;
      }

      const desafio = CABECERAS_DE_DESAFIO.find((cabecera) => respuesta.headers.get(cabecera));
      if (desafio) throw new BloqueoError(`${host} respondió con un desafío de seguridad (${desafio}).`);
      if (ESTADOS_DE_BLOQUEO.has(respuesta.status)) {
        throw new BloqueoError(`${host} respondió ${respuesta.status} en ${url}.`);
      }
      if (respuesta.status === 429) {
        if (esperoPor429) throw new BloqueoError(`${host} sigue respondiendo 429 tras esperar.`);
        esperoPor429 = true;
        const pedida = Number(respuesta.headers.get('retry-after')) * 1000 || 60_000;
        await this.esperar(Math.min(pedida, ESPERA_MAXIMA_429_MS));
        continue;
      }
      if (respuesta.status >= 500) {
        if (intento >= this.reintentos) throw new Error(`${url} sigue respondiendo ${respuesta.status}.`);
        await this.esperar(this.esperaBaseMs * 2 ** intento);
        intento += 1;
        continue;
      }
      return respuesta;
    }
  }

  async #revisarRobots(url) {
    const { origin, host, pathname, search } = new URL(url);
    if (!this.robots.has(host)) {
      const respuesta = await this.#pedir(`${origin}/robots.txt`, { accept: 'text/plain' });
      this.robots.set(host, respuesta.status === 200 ? await respuesta.text() : '');
    }
    if (!rutaPermitida(this.robots.get(host), USER_AGENT, pathname + search)) {
      throw new BloqueoError(`robots.txt de ${host} no permite ${pathname}.`);
    }
  }

  async obtener(url, { accept = 'application/json' } = {}) {
    await this.#revisarRobots(url);
    return this.#pedir(url, { accept });
  }
}
