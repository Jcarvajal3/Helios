/**
 * El mapa de pantallas del panel (`mapa.json`): lo que el asistente puede
 * enlazar y con qué nombres.
 *
 * Lo genera el panel desde su catálogo (`npm run asistente:mapa`, en
 * `features/admin/asistente/mapa.ts`), así que el asistente y el menú hablan
 * con los mismos rótulos. Aquí se valida al cargar (un mapa roto no debe tumbar
 * la función a mitad de una respuesta), se compacta para el system prompt y se
 * comprueba cada enlace que el modelo quiere enseñar.
 *
 * El mapa no dice qué acepta el `validateSearch` de cada ruta; dice qué
 * `search` usa el catálogo. Un enlace solo vale con esos parámetros y valores:
 * más estrecho que el panel, pero nunca lleva a una pantalla rota.
 */

import type { Enlace, ValorDeBusqueda } from './sse.ts';

export type Busqueda = Record<string, ValorDeBusqueda>;

export type PantallaDelMapa = {
  id: string;
  titulo: string;
  descripcion: string;
  ruta: string;
  search: Busqueda | null;
  searchConocidos: Busqueda[];
};

export type CifraDelMapa = {
  id: string;
  titulo: string;
  que: string;
  rpc: string;
  pantalla: string | null;
  ruta: string;
  search: Busqueda | null;
};

export type AccionDelMapa = {
  id: string;
  titulo: string;
  descripcion: string;
  ruta: string;
  search: Busqueda | null;
  soloSuperAdmin: boolean;
};

/** Una ficha: ruta con `$id`, que se sustituye por un uuid. */
export type FichaDelMapa = { ruta: string; titulo: string; que: string };

export type Mapa = {
  /** `true` mientras sea un mapa provisional escrito a mano. */
  regenerar: boolean;
  pantallas: PantallaDelMapa[];
  cifras: CifraDelMapa[];
  acciones: AccionDelMapa[];
  fichas: FichaDelMapa[];
};

type Fila = Record<string, unknown>;

const esFila = (v: unknown): v is Fila => typeof v === 'object' && v !== null && !Array.isArray(v);
const lista = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const texto = (v: unknown): string | null => (typeof v === 'string' && v.trim() !== '' ? v.trim() : null);
const rutaDelAdmin = (v: unknown): string | null => {
  const r = texto(v);
  return r && (r === '/admin' || r.startsWith('/admin/')) ? r : null;
};

const esValor = (v: unknown): v is ValorDeBusqueda =>
  typeof v === 'string' || typeof v === 'boolean' || (typeof v === 'number' && Number.isFinite(v));

/**
 * El generador del panel escribe los valores como texto; el router lee
 * `?marca=true` como booleano, así que «true» y «false» vuelven a serlo.
 */
const comoValor = (v: ValorDeBusqueda): ValorDeBusqueda => (v === 'true' ? true : v === 'false' ? false : v);

function leerBusqueda(v: unknown): Busqueda | null {
  if (!esFila(v)) return null;
  const salida: Busqueda = {};
  for (const [clave, valor] of Object.entries(v)) {
    if (esValor(valor)) salida[clave] = valor;
  }
  return Object.keys(salida).length > 0 ? salida : null;
}

/**
 * La forma que escribe `npm run asistente:mapa`: `{ clave: [valores] }`, los
 * valores que el catálogo usa con esa pantalla. Cada uno pasa a ser un
 * `search` conocido de un solo parámetro.
 */
function leerValoresAdmitidos(v: unknown): Busqueda[] {
  if (!esFila(v)) return [];
  return Object.entries(v).flatMap(([clave, valores]) =>
    lista(valores).filter(esValor).map((valor): Busqueda => ({ [clave]: comoValor(valor) }))
  );
}

/** Si `search` trae listas, es la forma generada; si trae valores sueltos, la escrita a mano. */
const traeListas = (v: unknown): boolean => esFila(v) && Object.values(v).some(Array.isArray);

