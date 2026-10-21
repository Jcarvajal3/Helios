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

/**
 * Los grupos en pantalla. Los cuatro de la base (`business_parameter_catalog`)
 * y tres del panel para los parámetros de Helios (contrato §3), que se
 * reparten por clave con `GRUPO_POR_CLAVE`: así salen juntos aunque la base
 * los catalogue en otro grupo o en ninguno.
 */
export type IdGrupoEnPantalla = GrupoParametro | 'financiamiento' | 'control' | 'alertas'

export type GrupoEnPantalla = {
  grupo: IdGrupoEnPantalla | null
  titulo: string
  /** Una línea: qué decide el grupo y a quién afecta. */
  ayuda: string
}

/** Los parámetros de Helios, por el grupo en que se leen. */
export const GRUPO_POR_CLAVE: Readonly<Record<string, IdGrupoEnPantalla | undefined>> = {
  min_charge_usd: 'financiamiento',
  staff_commission_usd: 'financiamiento',
  receipt_resends_per_day: 'financiamiento',
  payment_four_eyes: 'control',
  eligibility_lookups_per_staff_day: 'control',
  alert_charges_per_merchant_day: 'alertas',
  alert_new_patients_per_merchant_day: 'alertas',
  alert_staff_share_pct: 'alertas',
  alert_staff_share_min_charges: 'alertas',
  alert_fpd_merchant_pct: 'alertas',
  alert_fpd_min_cases: 'alertas',
  alert_merchant_exposure_usd: 'alertas',
  alert_first_charge_limit_pct: 'alertas',
}

