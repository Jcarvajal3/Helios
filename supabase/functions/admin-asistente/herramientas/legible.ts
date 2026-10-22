/**
 * Lo que convierte filas de la base en algo que lee quien no programa: sin
 * identificadores internos, con rótulos en español, el número de orden como
 * «#1013» y las fechas como «24 sep».
 *
 * Lo usan las tablas y los gráficos de `consultar_datos` y los que pide el
 * modelo con `mostrar_tabla` y `mostrar_grafico`: un uuid en una tabla del
 * panel no le sirve a nadie, lo escriba quien lo escriba.
 */

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const esUuid = (v: unknown): boolean => typeof v === 'string' && UUID.test(v.trim());

/** Una columna de identificadores: se llama `*_id` (o `id`) o todos sus valores son uuid. */
export function esIdentificador(clave: string, valores: readonly unknown[]): boolean {
  if (/(^|_)id$/i.test(clave)) return true;
  const presentes = valores.filter((v) => v !== null && v !== undefined && v !== '');
  return presentes.length > 0 && presentes.every(esUuid);
}

/** Con el vocabulario del superadmin: «paciente», «financiado», «Comisión Helios». */
const ROTULOS: Record<string, string> = {
  paciente: 'Paciente',
  pacientes: 'Pacientes',
  consulta_usd: 'Financiado ($)',
  consumo_usd: 'Financiado ($)',
  financed_usd: 'Financiado ($)',
  comision_usd: 'Comisión Helios ($)',
  comision_iva_usd: 'IVA de la comisión ($)',
  total_a_cobrar_usd: 'Total a cobrar ($)',
  a_la_clinica_usd: 'A la clínica ($)',
  cuota_usd: 'Cuota ($)',
  monto_ves: 'Monto (Bs)',
  nombre: 'Nombre',
  clinica: 'Clínica',
  medico: 'Médico',
  sede: 'Sede',
  categoria: 'Categoría',
  numero_orden: 'Orden',
  ordenes: 'Órdenes',
  dia: 'Día',
  dia_de_la_orden: 'Día de la orden',
  alta_dia: 'Alta',
  vence_el: 'Vence',
  pagado_el: 'Pagado el',
  se_paga_el: 'Se paga el',
  dias_atraso: 'Días de atraso',
  creado_at: 'Fecha',
  creada_at: 'Fecha',
  recibido_at: 'Recibido',
  reportado_at: 'Reportado',
  contactado_at: 'Contactado',
  primera_orden_at: 'Primera orden',
  ultima_orden_at: 'Última orden',
  clinica_de_registro: 'Clínica de registro',
  estado_del_pais: 'Estado',
};

/** Palabras que en los nombres de columna van sin tilde. */
const TILDES: Record<string, string> = {
  dia: 'día',
  dias: 'días',
  categoria: 'categoría',
  numero: 'número',
  ultimo: 'último',
  ultima: 'última',
  version: 'versión',
  promocion: 'promoción',
  telefono: 'teléfono',
  sesion: 'sesión',
  razon: 'razón',
  pais: 'país',
  clinica: 'clínica',
  clinicas: 'clínicas',
  medico: 'médico',
  ordenes: 'órdenes',
  comision: 'comisión',
};

/** «pagado_usd» → «Pagado ($)»; «dias_atraso» → «Días de atraso». */
export function rotularColumna(clave: string): string {
  if (ROTULOS[clave]) return ROTULOS[clave];
  const usd = /(^|_)usd$/.test(clave);
  const pct = /(^|_)pct$/.test(clave);
  const palabras = clave.replace(/_(usd|at|pct)$/, '').split('_').filter(Boolean).map((p) => TILDES[p] ?? p);
  const base = palabras.join(' ') || clave;
  const rotulo = base.charAt(0).toUpperCase() + base.slice(1);
  return usd ? `${rotulo} ($)` : pct ? `${rotulo} (%)` : rotulo;
}

const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];

/** El día de un `date` o de un instante (en Caracas), como «24 sep»; `null` si no es una fecha. */
export function diaLegible(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  let dia: string | null = null;
  if (/^\d{4}-\d{2}-\d{2}$/.test(v)) dia = v;
  else if (/^\d{4}-\d{2}-\d{2}T/.test(v)) {
    const t = new Date(v);
    // Caracas es UTC−4 todo el año.
    if (!Number.isNaN(t.getTime())) dia = new Date(t.getTime() - 4 * 3600_000).toISOString().slice(0, 10);
  }
  if (!dia) return null;
  const [, mes, d] = dia.split('-').map(Number);
  return `${d} ${MESES[mes - 1]}`;
}

/** «1013» → «#1013»; si la consulta ya le puso la almohadilla, no se repite. */
const conAlmohadilla = (v: number | string): string => `#${String(v).replace(/^#+/, '')}`;

/** Un valor como etiqueta de un gráfico: fechas legibles, sí/no y el número de orden con «#». */
export function etiquetaLegible(clave: string, v: unknown): string {
  if (v === null || v === undefined || v === '') return 'Sin dato';
  if (typeof v === 'boolean') return v ? 'Sí' : 'No';
  if (/numero_orden|^orden$/.test(clave) && (typeof v === 'number' || typeof v === 'string')) return conAlmohadilla(v);
  return (diaLegible(v) ?? String(v)).slice(0, 60);
}

/** Una celda de tabla: el número de orden con «#» y los sí/no; lo demás, tal cual. */
export function celdaLegible(clave: string, v: unknown): string | number | null {
  if (v === null || v === undefined) return null;
  if (typeof v === 'boolean') return v ? 'sí' : 'no';
  if (/numero_orden|^orden$/.test(clave) && (typeof v === 'number' || typeof v === 'string')) return conAlmohadilla(v);
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  if (typeof v === 'string') return v.slice(0, 200);
  return null;
}

/** Las columnas que se enseñan: todas menos las de identificadores. */
export function columnasLegibles(filas: ReadonlyArray<Record<string, unknown>>, claves: readonly string[]): string[] {
  return claves.filter((c) => !esIdentificador(c, filas.map((f) => f[c])));
}