/** Lee el JSON del mapa. Descarta las entradas incompletas en vez de fallar. */
export function leerMapa(crudo: unknown): Mapa {
  const m = esFila(crudo) ? crudo : {};
  const pantallas = lista(m.pantallas).flatMap((p): PantallaDelMapa[] => {
    if (!esFila(p)) return [];
    const id = texto(p.id), titulo = texto(p.titulo), ruta = rutaDelAdmin(p.ruta);
    if (!id || !titulo || !ruta) return [];
    const generada = traeListas(p.search);
    return [{
      id,
      titulo,
      descripcion: texto(p.descripcion) ?? '',
      ruta,
      search: generada ? null : leerBusqueda(p.search),
      searchConocidos: [
        ...(generada ? leerValoresAdmitidos(p.search) : []),
        ...lista(p.searchConocidos).flatMap((s) => {
          const b = leerBusqueda(s);
          return b ? [b] : [];
        }),
      ],
    }];
  });
  // Una cifra del mapa generado no trae ruta: la hereda de su pantalla.
  const rutaDePantalla = new Map(pantallas.map((p) => [p.id, p.ruta]));
  const cifras = lista(m.cifras).flatMap((c): CifraDelMapa[] => {
    if (!esFila(c)) return [];
    const id = texto(c.id), titulo = texto(c.titulo), rpc = texto(c.rpc), pantalla = texto(c.pantalla);
    const ruta = rutaDelAdmin(c.ruta) ?? (pantalla ? rutaDePantalla.get(pantalla) ?? null : null);
    if (!id || !titulo || !rpc || !ruta) return [];
    return [{ id, titulo, que: texto(c.que) ?? '', rpc, pantalla, ruta, search: leerBusqueda(c.search) }];
  });
  const acciones = lista(m.acciones).flatMap((a): AccionDelMapa[] => {
    if (!esFila(a)) return [];
    const id = texto(a.id), titulo = texto(a.titulo), ruta = rutaDelAdmin(a.ruta);
    if (!id || !titulo || !ruta) return [];
    return [{
      id,
      titulo,
      descripcion: texto(a.descripcion) ?? '',
      ruta,
      search: leerBusqueda(a.search),
      soloSuperAdmin: a.soloSuperAdmin === true,
    }];
  });
  const fichas = lista(m.fichas).flatMap((f): FichaDelMapa[] => {
    if (!esFila(f)) return [];
    const ruta = rutaDelAdmin(f.ruta);
    if (!ruta || !ruta.endsWith('/$id')) return [];
    const titulo = texto(f.titulo), que = texto(f.que);
    return [{ ruta, titulo: titulo ?? que ?? ruta, que: que ?? titulo ?? '' }];
  });
  return { regenerar: m.regenerar === true, pantallas, cifras, acciones, fichas };
}

/** «/admin/ajustes?tab=tasa»: la ruta con su search, para leerla de un vistazo. */
function rutaConBusqueda(ruta: string, search: Busqueda | null): string {
  if (!search) return ruta;
  return `${ruta}?${Object.entries(search).map(([k, v]) => `${k}=${String(v)}`).join('&')}`;
}

/** La primera frase, y como mucho `max` caracteres. */
function unaLinea(t: string, max = 160): string {
  const frase = t.split(/(?<=\.)\s/)[0] ?? t;
  return frase.length > max ? `${frase.slice(0, max - 1)}…` : frase;
}

/** Los valores de cada parámetro, sin repetir y en orden de aparición. */
function valoresPorClave(todas: ReadonlyArray<Busqueda | null>): Map<string, ValorDeBusqueda[]> {
  const salida = new Map<string, ValorDeBusqueda[]>();
  for (const b of todas) {
    for (const [clave, valor] of Object.entries(b ?? {})) {
      const valores = salida.get(clave) ?? [];
      if (!valores.some((v) => String(v) === String(valor))) valores.push(valor);
      salida.set(clave, valores);
    }
  }
  return salida;
}

/** Cada parámetro de la URL que se usa con esa ruta, con sus valores. */
export function busquedasDeLaRuta(mapa: Mapa, ruta: string): Map<string, ValorDeBusqueda[]> {
  return valoresPorClave([
    ...mapa.pantallas.filter((p) => p.ruta === ruta).flatMap((p) => [p.search, ...p.searchConocidos]),
    ...mapa.cifras.filter((c) => c.ruta === ruta).map((c) => c.search),
    ...mapa.acciones.filter((a) => a.ruta === ruta).map((a) => a.search),
  ]);
}

/**
 * La versión compacta que va en el system prompt: una línea por pantalla,
 * ficha, acción y cifra. Es determinista (mismo mapa, mismos bytes) para no
 * romper la caché del prefijo.
 */
