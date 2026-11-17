// Adaptador genérico para tiendas VTEX: lee su API pública de catálogo, sin
// sesión y sin claves, una categoría tras otra y de 50 en 50 productos.

import { unirConcentracion } from '../filas.mjs';

const TAMANO_PAGINA = 50;
const MONEDAS = { USD: 'USD', VES: 'VES', VEF: 'VES' };

function primero(valor) {
  return Array.isArray(valor) ? String(valor[0] ?? '').trim() : '';
}

function presentacionDe(producto) {
  const contenido = [primero(producto.Capacidad), primero(producto.Unidad)].filter(Boolean).join(' ');
  return [primero(producto['Presentación']), contenido].filter(Boolean).join(' - ');
}

function disponibleDe(oferta) {
  if (oferta.IsAvailable === true) return 'si';
  if (oferta.IsAvailable === false) return 'no';
  return '';
}

// Una fila por cada SKU con precio. El precio es el del vendedor predeterminado:
// el vigente de venta (Price), no el de lista.
export function filasDeProducto(producto, { farmacia, fuente, base, moneda, visto_en }) {
  const filas = [];
  let sinPrecio = 0;
  for (const item of producto.items ?? []) {
    const vendedor = item.sellers?.find((s) => s.sellerDefault) ?? item.sellers?.[0];
    const oferta = vendedor?.commertialOffer;
    if (!(oferta?.Price > 0)) {
      sinPrecio += 1;
      continue;
    }
    filas.push({
      farmacia,
      nombre: unirConcentracion(item.nameComplete || producto.productName, primero(producto['Concentración'])),
      precio: oferta.Price,
      moneda,
      laboratorio: producto.brand ?? '',
      presentacion: presentacionDe(producto),
      sku: item.itemId ?? '',
      url: String(producto.link ?? '').startsWith('https://') ? producto.link : base,
      disponible: disponibleDe(oferta),
      visto_en,
      fuente,
    });
  }
  return { filas, sinPrecio };
}

export function crearFuenteVtex({ id, nombre, base, categorias, estado, motivo, documentacion }) {
  let moneda = null;

  return {
    id,
    nombre,
    estado,
    motivo,
    documentacion,

    async segmentos(cliente) {
      const respuesta = await cliente.obtener(`${base}/api/catalog_system/pub/saleschannel/1`);
      if (!respuesta.ok) throw new Error(`${id}: canal de venta respondió ${respuesta.status}.`);
      const canal = await respuesta.json();
      moneda = MONEDAS[canal.CurrencyCode];
      if (!moneda) throw new Error(`${id}: moneda no reconocida (${canal.CurrencyCode}).`);
      return categorias.map((categoria) => ({ clave: categoria.ruta, ...categoria }));
    },

    async leerPagina(cliente, segmento, desde, visto_en) {
      const hasta = desde + TAMANO_PAGINA - 1;
      const url =
        `${base}/api/catalog_system/pub/products/search` +
        `?fq=C:/${segmento.ruta}/&O=OrderByNameASC&_from=${desde}&_to=${hasta}`;
      const respuesta = await cliente.obtener(url);
      if (!respuesta.ok) throw new Error(`${id}: ${url} respondió ${respuesta.status}.`);
      const productos = await respuesta.json();
      const total = Number(respuesta.headers.get('resources')?.split('/')[1]);

      const filas = [];
      const descartes = { sin_precio: 0, no_medicamento: 0 };
      for (const producto of productos) {
        if (segmento.exigeClaseTerapeutica && !primero(producto['Clase terapéutica'])) {
          descartes.no_medicamento += 1;
          continue;
        }
        const leido = filasDeProducto(producto, { farmacia: nombre, fuente: id, base, moneda, visto_en });
        filas.push(...leido.filas);
        descartes.sin_precio += leido.sinPrecio;
      }

      const termino = productos.length === 0 || !Number.isFinite(total) || desde + productos.length >= total;
      return { filas, descartes, leidos: productos.length, total, siguiente: termino ? null : desde + TAMANO_PAGINA };
    },
  };
}
