/**
 * Las herramientas de presentación: no leen la base. El panel dibuja el enlace,
 * el gráfico o la tabla con su propio kit, y el modelo recibe `ok` o el motivo
 * del rechazo para corregirse.
 */

import { type Mapa, validarEnlace } from '../mapa.ts';
import type { Grafico, PuntoDeGrafico, Tabla, UnidadDeColumna } from '../sse.ts';
import { esFila, objeto, opcion, textoLibre } from './esquema.ts';
import { celdaLegible, diaLegible, esIdentificador, esUuid } from './legible.ts';
import type { HerramientaDePresentacion, ResultadoDePresentacion } from './tipos.ts';

export const MAX_FILAS_TABLA = 50;
export const MAX_PUNTOS_GRAFICO = 60;

const TIPOS_DE_GRAFICO = ['barras', 'lineas', 'reparto'] as const;
/**
 * Las que puede pedir el modelo, con `usd` para el dinero. El protocolo con el
 * panel (heredado de Ronda) la llama `eur` y el panel la pinta en dólares.
 */
const UNIDADES_DE_GRAFICO = ['usd', 'numero', 'pct'] as const;
const UNIDADES_DE_COLUMNA = ['usd', 'numero', 'pct', 'texto', 'fecha'] as const;

const alProtocolo = <T extends string>(u: T | undefined): Exclude<T, 'usd'> | 'eur' | undefined =>
  u === 'usd' ? 'eur' : (u as Exclude<T, 'usd'> | undefined);

const texto = (v: unknown, max = 120): string => (typeof v === 'string' ? v.trim().slice(0, max) : '');
const numero = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const lista = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const de = <T extends string>(v: unknown, valores: readonly T[]): T | undefined => valores.find((x) => x === v);

function presentarEnlace(entrada: Record<string, unknown>, mapa: Mapa): ResultadoDePresentacion {
  const pares = lista(entrada.search).flatMap((p) => {
    if (!esFila(p)) return [];
    const clave = texto(p.clave, 40), valor = texto(p.valor, 200);
    return clave ? [[clave, valor] as const] : [];
  });
  const r = validarEnlace(mapa, {
    titulo: texto(entrada.titulo),
    ruta: texto(entrada.ruta, 200),
    search: pares.length > 0 ? Object.fromEntries(pares) : undefined,
  });
  return r.ok ? { ok: true, evento: { tipo: 'enlace', datos: r.enlace } } : r;
}

function presentarGrafico(entrada: Record<string, unknown>): ResultadoDePresentacion {
  const tipo = de(entrada.tipo, TIPOS_DE_GRAFICO);
  const unidad = alProtocolo(de(entrada.unidad, UNIDADES_DE_GRAFICO));
  const titulo = texto(entrada.titulo);
  if (!tipo || !unidad || !titulo) return { ok: false, error: 'El gráfico necesita tipo, unidad y título.' };

  const crudos = lista(entrada.puntos);
  if (crudos.length === 0) return { ok: false, error: 'El gráfico necesita al menos un punto.' };
  if (crudos.length > MAX_PUNTOS_GRAFICO) {
    return { ok: false, error: `El gráfico admite ${MAX_PUNTOS_GRAFICO} puntos como mucho; agrupa o recorta.` };
  }
  const puntos: PuntoDeGrafico[] = [];
  for (const p of crudos) {
    const crudo = esFila(p) ? texto(p.etiqueta, 60) : '';
    const valor = esFila(p) ? numero(p.valor) : null;
    if (!crudo || valor === null) return { ok: false, error: 'Cada punto necesita una etiqueta y un valor numérico.' };
    if (esUuid(crudo)) return { ok: false, error: 'Las etiquetas no pueden ser identificadores: usa el nombre del paciente o de la clínica, o la fecha.' };
    const etiqueta = diaLegible(crudo) ?? crudo;
    const valor2 = esFila(p) ? numero(p.valor2) : null;
    puntos.push(valor2 === null ? { etiqueta, valor } : { etiqueta, valor, valor2 });
  }

  const grafico: Grafico = { tipo, titulo, unidad, puntos };
  if (esFila(entrada.leyenda)) {
    const valor = texto(entrada.leyenda.valor, 60);
    const valor2 = texto(entrada.leyenda.valor2, 60);
    if (valor) grafico.leyenda = valor2 ? { valor, valor2 } : { valor };
  }
  return { ok: true, evento: { tipo: 'grafico', datos: grafico } };
}