export function compactarMapa(mapa: Mapa, consultables?: ReadonlySet<string>): string {
  // Varias pantallas con la misma ruta son pestañas de una: sus parámetros se
  // listan una sola vez, en la primera.
  const listadas = new Set<string>();
  const pantallas = mapa.pantallas.map((p) => {
    const primera = !listadas.has(p.ruta);
    listadas.add(p.ruta);
    const parametros = primera
      ? [...valoresPorClave(p.searchConocidos)].map(([k, vs]) => `${k}=${vs.map(String).join('|')}`)
      : [];
    const extra = parametros.length > 0 ? ` (search: ${parametros.join('; ')})` : '';
    return `- ${p.titulo} · ${rutaConBusqueda(p.ruta, p.search)}${extra}: ${unaLinea(p.descripcion)}`;
  });
  const fichas = mapa.fichas.map((f) =>
    `- ${f.titulo} · ${f.ruta} ($id es el uuid)${f.que !== f.titulo ? `: ${unaLinea(f.que)}` : ''}`
  );
  const acciones = mapa.acciones.map((a) =>
    `- ${a.titulo} · ${rutaConBusqueda(a.ruta, a.search)}${a.soloSuperAdmin ? ' (solo super admin)' : ''}`
  );
  // Con `consultables`, la RPC solo se nombra si es una herramienta: nombrar
  // una que no lo es invita al modelo a llamarla.
  const cifras = mapa.cifras.map((c) => {
    const rpc = !consultables || consultables.has(c.rpc) ? ` (${c.rpc})` : '';
    return `- ${c.titulo}${rpc} · ${rutaConBusqueda(c.ruta, c.search)}: ${unaLinea(c.que)}`;
  });
  const seccion = (titulo: string, lineas: string[]) => [`## ${titulo}`, ...(lineas.length > 0 ? lineas : ['- (ninguna)']), ''];
  return [
    ...seccion('Pantallas', pantallas),
    ...seccion('Fichas', fichas),
    ...seccion('Dónde se hace cada cosa (para enlazar; tú no lo haces)', acciones),
    ...seccion('Cifras y dónde se ven', cifras),
  ].join('\n').trimEnd();
}

const UUID = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';

function escaparRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

const fichaDeLaRuta = (mapa: Mapa, ruta: string): FichaDelMapa | undefined =>
  mapa.fichas.find((f) => new RegExp('^' + escaparRegex(f.ruta).replace('\\$id', UUID) + '$').test(ruta));

function esRutaConocida(mapa: Mapa, ruta: string): 'pantalla' | 'ficha' | null {
  const directa = [...mapa.pantallas, ...mapa.cifras, ...mapa.acciones].some((e) => e.ruta === ruta);
  if (directa) return 'pantalla';
  return fichaDeLaRuta(mapa, ruta) ? 'ficha' : null;
}

/**
 * El título con el que el mapa nombra una ruta: el de su pantalla (la primera
 * con esa ruta) o el de su ficha. `null` si la ruta no está en el mapa.
 */
export function tituloDeLaRuta(mapa: Mapa, ruta: string): string | null {
  const pantalla = mapa.pantallas.find((p) => p.ruta === ruta);
  if (pantalla) return pantalla.titulo;
  const otra = [...mapa.cifras, ...mapa.acciones].find((e) => e.ruta === ruta);
  if (otra) return otra.titulo;
  return fichaDeLaRuta(mapa, ruta)?.titulo ?? null;
}

export type ResultadoDeEnlace = { ok: true; enlace: Enlace } | { ok: false; error: string };

/**
 * Comprueba un enlace contra el mapa: la ruta tiene que ser una pantalla o una
 * ficha con un uuid, y cada parámetro de `search`, uno que el catálogo usa con
 * esa ruta y con uno de sus valores. El error va redactado para que el modelo
 * lo corrija.
 */
export function validarEnlace(
  mapa: Mapa,
  entrada: { titulo: string; ruta: string; search?: Record<string, string> },
): ResultadoDeEnlace {
  const ruta = entrada.ruta.trim();
  const titulo = entrada.titulo.trim();
  if (titulo === '') return { ok: false, error: 'El enlace necesita un título.' };

  const clase = esRutaConocida(mapa, ruta);
  if (!clase) {
    return {
      ok: false,
      error: `La ruta «${ruta}» no está en el mapa del panel. Usa una de las rutas de la lista de pantallas o fichas.`,
    };
  }

  const admitidos = clase === 'pantalla' ? busquedasDeLaRuta(mapa, ruta) : new Map<string, ValorDeBusqueda[]>();
  const search: Record<string, ValorDeBusqueda> = {};
  for (const [clave, valor] of Object.entries(entrada.search ?? {})) {
    const valores = admitidos.get(clave);
    if (!valores) {
      const lista = [...admitidos.keys()];
      return {
        ok: false,
        error: `La pantalla «${ruta}» no admite el parámetro «${clave}»` +
          (lista.length > 0 ? `; admite: ${lista.join(', ')}.` : '; no admite ninguno.'),
      };
    }
    // Se manda el valor del mapa, con su tipo (un `true` sigue siendo booleano).
    const conocido = valores.find((v) => String(v) === valor);
    if (conocido === undefined) {
      return {
        ok: false,
        error: `«${valor}» no es un valor válido de «${clave}» en «${ruta}»; los válidos son: ${valores.map(String).join(', ')}.`,
      };
    }
    search[clave] = conocido;
  }

  const enlace: Enlace = { titulo, ruta };
  if (Object.keys(search).length > 0) enlace.search = search;
  return { ok: true, enlace };
}
