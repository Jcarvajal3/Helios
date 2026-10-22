/**
 * El filtro del texto que llega del modelo antes de ir al panel.
 *
 * El modelo ligero, a veces, escribe una llamada a herramienta como texto en
 * vez de hacerla: «{mostrar_enlace(ruta="/admin/cobranza"…» o
 * «narod:mostrar_e…», pegado al final de una respuesta buena. Los nombres de
 * las herramientas de presentación nunca van en una respuesta, así que en
 * cuanto aparece «mostrar_» se corta: desde el principio de esa palabra hasta el
 * final de la vuelta no sale nada más.
 *
 * El texto sigue saliendo en streaming: solo se retiene una palabra final que
 * podría ser el principio de «mostrar_» (hasta el trozo siguiente o hasta que
 * acaba la vuelta).
 */

const MARCA = 'mostrar_';

/** Desde dónde hay que retener: el principio de la última palabra si podría acabar en la marca. */
function inicioSospechoso(texto: string): number {
  const inicio = texto.search(/\S*$/);
  const palabra = texto.slice(inicio);
  for (let i = palabra.indexOf('m'); i >= 0; i = palabra.indexOf('m', i + 1)) {
    if (MARCA.startsWith(palabra.slice(i))) return inicio;
  }
  return texto.length;
}

export type FiltroDeTexto = {
  /** Lo que ya se puede enviar tras este trozo (puede ser ''). */
  empujar(delta: string): string;
  /** Lo retenido, al acabar la vuelta. */
  vaciar(): string;
  /** Si se cortó una llamada escrita como texto. */
  readonly cortado: boolean;
};

export function crearFiltroDeTexto(): FiltroDeTexto {
  let pendiente = '';
  let cortado = false;
  return {
    empujar(delta) {
      if (cortado) return '';
      pendiente += delta;
      const marca = pendiente.indexOf(MARCA);
      if (marca >= 0) {
        cortado = true;
        const antes = pendiente.slice(0, marca);
        pendiente = '';
        return antes.slice(0, antes.search(/\S*$/)).trimEnd();
      }
      const corte = inicioSospechoso(pendiente);
      const listo = pendiente.slice(0, corte);
      pendiente = pendiente.slice(corte);
      return listo;
    },
    vaciar() {
      const resto = cortado ? '' : pendiente;
      pendiente = '';
      return resto;
    },
    get cortado() {
      return cortado;
    },
  };
}
