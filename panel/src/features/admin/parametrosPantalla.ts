import { formatUsd } from '@/components/ui'
import type { GrupoParametro, Parametro } from '@/features/admin/parametros'
import { leerMonto } from '@/lib/montos'

// ═══════════════════════════════════════════════════════════════════════════
// Cómo se enseñan y se editan los parámetros del negocio en Ajustes.
//
// El rótulo, la unidad y el grupo de cada clave vienen de la base
// (`business_parameter_catalog`). Aquí vive lo que la base no guarda: el
// título de cada grupo, la explicación larga de cada clave y las reglas para
// leer lo que alguien escribe en el campo.
// ═══════════════════════════════════════════════════════════════════════════

export type GrupoEnPantalla = {
  grupo: GrupoParametro | null
  titulo: string
  /** Una línea: qué decide el grupo y a quién afecta. */
  ayuda: string
}

/** Los grupos, en el orden en que se leen: primero lo que cambia la app. */
export const GRUPOS_DE_PARAMETROS: ReadonlyArray<GrupoEnPantalla> = [
  {
    grupo: 'producto',
    titulo: 'Reglas del crédito',
    ayuda: 'Lo que paga el paciente y los plazos del estado automático. Un cambio aquí afecta a todos los pacientes.',
  },
  {
    grupo: 'umbral',
    titulo: 'Umbrales de color',
    ayuda: 'A partir de qué porcentaje una cifra del panel se pinta en ámbar o en rojo.',
  },
  {
    grupo: 'meta',
    titulo: 'Metas',
    ayuda: 'Los objetivos contra los que Gerencia compara cada semana.',
  },
  {
    grupo: 'capital',
    titulo: 'Capital',
    ayuda: 'El dinero con el que cuenta Helios para financiar financiamientos.',
  },
  {
    grupo: null,
    titulo: 'Otros',
    ayuda: 'Claves que todavía no tienen grupo en el catálogo de la base.',
  },
]

/**
 * Claves que siguen en la base y ya no deciden nada, así que no se enseñan ni
 * se pueden cambiar. `on_time_grace_days`: desde el 27-09 hay UNA gracia
 * (Javier: «deben ser el mismo, déjalo en 3 días»); `helios_on_time_grace_days()`
 * devuelve la del cargo por atraso (migración 20260927650000), y esa se
 * cambia en su fila, «Días de gracia».
 */
export const CLAVES_SIN_USO: ReadonlySet<string> = new Set(['on_time_grace_days'])

/** Las filas repartidas por grupo, en el orden de arriba. Los grupos vacíos no salen, ni las claves sin uso. */
export function agruparParametros(
  filas: ReadonlyArray<Parametro>,
): Array<GrupoEnPantalla & { filas: Parametro[] }> {
  const vivas = filas.filter((f) => !CLAVES_SIN_USO.has(f.key))
  return GRUPOS_DE_PARAMETROS.map((g) => ({
    ...g,
    filas: vivas.filter((f) => f.grupo === g.grupo),
  })).filter((g) => g.filas.length > 0)
}

/**
 * El rótulo en pantalla cuando el de la base no es el que usa el panel. La
 * base dice «Comisión del usuario» y el fee se llama «service fee» (Javier,
 * 27-09); la comisión es la del local. Hasta que se cambie la fila de
 * `business_parameter_catalog`, manda esto.
 */
const ROTULO_EN_PANTALLA: Record<string, string | undefined> = {
  consumer_fee_pct: 'Service fee',
  vat_pct: 'IVA del service fee',
  // Una sola gracia para el cargo, «a tiempo» y el impago (27-09). La base
  // decía «Días antes del cargo» hasta 20260927650000.
  late_fee_grace_days: 'Días de gracia',
}

/** Cómo se llama un parámetro en pantalla: el rótulo del panel, el de la base o la clave. */
export function nombreDelParametro(p: Pick<Parametro, 'key' | 'label'>): string {
  return ROTULO_EN_PANTALLA[p.key] ?? p.label ?? p.key
}

