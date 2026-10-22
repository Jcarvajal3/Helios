/**
 * `consultar_datos`: un SELECT sobre las vistas del esquema `asistente`, para
 * lo que no cubre ninguna RPC (qué especialidad financia más, cuántas órdenes
 * rechazan los pacientes, cómo les fue a los WhatsApp, repartos por cualquier
 * columna…).
 *
 * La seguridad vive en la base (`admin_assistant_query`: rol que solo lee esas
 * vistas, solo lectura, tope de filas). Aquí se decide cómo se enseña: el
 * modelo dice qué forma quiere y qué columnas pintar, y la tabla o el gráfico
 * se arman con las filas tal como vinieron de la base, sin identificadores y
 * con rótulos legibles (`legible.ts`). Ninguna cifra dibujada pasa por el modelo.
 */

import type { Evento, Grafico, PuntoDeGrafico, Tabla, UnidadDeColumna } from '../sse.ts';
import { ErrorDeEntrada, esFila, leerOpcion, leerTexto, objeto, opcion, textoLibre } from './esquema.ts';
import { celdaLegible, columnasLegibles, esIdentificador, etiquetaLegible, rotularColumna } from './legible.ts';
import { MAX_FILAS_TABLA, MAX_PUNTOS_GRAFICO } from './presentacion.ts';
import type { Entrada, HerramientaDeDatos, PantallaDeHerramienta, Visualizacion } from './tipos.ts';

export { rotularColumna };

export const FORMAS = ['tabla', 'barras', 'lineas', 'reparto', 'nada'] as const;
/**
 * Las que puede pedir el modelo. El protocolo con el panel (`sse.ts`, heredado
 * de Ronda) llama `eur` a la unidad de dinero, y el panel de Helios la pinta en
 * dólares: el modelo dice `usd` y aquí se traduce.
 */
const UNIDADES = ['usd', 'numero', 'pct'] as const;
type Unidad = Grafico['unidad'];

export const unidadDelProtocolo = (u: (typeof UNIDADES)[number] | undefined): Unidad | undefined =>
  u === 'usd' ? 'eur' : u;

/** Columnas de más en una tabla del panel: a partir de aquí no se leen. */
const MAX_COLUMNAS = 8;

/**
 * Qué pantalla enseña lo que lee la consulta. Se enlaza la primera de esta
 * lista que encaje, no la primera vista de la consulta: la más concreta va
 * antes. Las cuotas llevan a Por cobrar solo si la consulta mira atrasos o
 * pagos; si no, son el reparto de una orden.
 */
const PANTALLAS: ReadonlyArray<readonly [RegExp, PantallaDeHerramienta]> = [
  [/\b(from|join)\s+mensajes\b/i, { ruta: '/admin/avisos' }],
  [/\b(from|join)\s+contactos_cobranza\b/i, { ruta: '/admin/cobranza' }],
  [/\b(from|join)\s+(pagos_reportados|comprobantes)\b/i, { ruta: '/admin/cobros' }],
  [/\b(from|join)\s+(pagos_a_clinicas|liquidaciones)\b/i, { ruta: '/admin/pagos-clinicas' }],
  [/^(?=[\s\S]*\b(from|join)\s+cuotas\b)(?=[\s\S]*\b(vencida|dias_atraso|vence_el|pagada_at|castigada_at|pendiente|pagada)\b)/i, { ruta: '/admin/cobranza' }],
  [/\b(from|join)\s+(ordenes|cuotas)\b/i, { ruta: '/admin/financiamientos' }],
  [/\b(from|join)\s+niveles\b/i, { ruta: '/admin/ajustes', search: { tab: 'niveles' } }],
  [/\b(from|join)\s+clinicas\b/i, { ruta: '/admin/clinicas' }],
  [/\b(from|join)\s+pacientes\b/i, { ruta: '/admin/pacientes' }],
];

export function pantallaDeLaConsulta(sql: string): PantallaDeHerramienta | null {
  return PANTALLAS.find(([patron]) => patron.test(sql))?.[1] ?? null;
}

const esNumero = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v);

/** La unidad de una columna por su nombre y sus valores. */
export function unidadDeColumna(clave: string, valores: readonly unknown[]): UnidadDeColumna {
  if (/numero_orden/.test(clave)) return 'texto';
  // `eur` es la unidad de dinero del protocolo: el panel la pinta en dólares.
  if (/(^|_)usd$/.test(clave)) return 'eur';
  if (/(^|_)(pct|porcentaje|tasa_pct)$/.test(clave)) return 'pct';
  const presentes = valores.filter((v) => v !== null && v !== undefined);
  if (presentes.length > 0 && presentes.every(esNumero)) return 'numero';
  if (presentes.length > 0 && presentes.every((v) => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}/.test(v))) return 'fecha';
  return 'texto';
}