function presentarTabla(entrada: Record<string, unknown>): ResultadoDePresentacion {
  const titulo = texto(entrada.titulo);
  const columnas: Tabla['columnas'] = lista(entrada.columnas).flatMap((c) => {
    if (!esFila(c)) return [];
    const clave = texto(c.clave, 40), rotulo = texto(c.rotulo, 60);
    if (!clave || !rotulo) return [];
    const unidad: UnidadDeColumna | undefined = alProtocolo(de(c.unidad, UNIDADES_DE_COLUMNA));
    return [unidad ? { clave, rotulo, unidad } : { clave, rotulo }];
  });
  if (!titulo || columnas.length === 0) return { ok: false, error: 'La tabla necesita título y columnas.' };

  const crudas = lista(entrada.filas);
  const todas = crudas.slice(0, MAX_FILAS_TABLA).map((f) => {
    const celdas = lista(f);
    const fila: Record<string, string | number | null> = {};
    columnas.forEach((c, i) => {
      fila[c.clave] = celdaLegible(c.clave, celdas[i]);
    });
    return fila;
  });
  // Un identificador no le sirve a quien lee el panel: esas columnas se quitan.
  const legibles = columnas.filter((c) => !esIdentificador(c.clave, todas.map((f) => f[c.clave])));
  if (legibles.length === 0) {
    return { ok: false, error: 'La tabla solo tiene identificadores: pon el nombre del paciente o de la clínica, el número de orden o la fecha.' };
  }
  const filas = todas.map((f) => Object.fromEntries(legibles.map((c) => [c.clave, f[c.clave]])));
  const avisos = [
    legibles.length < columnas.length ? 'Se quitaron las columnas de identificadores; no los nombres en el texto.' : '',
    crudas.length > MAX_FILAS_TABLA ? `Se enseñan las primeras ${MAX_FILAS_TABLA} filas de ${crudas.length}; dilo en la respuesta.` : '',
  ].filter(Boolean);
  const nota = avisos.length > 0 ? avisos.join(' ') : undefined;
  return { ok: true, evento: { tipo: 'tabla', datos: { titulo, columnas: legibles, filas } }, nota };
}

const PAR_DE_BUSQUEDA = objeto({
  clave: textoLibre('Nombre del parámetro, tal como lo lista el mapa.'),
  valor: textoLibre('Valor del parámetro.'),
}, ['clave', 'valor']);

export const presentacion: HerramientaDePresentacion[] = [
  {
    clase: 'presentacion',
    nombre: 'mostrar_enlace',
    descripcion:
      'Enseña un botón que lleva a una pantalla del panel. Úsala cada vez que des una cifra, para enlazar la ' +
      'pantalla donde se ve, y cuando pidan hacer un cambio (tú no los haces). La ruta tiene que ser una de las ' +
      'pantallas o fichas del mapa; search, solo con los parámetros que esa pantalla admite.',
    esquema: objeto({
      titulo: textoLibre('Lo que dice el botón, p. ej. «Ver la cartera vencida».'),
      ruta: textoLibre('La ruta del mapa, p. ej. /admin/cobranza o /admin/pacientes/<uuid>.'),
      search: { type: 'array', items: PAR_DE_BUSQUEDA, description: 'Parámetros de la URL, si hacen falta.' },
    }, ['titulo', 'ruta']),
    presentar: presentarEnlace,
  },
  {
    clase: 'presentacion',
    nombre: 'mostrar_grafico',
    descripcion:
      'Dibuja un gráfico en el panel. Úsala solo cuando aclara más que el texto: una serie en el tiempo ' +
      '(lineas), una comparación (barras) o un reparto entre partes (reparto). valor2 es una segunda serie ' +
      'opcional, dentro de la primera. Nunca mezcles en un gráfico lo financiado (sin comisión) y la deuda (con ' +
      'la Comisión Helios). ' +
      `Como mucho ${MAX_PUNTOS_GRAFICO} puntos.`,
    esquema: objeto({
      tipo: opcion(TIPOS_DE_GRAFICO, 'Forma del gráfico.'),
      titulo: textoLibre('Título, con la unidad y el periodo.'),
      unidad: opcion(UNIDADES_DE_GRAFICO, 'usd para montos, pct para porcentajes, numero para cuentas.'),
      puntos: {
        type: 'array',
        items: objeto({
          etiqueta: textoLibre('Rótulo del punto (fecha, clínica, tramo…).'),
          valor: { type: 'number', description: 'Valor de la serie principal.' },
          valor2: { type: 'number', description: 'Valor de la segunda serie, si la hay.' },
        }, ['etiqueta', 'valor']),
        description: 'Los puntos, en el orden en que se pintan.',
      },
      leyenda: {
        ...objeto({
          valor: textoLibre('Nombre de la serie principal.'),
          valor2: textoLibre('Nombre de la segunda serie.'),
        }, ['valor']),
        description: 'Nombres de las series, si hay dos.',
      },
    }, ['tipo', 'titulo', 'unidad', 'puntos']),
    presentar: (entrada) => presentarGrafico(entrada),
  },
  {
    clase: 'presentacion',
    nombre: 'mostrar_tabla',
    descripcion:
      'Enseña una tabla en el panel. Úsala para listas de más de cuatro o cinco elementos con varias columnas ' +
      `(pacientes, clínicas, semanas). Cada fila es una lista de celdas en el orden de columnas. Como mucho ` +
      `${MAX_FILAS_TABLA} filas. Lo financiado (sin comisión) y la deuda (con comisión) van en columnas distintas y rotuladas.`,
    esquema: objeto({
      titulo: textoLibre('Título de la tabla.'),
      columnas: {
        type: 'array',
        items: objeto({
          clave: textoLibre('Identificador corto de la columna.'),
          rotulo: textoLibre('Encabezado que se pinta.'),
          unidad: opcion(UNIDADES_DE_COLUMNA, 'Cómo se formatea la celda.'),
        }, ['clave', 'rotulo']),
        description: 'Las columnas, en orden.',
      },
      filas: {
        type: 'array',
        items: { type: 'array', items: { type: ['string', 'number', 'null'] } },
        description: 'Las filas: cada una, sus celdas en el orden de las columnas.',
      },
    }, ['titulo', 'columnas', 'filas']),
    presentar: (entrada) => presentarTabla(entrada),
  },
];