/** Qué decide cada parámetro, para su `InfoDot`. Sin cifras: esas son el valor. */
export const QUE_DECIDE: Record<string, string | undefined> = {
  consumer_fee_pct:
    'El service fee: lo que el paciente paga a Helios por financiar su financiamiento, sobre el financiamiento y sin IVA. No es la comisión de la clínica.',
  vat_pct: 'El IVA del service fee. Se cobra al paciente y se remite: no es de Helios.',
  late_fee_usd: 'Lo que se suma a la deuda por cada cuota atrasada, una sola vez por episodio.',
  late_fee_grace_days:
    'Días de atraso que se perdonan. Al pasarlos cae el cargo por atraso; una cuota pagada dentro de ellos cuenta como pagada a tiempo, y el impago de una cuota se juzga al acabarlos. Es una sola gracia para las tres cosas.',
  installment_interval_days: 'Del financiamiento a la cuota 1, y de la cuota 1 a la cuota 2.',
  mora_demotion_days: 'Días de atraso que cuestan un nivel y pasan la cuenta de congelada a suspendida.',
  mora_expulsion_days: 'Días de atraso que cuestan la cuenta y dan la deuda por perdida.',
  on_time_grace_days: 'Ya no se usa: «a tiempo» cuenta con los días de gracia, los mismos del cargo por atraso.',
  min_float_days: 'Días mínimos entre el financiamiento y su primera cuota.',
  umbral_mora_alerta_pct: 'La mora de una cosecha o de una clínica se pinta en ámbar desde este porcentaje.',
  umbral_mora_critica_pct: 'La mora de una cosecha o de una clínica se pinta en rojo desde este porcentaje.',
  umbral_impago_alerta_pct: 'El impago de la primera cuota se pinta en ámbar desde este porcentaje.',
  umbral_impago_critico_pct: 'El impago de la primera cuota se pinta en rojo desde este porcentaje.',
  umbral_cobro_a_tiempo_bueno_pct: 'El cobro a tiempo se pinta en verde desde este porcentaje.',
  umbral_cobro_a_tiempo_alerta_pct:
    'El cobro a tiempo se pinta en ámbar desde este porcentaje, y en rojo por debajo.',
  capital_disponible_usd: 'El capital que Helios tiene disponible para financiar financiamientos.',
  meta_financiado_semana_usd: 'Sin el service fee: el financiamiento financiado que se espera en una semana.',
  meta_mora_pct: 'La mora que no se quiere superar.',
  meta_cobro_a_tiempo_pct: 'El porcentaje de cuotas cobradas a tiempo que se quiere alcanzar.',
  meta_personas_activas_semana: 'Los pacientes con algún financiamiento en la semana que se quieren alcanzar.',
  meta_locales_activos: 'Las clínicas con financiamientos que se quieren tener.',
}

/** Las unidades que no admiten decimales, con su nombre largo. */
const UNIDADES_ENTERAS: Record<string, string | undefined> = {
  días: 'días',
  min: 'minutos',
  personas: 'personas',
  locales: 'locales',
  consumos: 'consumos',
}

/** El singular de las unidades que cuentan cosas: «1 día», no «1 días». */
const SINGULAR: Record<string, string | undefined> = {
  días: 'día',
  personas: 'persona',
  locales: 'local',
  consumos: 'consumo',
}

/**
 * Un valor con su unidad, para leer. `null` es «Sin definir», nunca un cero:
 * una meta sin fijar no es una meta de cero.
 */
export function formatValorParametro(valor: number | null, unidad: string | null): string {
  if (valor === null) return 'Sin definir'
  // El dinero de Helios es el dólar: la unidad de un monto en el catálogo de
  // parámetros es '$' (o 'USD'). La de Ronda era '€' y se acepta mientras la
  // base no la porte, pintada en dólares: el importe guardado ya es USD.
  if (unidad === '$' || unidad === 'USD' || unidad === '€') return formatUsd(valor)

  // Con todos sus decimales: un fee de 2,125 % no es uno de 2,1 %.
  const cifra = valor.toLocaleString('es-VE', { maximumFractionDigits: 4 })
  if (unidad === '%') return `${cifra} %`
  if (!unidad) return cifra
  return `${cifra} ${valor === 1 ? (SINGULAR[unidad] ?? unidad) : unidad}`
}

export type LecturaDeValor = { ok: true; valor: number } | { ok: false; motivo: string }

/**
 * Lo que alguien escribió en el campo, a número, con las mismas reglas que
 * aplica `admin_set_business_parameter` y alguna más: el servidor acepta
 * «2,5 días», pero el estado automático cuenta días enteros.
 */
export function leerValorParametro(texto: string, unidad: string | null): LecturaDeValor {
  if (texto.trim() === '') return { ok: false, motivo: 'Escribe el valor nuevo.' }

  const valor = leerMonto(texto)
  if (valor === null) {
    return { ok: false, motivo: 'El valor no se entiende. Escríbelo con coma decimal, por ejemplo 2,5.' }
  }
  if (valor < 0) return { ok: false, motivo: 'Un parámetro no puede ser negativo.' }
  if (unidad === '%' && valor > 100) {
    return { ok: false, motivo: 'Un porcentaje no puede pasar de 100.' }
  }

  const entera = unidad ? UNIDADES_ENTERAS[unidad] : undefined
  if (entera && !Number.isInteger(valor)) {
    return { ok: false, motivo: `Este parámetro se cuenta en ${entera} enteros.` }
  }

  return { ok: true, valor }
}