function filasDe(datos: unknown): Array<Record<string, unknown>> {
  if (!esFila(datos) || !Array.isArray(datos.filas)) return [];
  return datos.filas.filter(esFila);
}

/**
 * La tabla con las columnas que una persona entiende: sin identificadores.
 * `null` si no queda ninguna (la consulta solo traía ids).
 */
function armarTabla(titulo: string, filas: Array<Record<string, unknown>>): { tabla: Tabla; nota: string } | null {
  const legibles = columnasLegibles(filas, Object.keys(filas[0]));
  if (legibles.length === 0) return null;
  const claves = legibles.slice(0, MAX_COLUMNAS);
  const columnas = claves.map((clave) => ({
    clave,
    rotulo: rotularColumna(clave),
    unidad: unidadDeColumna(clave, filas.map((f) => f[clave])),
  }));
  const celdas = filas.slice(0, MAX_FILAS_TABLA).map((f) => Object.fromEntries(claves.map((c) => [c, celdaLegible(c, f[c])])));
  const avisos: string[] = [];
  if (legibles.length > MAX_COLUMNAS) avisos.push(`solo se enseñan las primeras ${MAX_COLUMNAS} columnas`);
  if (filas.length > MAX_FILAS_TABLA) avisos.push(`solo se enseñan las primeras ${MAX_FILAS_TABLA} filas de ${filas.length}; dilo`);
  return {
    tabla: { titulo, columnas, filas: celdas },
    nota: `El panel ya enseña esta tabla («${titulo}»)${avisos.length ? ` (${avisos.join('; ')})` : ''}.`,
  };
}

type Pedido = { forma: 'barras' | 'lineas' | 'reparto'; etiqueta?: string; valor?: string; valor2?: string; unidad?: Unidad };

/** Un gráfico, o el motivo por el que no se puede con esas filas. */
function armarGrafico(titulo: string, filas: Array<Record<string, unknown>>, p: Pedido): { grafico: Grafico } | { error: string } {
  const claves = Object.keys(filas[0]);
  const numericas = claves.filter((c) => filas.every((f) => f[c] === null || esNumero(f[c])) && filas.some((f) => esNumero(f[c])));
  const ids = new Set(claves.filter((c) => esIdentificador(c, filas.map((f) => f[c]))));
  const etiqueta = p.etiqueta ?? claves.find((c) => !numericas.includes(c) && !ids.has(c)) ?? claves[0];
  const valor = p.valor ?? numericas.find((c) => c !== etiqueta);
  const falta = [etiqueta, valor, p.valor2].filter((c): c is string => c !== undefined && !claves.includes(c));
  if (falta.length > 0) return { error: `el resultado no trae ${falta.map((c) => `«${c}»`).join(', ')}; columnas: ${claves.join(', ')}` };
  if (ids.has(etiqueta)) return { error: `«${etiqueta}» son identificadores internos; pon paciente, clinica, medico o una fecha como rótulo` };
  if (!valor || !numericas.includes(valor)) return { error: `«${valor ?? '?'}» no es una columna numérica` };
  if (p.valor2 && !numericas.includes(p.valor2)) return { error: `«${p.valor2}» no es una columna numérica` };
  if (filas.length > MAX_PUNTOS_GRAFICO) return { error: `son ${filas.length} puntos y el gráfico admite ${MAX_PUNTOS_GRAFICO}; agrupa más` };

  const puntos: PuntoDeGrafico[] = filas.map((f) => {
    const v = f[valor], v2 = p.valor2 ? f[p.valor2] : null;
    const punto: PuntoDeGrafico = { etiqueta: etiquetaLegible(etiqueta, f[etiqueta]), valor: esNumero(v) ? v : 0 };
    if (esNumero(v2)) punto.valor2 = v2;
    return punto;
  });
  const deducida = unidadDeColumna(valor, filas.map((f) => f[valor]));
  const unidad: Unidad = p.unidad ?? (deducida === 'eur' || deducida === 'pct' ? deducida : 'numero');
  const grafico: Grafico = { tipo: p.forma, titulo, unidad, puntos };
  if (p.valor2) grafico.leyenda = { valor: rotularColumna(valor), valor2: rotularColumna(p.valor2) };
  return { grafico };
}

const SOLO_IDS =
  'La consulta solo trae identificadores internos y no se enseñan. Si hace falta una lista, repítela con paciente, ' +
  'clinica, medico, numero_orden o fechas.';