/** Los grupos, en el orden en que se leen: primero lo que paga el paciente. */
export const GRUPOS_DE_PARAMETROS: ReadonlyArray<GrupoEnPantalla> = [
  {
    grupo: 'producto',
    titulo: 'Reglas del pago en cuotas',
    ayuda: 'Lo que paga el paciente y los plazos del estado automático. Un cambio aquí afecta a todos los pacientes.',
  },
  {
    grupo: 'financiamiento',
    titulo: 'Órdenes y comisión del personal',
    ayuda: 'El monto mínimo de una orden, lo que gana el personal de la clínica por cada una y cuántas veces al día puede reenviar el comprobante.',
  },
  {
    grupo: 'control',
    titulo: 'Controles',
    ayuda: 'El doble control de los pagos registrados y el límite de consultas de cédula que protege la base de pacientes.',
  },
  {
    grupo: 'alertas',
    titulo: 'Umbrales de las alertas',
    ayuda: 'Desde dónde salta cada alerta de riesgo sobre clínicas y pacientes. Ninguna bloquea nada: solo avisan.',
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
 * cambia en su fila, «Días de gracia». `min_float_days`: solo lo lee
 * `helios_min_float_days()`, y a esa función no la llama nadie (las cuotas
 * vencen a los 7 y 14 días, `installment_interval_days`).
 */
export const CLAVES_SIN_USO: ReadonlySet<string> = new Set(['on_time_grace_days', 'min_float_days'])

/** Las filas repartidas por grupo, en el orden de arriba. Los grupos vacíos no salen, ni las claves sin uso. */
export function agruparParametros(
  filas: ReadonlyArray<Parametro>,
): Array<GrupoEnPantalla & { filas: Parametro[] }> {
  const vivas = filas.filter((f) => !CLAVES_SIN_USO.has(f.key))
  const grupoDe = (f: Parametro): IdGrupoEnPantalla | null => GRUPO_POR_CLAVE[f.key] ?? f.grupo
  return GRUPOS_DE_PARAMETROS.map((g) => ({
    ...g,
    filas: vivas.filter((f) => grupoDe(f) === g.grupo),
  })).filter((g) => g.filas.length > 0)
}

/**
 * Los parámetros que son un interruptor (0 apagado, 1 encendido). Se pintan
 * «Activado» o «Apagado» y solo aceptan 0 o 1.
 */
export const INTERRUPTORES: ReadonlySet<string> = new Set(['payment_four_eyes', 'patient_confirmation_required'])

/**
 * El rótulo en pantalla cuando el de la base no es el que usa el panel. La
 * base dice «Comisión de servicio», que es como se le llama al paciente; en
 * el panel es la «Comisión Helios» (Javier, 2026-10-13). Hasta que se cambie
 * la fila de `business_parameter_catalog`, manda esto.
 */
const ROTULO_EN_PANTALLA: Record<string, string | undefined> = {
  consumer_fee_pct: 'Comisión Helios',
  vat_pct: 'IVA de la Comisión Helios',
  // Una sola gracia para el cargo, «a tiempo» y el impago (27-09). La base
  // decía «Días antes del cargo» hasta 20260927650000.
  late_fee_grace_days: 'Días de gracia',
}

/**
 * El rótulo de los parámetros de Helios cuando el catálogo de la base no
 * trae uno (contrato §3): mejor un nombre que la clave en inglés.
 */
const ROTULO_SI_FALTA: Record<string, string | undefined> = {
  min_charge_usd: 'Monto mínimo por orden',
  staff_commission_usd: 'Comisión del personal por orden',
  eligibility_lookups_per_staff_day: 'Consultas de cédula por persona y día',
  payment_four_eyes: 'Doble control de pagos',
  receipt_resends_per_day: 'Reenvíos del comprobante por día',
  alert_charges_per_merchant_day: 'Financiamientos por clínica y día',
  alert_new_patients_per_merchant_day: 'Pacientes nuevos por clínica y día',
  alert_staff_share_pct: 'Altas de una sola persona en la semana',
  alert_fpd_merchant_pct: 'Impago de la primera cuota por clínica',
  alert_fpd_min_cases: 'Casos mínimos para juzgar el impago',
  alert_merchant_exposure_usd: 'Deuda viva por clínica',
  alert_first_charge_limit_pct: 'Cupo usado al estrenar',
}

/** Cómo se llama un parámetro en pantalla: el rótulo del panel, el de la base o la clave. */
export function nombreDelParametro(p: Pick<Parametro, 'key' | 'label'>): string {
  return ROTULO_EN_PANTALLA[p.key] ?? p.label ?? ROTULO_SI_FALTA[p.key] ?? p.key
}

/** Qué decide cada parámetro, para su `InfoDot`. Sin cifras: esas son el valor. */
export const QUE_DECIDE: Record<string, string | undefined> = {
  consumer_fee_pct:
    'La Comisión Helios: lo que el paciente paga a Helios por pagar su consulta en cuotas, sobre la consulta y sin IVA. A la clínica no le cuesta nada.',
  vat_pct: 'El IVA de la Comisión Helios. Se cobra al paciente y se remite: no es de Helios.',
  late_fee_usd: 'Lo que se suma a la deuda por cada cuota atrasada, una sola vez por episodio.',
  late_fee_grace_days:
    'Días de atraso que se perdonan. Al pasarlos cae el cargo por atraso; una cuota pagada dentro de ellos cuenta como pagada a tiempo, y el impago de una cuota se juzga al acabarlos. Es una sola gracia para las tres cosas.',
  installment_interval_days:
    'De la orden a la cuota 1, y de la cuota 1 a la cuota 2. También decide cuándo se le paga a la clínica (el día siguiente a cada vencimiento) y los plazos que se publican en la portada y los términos.',
  mora_demotion_days:
    'Días de atraso que pasan la cuenta de congelada a suspendida (y le bajan un nivel, si tiene más de uno).',
  mora_expulsion_days: 'Días de atraso que cuestan la cuenta y dan la deuda por perdida.',
  on_time_grace_days: 'Ya no se usa: «a tiempo» cuenta con los días de gracia, los mismos del cargo por atraso.',
  min_float_days: 'Ya no se usa: las cuotas vencen a los días entre cuotas.',
  umbral_mora_alerta_pct: 'La mora de una cosecha o de una clínica se pinta en ámbar desde este porcentaje.',
  umbral_mora_critica_pct: 'La mora de una cosecha o de una clínica se pinta en rojo desde este porcentaje.',
  umbral_impago_alerta_pct: 'El impago de la primera cuota se pinta en ámbar desde este porcentaje.',
  umbral_impago_critico_pct: 'El impago de la primera cuota se pinta en rojo desde este porcentaje.',
  umbral_cobro_a_tiempo_bueno_pct: 'El cobro a tiempo se pinta en verde desde este porcentaje.',
  umbral_cobro_a_tiempo_alerta_pct:
    'El cobro a tiempo se pinta en ámbar desde este porcentaje, y en rojo por debajo.',
  capital_disponible_usd: 'El capital que Helios tiene disponible para financiar financiamientos.',
  meta_financiado_semana_usd: 'Sin la Comisión Helios: el financiamiento financiado que se espera en una semana.',
  meta_mora_pct: 'La mora que no se quiere superar.',
  meta_cobro_a_tiempo_pct: 'El porcentaje de cuotas cobradas a tiempo que se quiere alcanzar.',
  meta_personas_activas_semana: 'Los pacientes con algún financiamiento en la semana que se quieren alcanzar.',
  meta_locales_activos: 'Las clínicas con financiamientos que se quieren tener.',
  min_charge_usd: 'El monto más bajo de una consulta en cuotas, sin la Comisión Helios.',
  staff_commission_usd:
    'Lo que gana quien registra una orden confirmada. Se le paga a la clínica el día siguiente a la confirmación, en la transferencia de ese día, y ella se la entrega a su personal. Una clínica puede tener la suya en su ficha › Condiciones; lo ya devengado no cambia.',
  eligibility_lookups_per_staff_day:
    'Cuántas cédulas puede consultar una persona de una clínica en un día. Pasado el límite no puede consultar más hasta mañana y salta la alerta «Demasiadas consultas de cédula»: protege la base de pacientes.',
  payment_four_eyes:
    'Encendido (1), quien registra un pago no puede aprobarlo: lo aprueba otra persona del equipo o un super admin. Recomendado en cuanto el equipo tenga más de una persona.',
  receipt_resends_per_day: 'Cuántas veces al día puede la clínica reenviar el comprobante de un mismo financiamiento.',
  alert_charges_per_merchant_day: 'Salta «Ráfaga de financiamientos» cuando una clínica registra más que esto en un día.',
  alert_new_patients_per_merchant_day:
    'Salta «Ráfaga de pacientes nuevos» cuando una clínica da de alta más pacientes nuevos que esto en un día.',
  alert_staff_share_pct:
    'Salta «Altas concentradas en una persona» cuando, en una clínica con varias personas, una sola registra más de este porcentaje de los financiamientos de la semana.',
  alert_fpd_merchant_pct:
    'Salta «Impago de la primera cuota en una clínica» cuando sus pacientes no pagan la primera cuota por encima de este porcentaje.',
  alert_fpd_min_cases: 'Los casos mínimos para juzgar el impago de la primera cuota de una clínica: con menos, no salta.',
  alert_merchant_exposure_usd:
    'Salta «Exposición alta en una clínica» cuando la deuda viva de sus financiamientos pasa de este monto.',
  alert_first_charge_limit_pct:
    'Salta «Cupo casi entero en el primer financiamiento» cuando un paciente nuevo usa más de este porcentaje de su cupo en su primer financiamiento.',
}

/** Las unidades que no admiten decimales, con su nombre largo. */
const UNIDADES_ENTERAS: Record<string, string | undefined> = {
  días: 'días',
  min: 'minutos',
  minutos: 'minutos',
  intentos: 'intentos',
  preguntas: 'preguntas',
  personas: 'personas',
  locales: 'locales',
  consumos: 'consumos',
  pacientes: 'pacientes',
  clínicas: 'clínicas',
  financiamientos: 'financiamientos',
  consultas: 'consultas',
  reenvíos: 'reenvíos',
  casos: 'casos',
}

/** El singular de las unidades que cuentan cosas: «1 día», no «1 días». */
const SINGULAR: Record<string, string | undefined> = {
  días: 'día',
  minutos: 'minuto',
  intentos: 'intento',
  preguntas: 'pregunta',
  personas: 'persona',
  locales: 'local',
  consumos: 'consumo',
  pacientes: 'paciente',
  clínicas: 'clínica',
  financiamientos: 'financiamiento',
  consultas: 'consulta',
  reenvíos: 'reenvío',
  casos: 'caso',
}

/**
 * Un valor con su unidad, para leer. `null` es «Sin definir», nunca un cero:
 * una meta sin fijar no es una meta de cero.
 */
export function formatValorParametro(valor: number | null, unidad: string | null, clave?: string): string {
  if (valor === null) return 'Sin definir'
  if (clave !== undefined && INTERRUPTORES.has(clave)) return valor === 1 ? 'Activado' : 'Apagado'
  // El dinero de Helios es el dólar: la unidad de un monto en el catálogo de
  // parámetros es '$' (o 'USD'). La de Ronda era '€' y se acepta mientras la
  // base no la porte, pintada en dólares: el importe guardado ya es USD. Una
  // clave `_usd` sin unidad en el catálogo también es un monto.
  if (unidad === '$' || unidad === 'USD' || unidad === '€') return formatUsd(valor)
  if (!unidad && clave?.endsWith('_usd')) return formatUsd(valor)

  // Con todos sus decimales: una comisión de 2,125 % no es uno de 2,1 %.
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
export function leerValorParametro(texto: string, unidad: string | null, clave?: string): LecturaDeValor {
  if (texto.trim() === '') return { ok: false, motivo: 'Escribe el valor nuevo.' }

  const valor = leerMonto(texto)
  if (valor === null) {
    return { ok: false, motivo: 'El valor no se entiende. Escríbelo con coma decimal, por ejemplo 2,5.' }
  }
  if (clave !== undefined && INTERRUPTORES.has(clave) && valor !== 0 && valor !== 1) {
    return { ok: false, motivo: 'Este parámetro es un interruptor: 1 lo enciende y 0 lo apaga.' }
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
