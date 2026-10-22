/**
 * Los enlaces que el panel recibe solos al terminar una respuesta.
 *
 * Cada herramienta de datos sabe en qué pantalla se ve lo que lee. Pedirle al
 * modelo que lo enlace con `mostrar_enlace` falla a menudo (se le olvida, sobre
 * todo al modelo ligero) y cuesta una vuelta más; así que el bucle enlaza él
 * mismo las pantallas de las herramientas usadas. El modelo sigue pudiendo
 * enlazar otra pantalla o un filtro concreto, y esas no se repiten.
 */

import type { PantallaDeHerramienta } from './herramientas/tipos.ts';
import { busquedasDeLaRuta, type Mapa, tituloDeLaRuta, validarEnlace } from './mapa.ts';
import type { Enlace } from './sse.ts';

export const MAX_ENLACES_AUTOMATICOS = 3;

/**
 * Los parámetros de la pantalla que el mapa admite para esa ruta. Uno que no
 * admite (el mapa solo lista lo que el catálogo enlaza, y puede ir por detrás
 * del panel) se cae solo, sin costar el enlace entero.
 */
function soloLosAdmitidos(mapa: Mapa, pantalla: PantallaDeHerramienta): Record<string, string> | undefined {
  const admitidos = busquedasDeLaRuta(mapa, pantalla.ruta);
  const quedan = Object.entries(pantalla.search ?? {}).filter(([clave, valor]) =>
    (admitidos.get(clave) ?? []).some((v) => String(v) === valor)
  );
  return quedan.length > 0 ? Object.fromEntries(quedan) : undefined;
}

/**
 * El título de la pestaña concreta. Varias pantallas del mapa comparten ruta y
 * se distinguen por la pestaña (`vista`) y la sub-pestaña (`sub`); el mapa no
 * trae el search de cada una, pero sí ids que las siguen: «promesas»,
 * «metricas-semana», «metricas-semana-rendimiento». Se busca de la más
 * concreta a la más general; sin ninguna, el de la ruta.
 */
export function tituloDeLaPestana(mapa: Mapa, pantalla: PantallaDeHerramienta): string | null {
  const { vista, sub } = pantalla.search ?? {};
  const deLaRuta = mapa.pantallas.filter((p) => p.ruta === pantalla.ruta);
  const candidatos = [
    vista && sub ? `-${vista}-${sub}` : null,
    vista ? `-${vista}` : null,
  ].filter((c): c is string => c !== null);
  for (const fin of candidatos) {
    const hallada = deLaRuta.find((p) => p.id.endsWith(fin));
    if (hallada) return hallada.titulo;
  }
  const igual = vista ? deLaRuta.find((p) => p.id === vista) : undefined;
  return igual?.titulo ?? tituloDeLaRuta(mapa, pantalla.ruta);
}

/**
 * La pantalla como enlace validado contra el mapa, o `null` si el mapa no la
 * tiene. El título sale de los parámetros que quedan: si la pestaña pedida ya
 * no existe, el enlace va a la pantalla y se llama como ella.
 */
function comoEnlace(mapa: Mapa, pantalla: PantallaDeHerramienta): Enlace | null {
  const search = soloLosAdmitidos(mapa, pantalla);
  const titulo = tituloDeLaPestana(mapa, { ruta: pantalla.ruta, search });
  if (!titulo) return null;
  const r = validarEnlace(mapa, { titulo, ruta: pantalla.ruta, search });
  return r.ok ? r.enlace : null;
}

/** Una pestaña: la ruta con sus parámetros, en orden. */
const pestanaDe = (e: { ruta: string; search?: Record<string, unknown> }): string =>
  `${e.ruta}?${Object.entries(e.search ?? {}).map(([k, v]) => `${k}=${String(v)}`).sort().join('&')}`;

/**
 * Los enlaces de las pantallas usadas, en el orden en que se leyeron: una vez
 * cada pestaña, sin las que el modelo ya enlazó y como mucho `max`. Se cuenta
 * por pestaña y no por ruta porque Métricas junta en una sola ruta la semana,
 * los cobros, la caja o la gente.
 */
export function enlacesAutomaticos(
  mapa: Mapa,
  pantallas: ReadonlyArray<PantallaDeHerramienta>,
  yaEnlazados: ReadonlyArray<Enlace>,
  max = MAX_ENLACES_AUTOMATICOS,
): Enlace[] {
  const vistas = new Set(yaEnlazados.map(pestanaDe));
  const salida: Enlace[] = [];
  for (const pantalla of pantallas) {
    if (salida.length >= max) break;
    const enlace = comoEnlace(mapa, pantalla);
    if (!enlace || vistas.has(pestanaDe(enlace))) continue;
    vistas.add(pestanaDe(enlace));
    salida.push(enlace);
  }
  return salida;
}