export function visualizarConsulta(entrada: Entrada, datos: unknown): Visualizacion | null {
  const forma = leerOpcion(entrada.mostrar, FORMAS) ?? 'tabla';
  const filas = filasDe(datos);
  if (filas.length === 0) return { nota: 'La consulta no devolvió filas.' };
  if (forma === 'nada') return null;
  // Un «select *» es para mirar qué hay, no una respuesta: no se pinta.
  if (typeof entrada.sql === 'string' && /^\s*select\s+\*/i.test(entrada.sql)) {
    return { nota: 'Un «select *» no se enseña en el panel: para enseñar algo, elige las columnas que responden la pregunta.' };
  }
  const titulo = leerTexto(entrada.titulo, 120) ?? 'Resultado de la consulta';

  if (forma !== 'tabla') {
    const r = armarGrafico(titulo, filas, {
      forma,
      etiqueta: leerTexto(entrada.etiqueta, 63),
      valor: leerTexto(entrada.valor, 63),
      valor2: leerTexto(entrada.valor2, 63),
      unidad: unidadDelProtocolo(leerOpcion(entrada.unidad, UNIDADES)),
    });
    if ('grafico' in r) {
      const evento: Evento = { tipo: 'grafico', datos: r.grafico };
      return {
        evento,
        nota: `El panel ya enseña este gráfico («${titulo}») con estas filas: no lo repitas con mostrar_grafico ni copies en el texto todas sus cifras.`,
      };
    }
    // Sin gráfico posible, las filas se enseñan igual: en tabla.
    const t = armarTabla(titulo, filas);
    if (!t) return { nota: `No se pudo dibujar el gráfico (${r.error}). ${SOLO_IDS}` };
    return { evento: { tipo: 'tabla', datos: t.tabla }, nota: `No se pudo dibujar el gráfico (${r.error}). ${t.nota}` };
  }
  if (filas.length === 1 && Object.keys(filas[0]).length <= 2) {
    return { nota: 'Es una sola cifra: dila en el texto; no hace falta tabla.' };
  }
  const t = armarTabla(titulo, filas);
  if (!t) return { nota: SOLO_IDS };
  return { evento: { tipo: 'tabla', datos: t.tabla }, nota: `${t.nota} No repitas en el texto todas sus filas.` };
}

export const consulta: HerramientaDeDatos[] = [
  {
    clase: 'datos',
    nombre: 'consultar_datos',
    rpc: 'admin_assistant_query',
    rotulo: 'Consultando los datos',
    descripcion:
      'Lee con un SELECT de PostgreSQL las vistas del asistente (la lista está en el system prompt): pacientes, ' +
      'clínicas, órdenes, cuotas, pagos, comprobantes, liquidaciones, mensajes… Úsala para lo que no contesta otra ' +
      'herramienta y para cualquier reparto, ranking o serie que haya que dibujar. En la misma llamada dices cómo se ' +
      'enseña (mostrar) y qué columnas pintar: el panel arma la tabla o el gráfico con las filas de la base. Pantalla: ' +
      'la que corresponde a las vistas leídas.',
    esquema: objeto({
      sql: textoLibre('Un solo SELECT sobre las vistas, sin punto y coma ni prefijo de esquema.'),
      titulo: textoLibre('Título de la tabla o del gráfico, con el periodo: «Órdenes por especialidad», «WhatsApp, semana del 19-10».'),
      mostrar: opcion(
        FORMAS,
        'tabla para listas; barras para comparar categorías; lineas para una serie en el tiempo; reparto para las ' +
          'partes de un total; nada si es una sola cifra o una consulta para mirar o comprobar algo.',
      ),
      etiqueta: textoLibre('Para un gráfico: la columna de los rótulos (dia, clinica, medico, categoria…). Nunca un *_id.'),
      valor: textoLibre('Para un gráfico: la columna numérica de la serie principal.'),
      valor2: textoLibre('Para un gráfico: una segunda columna numérica, opcional (se pinta dentro de la primera).'),
      unidad: opcion(UNIDADES, 'Para un gráfico: usd, numero o pct. Si se omite, se deduce del nombre de la columna.'),
    }, ['sql', 'titulo', 'mostrar']),
    argumentos: (e) => {
      const sql = leerTexto(e.sql, 8000);
      if (!sql) throw new ErrorDeEntrada('Falta «sql»: escribe un SELECT sobre las vistas del asistente.');
      return { p_sql: sql, p_max_rows: 200 };
    },
    pantalla: (e) => pantallaDeLaConsulta(typeof e.sql === 'string' ? e.sql : ''),
    visualizar: visualizarConsulta,
    datosPersonales: 'lista',
  },
];
