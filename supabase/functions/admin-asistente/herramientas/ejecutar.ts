/**
 * Ejecuta una herramienta y deja su resultado listo para el modelo.
 *
 * Una herramienta de datos llama a su RPC con el cliente de quien pregunta,
 * recorta lo que confunde, deja los importes a céntimos, tapa los datos
 * personales y serializa con un
 * tope de tamaño. Un fallo nunca revienta la respuesta: vuelve al modelo como
 * `is_error` con el mensaje de la base (ya en español), y el modelo lo dice.
 */

import type { Base } from '../base.ts';
import { MAX_RESULTADO } from '../config.ts';
import { enmascarar } from '../enmascarar.ts';
import type { Mapa } from '../mapa.ts';
import { redondearDinero } from '../redondear.ts';
import type { Evento } from '../sse.ts';
import { ErrorDeEntrada, esFila } from './esquema.ts';
import type { Entrada, Herramienta, HerramientaDeDatos, PantallaDeHerramienta } from './tipos.ts';

export type ResultadoDeHerramienta = {
  contenido: string;
  esError: boolean;
  /** Lo que el panel tiene que dibujar ya (solo las de presentación). */
  evento?: Evento;
  /** La tabla o el gráfico de lo leído (solo las de datos): se pinta al final de la respuesta. */
  vista?: Evento;
  /** Dónde se ve lo leído (solo las de datos, y solo si leyeron algo). */
  pantalla?: PantallaDeHerramienta;
};

/** La pantalla de una herramienta de datos para esa entrada y esos datos. */
export function pantallaDe(herramienta: HerramientaDeDatos, entrada: Entrada, datos: unknown): PantallaDeHerramienta | null {
  return typeof herramienta.pantalla === 'function' ? herramienta.pantalla(entrada, datos) : herramienta.pantalla;
}

function cortarListas(valor: unknown, n: number): unknown {
  if (Array.isArray(valor)) return valor.slice(0, n).map((v) => cortarListas(v, n));
  if (!esFila(valor)) return valor;
  return Object.fromEntries(Object.entries(valor).map(([k, v]) => [k, cortarListas(v, n)]));
}

function hayListaMasLarga(valor: unknown, n: number): boolean {
  if (Array.isArray(valor)) return valor.length > n || valor.some((v) => hayListaMasLarga(v, n));
  return esFila(valor) && Object.values(valor).some((v) => hayListaMasLarga(v, n));
}

/**
 * JSON de como mucho `max` caracteres. Si no cabe, corta las listas (a 200,
 * 100, 50… elementos) y lo avisa en `_aviso` para que el modelo no presente
 * una lista cortada como si estuviera entera.
 */
export function serializarAcotado(valor: unknown, max = MAX_RESULTADO): string {
  const entero = JSON.stringify(valor) ?? 'null';
  if (entero.length <= max) return entero;
  for (const n of [200, 100, 50, 25, 10, 5]) {
    if (!hayListaMasLarga(valor, n)) continue;
    const aviso = `Resultado recortado: cada lista trae solo sus primeros ${n} elementos. Dilo si afecta a la respuesta, o acota la consulta.`;
    const cortado = cortarListas(valor, n);
    const envuelto = esFila(cortado) ? { _aviso: aviso, ...cortado } : { _aviso: aviso, filas: cortado };
    const texto = JSON.stringify(envuelto);
    if (texto.length <= max) return texto;
  }
  return JSON.stringify({
    _aviso: 'Resultado demasiado grande y cortado a mitad: no presentes estas cifras como completas; acota la consulta.',
    parcial: entero.slice(0, max - 300),
  });
}

export async function ejecutarHerramienta(
  herramienta: Herramienta,
  entrada: Entrada,
  contexto: { base: Base; mapa: Mapa },
): Promise<ResultadoDeHerramienta> {
  if (herramienta.clase === 'presentacion') {
    const r = herramienta.presentar(entrada, contexto.mapa);
    if (!r.ok) return { contenido: r.error, esError: true };
    return { contenido: r.nota ? `ok. ${r.nota}` : 'ok', esError: false, evento: r.evento };
  }

  let args: Record<string, unknown>;
  try {
    args = herramienta.argumentos(entrada);
  } catch (error) {
    if (error instanceof ErrorDeEntrada) return { contenido: error.message, esError: true };
    throw error;
  }

  const { data, error } = await contexto.base.rpc(herramienta.rpc, args);
  if (error) {
    return { contenido: `La consulta ${herramienta.rpc} falló: ${error.message}`, esError: true };
  }
  if (data === null || data === undefined) {
    return { contenido: 'Sin resultado: la función devolvió null (no existe, o es una cuenta de prueba).', esError: false };
  }

  const recortado = herramienta.recortar ? herramienta.recortar(data) : data;
  const seguro = enmascarar(redondearDinero(recortado), herramienta.datosPersonales);
  const pantalla = pantallaDe(herramienta, entrada, data);
  const vista = herramienta.visualizar?.(entrada, seguro) ?? null;
  const contenido = serializarAcotado(seguro);
  const resultado: ResultadoDeHerramienta = { contenido: vista?.nota ? `${vista.nota}\n${contenido}` : contenido, esError: false };
  if (pantalla) resultado.pantalla = pantalla;
  if (vista?.evento) resultado.vista = vista.evento;
  return resultado;
}
