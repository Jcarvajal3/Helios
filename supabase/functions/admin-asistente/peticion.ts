/**
 * Lo que manda el panel y cómo se convierte en `messages`.
 *
 * El servidor no guarda nada: el panel manda la conversación entera en cada
 * turno, solo con el texto final de cada respuesta. Las herramientas de turnos
 * anteriores no se reenvían; si hacen falta, el modelo vuelve a consultar.
 */

import { LIMITES_CONVERSACION } from './config.ts';
import type { MensajeNeutral } from './proveedor.ts';

export type Turno = { rol: 'persona' | 'asistente'; texto: string };

export type Peticion = { conversacion: Turno[]; rutaActual: string | null };

export type LecturaDePeticion = { ok: true; peticion: Peticion } | { ok: false; mensaje: string };

const RUTA = /^\/admin(\/[A-Za-z0-9_-]+)*\/?$/;

const esFila = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/** Valida el cuerpo. La ruta actual es un extra: si no encaja, se ignora. */
export function leerPeticion(cuerpo: unknown): LecturaDePeticion {
  if (!esFila(cuerpo) || !Array.isArray(cuerpo.conversacion)) {
    return { ok: false, mensaje: 'La petición necesita la conversación.' };
  }

  const turnos: Turno[] = [];
  for (const t of cuerpo.conversacion) {
    if (!esFila(t) || (t.rol !== 'persona' && t.rol !== 'asistente') || typeof t.texto !== 'string') {
      return { ok: false, mensaje: 'Cada turno necesita rol («persona» o «asistente») y texto.' };
    }
    const texto = t.texto.trim();
    if (texto === '') continue;
    if (t.rol === 'persona' && texto.length > LIMITES_CONVERSACION.caracteresPersona) {
      return {
        ok: false,
        mensaje: `La pregunta es demasiado larga: el máximo es ${LIMITES_CONVERSACION.caracteresPersona} caracteres.`,
      };
    }
    turnos.push({
      rol: t.rol,
      texto: t.rol === 'asistente' ? texto.slice(0, LIMITES_CONVERSACION.caracteresAsistente) : texto,
    });
  }

  // Los turnos más recientes; la conversación empieza siempre por una pregunta.
  const recientes = turnos.slice(-LIMITES_CONVERSACION.turnos);
  while (recientes.length > 0 && recientes[0].rol !== 'persona') recientes.shift();

  if (recientes.length === 0 || recientes[recientes.length - 1].rol !== 'persona') {
    return { ok: false, mensaje: 'La conversación tiene que terminar en una pregunta.' };
  }

  const ruta = typeof cuerpo.rutaActual === 'string' ? cuerpo.rutaActual.trim() : '';
  const rutaActual = ruta.length <= 200 && RUTA.test(ruta) ? ruta : null;

  return { ok: true, peticion: { conversacion: recientes, rutaActual } };
}

/** La última pregunta, que es la que va a la bitácora. */
export function ultimaPregunta(peticion: Peticion): string {
  return peticion.conversacion[peticion.conversacion.length - 1].texto;
}

/**
 * La conversación en el formato neutro del proveedor. Turnos seguidos del
 * mismo rol se juntan, y el contexto del turno va como primer bloque de la
 * última pregunta: después de todo lo que se cachea.
 */
export function aMensajes(peticion: Peticion, contexto: string): MensajeNeutral<never>[] {
  const juntos: Turno[] = [];
  for (const t of peticion.conversacion) {
    const anterior = juntos[juntos.length - 1];
    if (anterior && anterior.rol === t.rol) anterior.texto = `${anterior.texto}\n\n${t.texto}`;
    else juntos.push({ ...t });
  }
  return juntos.map((t, i): MensajeNeutral<never> => {
    if (i === juntos.length - 1) {
      return { rol: 'persona', bloques: [{ tipo: 'texto', texto: contexto }, { tipo: 'texto', texto: t.texto }] };
    }
    return { rol: t.rol, bloques: [{ tipo: 'texto', texto: t.texto }] };
  });
}
