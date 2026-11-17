// keiti.io: la API exige clave con saldo (términos §5 y /documentacion). Solo
// está escrita la traducción de la respuesta de /v1/buscar, según el ejemplo de
// su documentación. Falta recorrer el catálogo, y eso se escribe contra
// respuestas reales cuando Javier decida si compra el acceso (FUENTES.md).

// Regiones que cubren Caracas. «Centro» queda fuera mientras no se compruebe
// con datos reales si incluye a Caracas.
const REGIONES_DE_CARACAS = ['nacional', 'caracas', 'distrito capital', 'gran caracas'];

export function filasDeBuscar(respuesta, { visto_en }) {
  const filas = [];
  for (const producto of respuesta.productos ?? []) {
    for (const oferta of producto.ofertas ?? []) {
      const region = String(oferta.region_geografica ?? '').toLowerCase();
      if (!REGIONES_DE_CARACAS.includes(region)) continue;
      // Si trae las dos monedas, la de bolívares: el dólar lo calcula keiti.
      const enBolivares = oferta.precio_bs > 0;
      filas.push({
        farmacia: oferta.cadena,
        nombre: producto.titulo_visual || producto.producto,
        precio: enBolivares ? oferta.precio_bs : oferta.precio_usd,
        moneda: enBolivares ? 'VES' : 'USD',
        laboratorio: producto.marca ?? '',
        presentacion: [producto.presentacion, producto.cantidad && `x${producto.cantidad}`].filter(Boolean).join(' '),
        sku: producto.ean ?? producto.id_producto ?? '',
        url: oferta.url ?? 'https://keiti.io/',
        disponible: oferta.disponible === true ? 'si' : oferta.disponible === false ? 'no' : '',
        visto_en,
        fuente: 'keiti',
      });
    }
  }
  return filas;
}
