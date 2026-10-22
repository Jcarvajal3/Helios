/**
 * admin-asistente: el asistente de datos del super admin, de solo lectura.
 *
 * El equipo pregunta en español y el modelo contesta con cifras que lee en ese
 * momento de la base, con enlaces a la pantalla donde se ve cada cosa. Cada
 * herramienta es una RPC de lectura llamada con el JWT de quien pregunta: la
 * guarda `is_platform_admin()` sigue mandando. Nunca `service_role`.
 *
 * Aquí solo se conecta todo. Contrato con el panel: `sse.ts` (eventos) y
 * `peticion.ts` (cuerpo). Frontera con el modelo: `proveedor.ts`. Contesta
 * Anthropic con la misma clave que el lector de comprobantes
 * (`ANTHROPIC_API_KEY`); el modelo lo decide `configuracion.ts`.
 *
 * Despliegue (sin Docker; con JWT, porque el panel la llama con la sesión de
 * quien pregunta):
 *   supabase functions deploy admin-asistente --use-api \
 *     --project-ref ahyfbnfsbyzdoyjzjvfb
 */

import { createClient } from 'jsr:@supabase/supabase-js@2';

import { crearProveedorAnthropic } from './anthropic/proveedor.ts';
import type { Base } from './base.ts';
import { correrAsistente } from './bucle.ts';
import { elegirProveedor } from './configuracion.ts';
import { crearManejador } from './manejador.ts';
import { leerMapa } from './mapa.ts';
import mapaCrudo from './mapa.json' with { type: 'json' };
import { construirSystem } from './prompt.ts';
import type { Proveedor } from './proveedor.ts';

const mapa = leerMapa(mapaCrudo);
const system = construirSystem(mapa);

function crearBase(authorization: string): Base {
  const cliente = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_ANON_KEY') ?? '', {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return {
    async usuario() {
      const { data, error } = await cliente.auth.getUser();
      return error || !data.user ? null : data.user.id;
    },
    async rpc(nombre, args) {
      const { data, error } = await cliente.rpc(nombre, args);
      return { data, error: error ? { message: error.message, code: error.code } : null };
    },
  };
}

function crearProveedor(): Proveedor | null {
  const eleccion = elegirProveedor((nombre) => Deno.env.get(nombre));
  switch (eleccion.proveedor) {
    case 'anthropic':
      return crearProveedorAnthropic({ apiKey: eleccion.apiKey, modelo: eleccion.modelo });
    case null:
      console.warn(`asistente: falta ${eleccion.falta}`);
      return null;
  }
}

Deno.serve(
  crearManejador({
    entorno: (nombre) => Deno.env.get(nombre),
    crearBase,
    crearProveedor,
    correr: correrAsistente,
    mapa,
    system,
    ahora: () => new Date(),
  }),
);
