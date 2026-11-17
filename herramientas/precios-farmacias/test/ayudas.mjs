// Todas las pruebas corren sin red: si algo intenta salir a internet, falla.
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

globalThis.fetch = () => {
  throw new Error('Las pruebas no pueden usar la red.');
};

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), 'fixtures');

export const leerFixture = (nombre) => readFile(join(FIXTURES, nombre), 'utf8');

export function filaBase(cambios = {}) {
  return {
    farmacia: 'Farmacia Permitida',
    nombre: 'PRUEBAMOL TAB 500MG X20',
    precio: 1.22,
    moneda: 'USD',
    laboratorio: 'LAB',
    presentacion: 'Caja',
    sku: '9001',
    url: 'https://farmacia.test/9001/p',
    disponible: 'si',
    visto_en: '2026-11-06T10:00:00-04:00',
    fuente: 'prueba',
    ...cambios,
  };
}

// Reloj falso: esperar() avanza el tiempo en lugar de dormir.
export function relojFalso() {
  const reloj = { ms: 0, esperas: [] };
  reloj.ahora = () => reloj.ms;
  reloj.esperar = async (ms) => {
    reloj.esperas.push(ms);
    reloj.ms += ms;
  };
  return reloj;
}

// fetch falso: responde según la función dada y anota cada llamada.
export function fetchFalso(responder) {
  const falso = async (url, opciones) => {
    falso.llamadas.push({ url: String(url), opciones });
    if (String(url).endsWith('/robots.txt')) {
      return (await responder(String(url))) ?? new Response('User-agent: *\nDisallow: /checkout/\n');
    }
    const respuesta = await responder(String(url));
    if (!respuesta) throw new Error(`URL inesperada en la prueba: ${url}`);
    return respuesta;
  };
  falso.llamadas = [];
  return falso;
}
