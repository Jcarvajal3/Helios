/**
 * El manejador HTTP: quién pregunta, si puede, si queda cupo, y el flujo SSE.
 *
 * Todo lo de fuera (entorno, Supabase, el proveedor del modelo y el bucle)
 * llega por `Dependencias`, así que las pruebas lo recorren entero sin red. El
 * manejador no sabe qué modelo hay detrás.
 *
 * El orden importa:
 * 1. sesión y permiso, antes que nada: a quien no es del equipo no se le dice
 *    ni si el asistente está configurado;
 * 2. la petición, luego el proveedor: una petición mal hecha o un asistente sin
 *    configurar no gastan cupo;
 * 3. la línea `assistant.question` en la bitácora, que es también el límite
 *    por persona;
 * 4. el flujo. Al terminar se deja `assistant.answer` con los tokens.
 */

import type { Base } from './base.ts';
import type { OpcionesDeCorrida, ResumenDeCorrida } from './bucle.ts';
import type { Mapa } from './mapa.ts';
import { aMensajes, leerPeticion, ultimaPregunta } from './peticion.ts';
import { contextoDelTurno } from './prompt.ts';
import type { Proveedor } from './proveedor.ts';
import { type Canal, crearCanal } from './sse.ts';

export type Dependencias = {
  entorno(nombre: string): string | undefined;
  crearBase(authorization: string): Base;
  /** El proveedor configurado, o `null` si falta su clave. */
  crearProveedor(): Proveedor | null;
  correr(opciones: OpcionesDeCorrida): Promise<ResumenDeCorrida>;
  mapa: Mapa;
  system: string;
  ahora(): Date;
  crearCanal?(): Canal;
};

export const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

export const SIN_CLAVE = 'El asistente todavía no está configurado: falta la clave.';

function json(status: number, error: string, mensaje: string): Response {
  return new Response(JSON.stringify({ error, mensaje }), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

/** El id de la línea de la bitácora, que la RPC devuelve como bigint. */
function leerId(v: unknown): number | null {
  const n = typeof v === 'number' ? v : typeof v === 'string' ? Number(v) : NaN;
  return Number.isSafeInteger(n) ? n : null;
}

export function crearManejador(deps: Dependencias): (req: Request) => Promise<Response> {
  return async (req) => {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
    if (req.method !== 'POST') return json(405, 'metodo', 'Solo se admite POST.');

    const authorization = req.headers.get('Authorization') ?? '';
    if (!/^Bearer\s+\S+$/.test(authorization)) return json(401, 'sin_sesion', 'Hace falta iniciar sesión.');

    if (!deps.entorno('SUPABASE_URL') || !deps.entorno('SUPABASE_ANON_KEY')) {
      console.error('asistente: faltan SUPABASE_URL o SUPABASE_ANON_KEY');
      return json(500, 'no_configurado', 'La función no tiene la configuración de Supabase.');
    }

    const base = deps.crearBase(authorization);
    const usuario = await base.usuario();
    if (!usuario) return json(401, 'sin_sesion', 'La sesión no es válida o caducó. Vuelve a iniciar sesión.');

    const admin = await base.rpc('is_platform_admin');
    if (admin.error) {
      console.error('asistente: no se pudo comprobar el permiso', admin.error.message);
      return json(500, 'permiso', 'No se pudo comprobar el permiso.');
    }
    if (admin.data !== true) return json(403, 'sin_permiso', 'El asistente es solo para el equipo de Helios.');

    let cuerpo: unknown;
    try {
      cuerpo = await req.json();
    } catch {
      return json(400, 'peticion', 'La petición no es un JSON válido.');
    }
    const lectura = leerPeticion(cuerpo);
    if (!lectura.ok) return json(400, 'peticion', lectura.mensaje);
    const { peticion } = lectura;

    const proveedor = deps.crearProveedor();
    if (!proveedor) return json(503, 'sin_clave', SIN_CLAVE);

    const pregunta = ultimaPregunta(peticion);
    const linea = await base.rpc('admin_assistant_log', { p_question: pregunta });
    if (linea.error) {
      if (linea.error.code === '22023') return json(429, 'limite', linea.error.message);
      console.error('asistente: no se pudo dejar la línea en la bitácora', linea.error.message);
      return json(500, 'bitacora', 'No se pudo registrar la pregunta. Vuelve a intentarlo.');
    }
    const idDeLinea = leerId(linea.data);

    const canal = (deps.crearCanal ?? crearCanal)();
    const mensajes = aMensajes(peticion, contextoDelTurno(deps.ahora(), peticion.rutaActual));

    // Sin await: la respuesta sale ya y el bucle va escribiendo en el canal.
    void deps
      .correr({ proveedor, system: deps.system, mensajes, base, mapa: deps.mapa, canal })
      .then(async (resumen) => {
        if (idDeLinea === null) return;
        const { error } = await base.rpc('admin_assistant_log', {
          p_question: pregunta,
          p_tools: [...new Set(resumen.herramientas)],
          p_input_tokens: resumen.entrada,
          p_output_tokens: resumen.salida,
          p_model: resumen.modelo,
          p_log_id: idDeLinea,
        });
        if (error) console.error('asistente: no se pudieron anotar los tokens', error.message);
      })
      .catch((error) => {
        console.error('asistente: la corrida falló', error instanceof Error ? error.message : String(error));
        canal.enviar({ tipo: 'error', datos: { codigo: 'otro', mensaje: 'El asistente no pudo completar la consulta.', reintentar: true } });
      })
      .finally(() => canal.cerrar());

    return new Response(canal.stream, {
      headers: {
        ...CORS,
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-cache, no-transform',
        'X-Accel-Buffering': 'no',
      },
    });
  };
}
