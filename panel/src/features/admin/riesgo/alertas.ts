import { formatDay, formatPhone, formatUsd } from '@/components/ui'
import type { BadgeTone } from '@/components/ui'
import { comoFila, comoLista, numero, numeroONulo, texto, textoONulo, textos } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Las alertas de riesgo (`admin_risk_alerts`, 20260925201000 + H10).
//
// No se guardan: la base las deriva de los datos en cada llamada y solo guarda
// quién las revisó. Aquí se tipan, se describen en una frase y se filtran.
//
// En Helios ninguna bloquea nada (plan §14): son la defensa contra las altas
// falsas mientras no haya expediente. Cada una es de un paciente, de una
// clínica o de alguien de su personal (`subject_type`).
// ═══════════════════════════════════════════════════════════════════════════

export type TipoAlerta =
  | 'cuenta_relacionada'
  | 'consumo_sobre_cupo'
  | 'telefono_repetido'
  | 'correo_repetido'
  | 'correo_rebotado'
  | 'rafaga_de_altas'
  | 'rafaga_de_pacientes_nuevos'
  | 'secretaria_concentrada'
  | 'impago_primera_cuota_clinica'
  | 'exposicion_clinica'
  | 'referencia_repetida'
  | 'cupo_al_limite_al_estrenar'
  | 'consultas_de_cedula_excesivas'

export type Gravedad = 'alta' | 'media'
export const GRAVEDADES: readonly Gravedad[] = ['alta', 'media']

export const GRAVEDAD: Record<Gravedad, { rotulo: string; tono: BadgeTone }> = {
  alta: { rotulo: 'Alta', tono: 'error' },
  media: { rotulo: 'Media', tono: 'warning' },
}

/** De quién es la alerta. */
export type TipoSujeto = 'paciente' | 'clinica' | 'personal'
const SUJETOS: readonly TipoSujeto[] = ['paciente', 'clinica', 'personal']

export const ROTULO_SUJETO: Record<TipoSujeto, string> = {
  paciente: 'Paciente',
  clinica: 'Clínica',
  personal: 'Personal de la clínica',
}

/**
 * Cada tipo, con su nombre, qué lo dispara, la gravedad que suele traer (la
 * que manda es la de la fila) y de quién es. El parámetro, si tiene umbral en
 * Ajustes › Parámetros (contrato §3).
 */
export const TIPOS: Record<
  TipoAlerta,
  { rotulo: string; descripcion: string; gravedad: Gravedad; sujeto: TipoSujeto; parametro?: string }
> = {
  cuenta_relacionada: {
    rotulo: 'Cuenta relacionada',
    descripcion: 'Dos pacientes comparten cédula o nombre: puede ser el mismo paciente registrado dos veces.',
    gravedad: 'alta',
    sujeto: 'paciente',
  },
  consumo_sobre_cupo: {
    rotulo: 'Financiamiento por encima de su cupo',
    descripcion: 'Un financiamiento que pasó del cupo del paciente o se registró con una cuota vencida: la base no debería dejarlo pasar.',
    gravedad: 'alta',
    sujeto: 'paciente',
  },
  telefono_repetido: {
    rotulo: 'Teléfono repetido',
    descripcion: 'El mismo teléfono está en más de un paciente. En una familia es normal; en pacientes sin relación, sospechoso.',
    gravedad: 'media',
    sujeto: 'paciente',
  },
  correo_repetido: {
    rotulo: 'Correo repetido',
    descripcion: 'El mismo correo está en más de un paciente: el comprobante de uno le llega a otro.',
    gravedad: 'media',
    sujeto: 'paciente',
  },
  correo_rebotado: {
    rotulo: 'Correo rebotado',
    descripcion: 'El comprobante no llegó: el correo del paciente no existe o lo rechazó. Hay que corregirlo y reenviarlo.',
    gravedad: 'media',
    sujeto: 'paciente',
  },
  rafaga_de_altas: {
    rotulo: 'Ráfaga de financiamientos',
    descripcion: 'Una clínica registró más financiamientos en un día que el umbral.',
    gravedad: 'alta',
    sujeto: 'clinica',
    parametro: 'alert_charges_per_merchant_day',
  },
  rafaga_de_pacientes_nuevos: {
    rotulo: 'Ráfaga de pacientes nuevos',
    descripcion: 'Una clínica dio de alta más pacientes nuevos en un día que el umbral.',
    gravedad: 'alta',
    sujeto: 'clinica',
    parametro: 'alert_new_patients_per_merchant_day',
  },
  secretaria_concentrada: {
    rotulo: 'Altas concentradas en una persona',
    descripcion: 'En una clínica con varias personas, una sola registró más del umbral de los financiamientos de la semana.',
    gravedad: 'media',
    sujeto: 'personal',
    parametro: 'alert_staff_share_pct',
  },
  impago_primera_cuota_clinica: {
    rotulo: 'Impago de la primera cuota en una clínica',
    descripcion: 'Los pacientes de una clínica no pagan la primera cuota por encima del umbral, con un mínimo de casos.',
    gravedad: 'alta',
    sujeto: 'clinica',
    parametro: 'alert_fpd_merchant_pct',
  },
  exposicion_clinica: {
    rotulo: 'Exposición alta en una clínica',
    descripcion: 'La deuda viva de los financiamientos de una clínica pasó del umbral.',
    gravedad: 'media',
    sujeto: 'clinica',
    parametro: 'alert_merchant_exposure_usd',
  },
  referencia_repetida: {
    rotulo: 'Referencia de pago repetida',
    descripcion: 'La misma referencia bancaria aparece en pagos de pacientes distintos.',
    gravedad: 'alta',
    sujeto: 'paciente',
  },
  cupo_al_limite_al_estrenar: {
    rotulo: 'Cupo casi entero en el primer financiamiento',
    descripcion: 'Un paciente nuevo usó casi todo su cupo en su primer financiamiento.',
    gravedad: 'media',
    sujeto: 'paciente',
    parametro: 'alert_first_charge_limit_pct',
  },
  consultas_de_cedula_excesivas: {
    rotulo: 'Demasiadas consultas de cédula',
    descripcion: 'Alguien del personal pasó el límite diario de consultas de cédula: puede estar recorriendo la base de pacientes.',
    gravedad: 'alta',
    sujeto: 'personal',
    parametro: 'eligibility_lookups_per_staff_day',
  },
}

export const TIPOS_ALERTA = Object.keys(TIPOS) as TipoAlerta[]

export const ROTULO_TIPO_ALERTA: Record<TipoAlerta, string> = Object.fromEntries(
  TIPOS_ALERTA.map((t) => [t, TIPOS[t].rotulo]),
) as Record<TipoAlerta, string>

/** Lo que comparte una cuenta con la otra, como lo manda la base. */
export type MotivoRelacion = 'dispositivo' | 'cedula' | 'nombre'

const MOTIVOS: readonly MotivoRelacion[] = ['dispositivo', 'cedula', 'nombre']

export const ROTULO_MOTIVO: Record<MotivoRelacion, string> = {
  dispositivo: 'el mismo teléfono',
  cedula: 'la misma cédula',
  nombre: 'el mismo nombre',
}

export type DetalleAlerta =
  | {
      tipo: 'cuenta_relacionada'
      otraPersona: string
      otroNombre: string | null
      motivos: MotivoRelacion[]
    }
  | {
      tipo: 'consumo_sobre_cupo'
      orden: number | null
      dia: string
      local: string | null
      /** Su parte, en financiamiento (financed). */
      monto: number
      /** Lo que ya ocupaba su cupo al financiar, en financiamiento (financed). */
      ocupado: number
      /** El límite de su nivel en ese momento. */
      limite: number | null
      nivel: number | null
      /** Por qué salta: pasó del cupo, o financió con una cuota vencida. */
      sobreCupo: boolean
      enMora: boolean
    }
  | {
      /** Las de H10: el detalle es libre y se lee campo a campo al describirla. */
      tipo: Exclude<TipoAlerta, 'cuenta_relacionada' | 'consumo_sobre_cupo'>
      datos: Record<string, unknown>
    }

export type Alerta = {
  clave: string
  tipo: TipoAlerta
  gravedad: Gravedad
  sujeto: { tipo: TipoSujeto; id: string; nombre: string | null }
  /** El paciente, si la alerta es de uno. */
  personaId: string | null
  nombre: string | null
  estadoPersona: string
  detectadaEn: string
  detalle: DetalleAlerta
  revisada: boolean
  revisadaEn: string | null
  revisadaPor: string | null
  nota: string | null
}

export type RecuentoAlertas = { total: number; pendientes: number; pendientesAltas: number }

export type Alertas = {
  businessDate: string
  ventanaDias: number
  recuentos: Record<TipoAlerta, RecuentoAlertas>
  /** Con el filtro de tipo, antes del tope. */
  total: number
  /** Había más de las que caben en el tope. */
  truncada: boolean
  filas: Alerta[]
}

function leerDetalle(tipo: TipoAlerta, raw: unknown): DetalleAlerta {
  const d = comoFila(raw)
  switch (tipo) {
    case 'cuenta_relacionada':
      return {
        tipo,
        otraPersona: String(d.other_user_id),
        otroNombre: textoONulo(d.other_name),
        motivos: textos(d.reasons).filter((m): m is MotivoRelacion => MOTIVOS.some((x) => x === m)),
      }
    case 'consumo_sobre_cupo': {
      const motivos = textos(d.reasons)
      return {
        tipo,
        orden: numeroONulo(d.order_number),
        dia: String(d.business_date),
        local: textoONulo(d.merchant_name),
        monto: Number(d.financed_usd ?? 0),
        ocupado: Number(d.used_usd ?? 0),
        limite: numeroONulo(d.limit_usd),
        nivel: numeroONulo(d.level),
        sobreCupo: motivos.includes('sobre_cupo'),
        enMora: motivos.includes('en_mora'),
      }
    }
    default:
      return { tipo, datos: d }
  }
}

function leerRecuento(raw: unknown): RecuentoAlertas {
  const f = comoFila(raw)
  return {
    total: Number(f.total ?? 0),
    pendientes: Number(f.unreviewed ?? 0),
    pendientesAltas: Number(f.unreviewed_high ?? 0),
  }
}

/** Una fila de la respuesta. `null` si trae un tipo que el panel no conoce. */
function leerAlerta(raw: unknown): Alerta | null {
  const f = comoFila(raw)
  const tipo = TIPOS_ALERTA.find((t) => t === f.kind)
  if (!tipo) return null
  // Las de siempre traen `user_id` y `full_name`; las de H10, `subject_*`.
  const sujetoTipo = SUJETOS.find((s) => s === f.subject_type) ?? TIPOS[tipo].sujeto
  const sujetoId = textoONulo(f.subject_id) ?? textoONulo(f.user_id) ?? ''
  const sujetoNombre = textoONulo(f.subject_name) ?? textoONulo(f.full_name)
  return {
    clave: String(f.alert_key),
    tipo,
    gravedad: f.severity === 'alta' ? 'alta' : f.severity === 'media' ? 'media' : TIPOS[tipo].gravedad,
    sujeto: { tipo: sujetoTipo, id: sujetoId, nombre: sujetoNombre },
    personaId: sujetoTipo === 'paciente' && sujetoId ? sujetoId : null,
    nombre: sujetoNombre,
    estadoPersona: String(f.user_status ?? ''),
    detectadaEn: textoONulo(f.first_seen_at) ?? texto(f.detected_at),
    detalle: leerDetalle(tipo, f.detail),
    revisada: f.reviewed === true,
    revisadaEn: textoONulo(f.reviewed_at),
    revisadaPor: textoONulo(f.reviewed_by_name),
    nota: textoONulo(f.review_note),
  }
}

/**
 * Cuántas alertas esperan, de `admin_risk_alert_counts`: la insignia del menú
 * y las cifras de Inicio. La base las calcula con `admin_risk_alerts`, así que
 * cuentan lo mismo que la pantalla, sin mandar las filas.
 */
export type RecuentoDeAlertas = {
  /** Sin revisar y de gravedad alta. */
  pendientesAltas: number
  /** Sin revisar y de gravedad media. */
  pendientesMedias: number
  revisadas: number
}

export function leerRecuentoDeAlertas(raw: unknown): RecuentoDeAlertas {
  const f = comoFila(raw)
  return {
    pendientesAltas: numero(f.pendientes_alta),
    pendientesMedias: numero(f.pendientes_media),
    revisadas: numero(f.revisadas),
  }
}

/** La respuesta de `admin_risk_alerts`, ya tipada. */
export function leerAlertas(raw: unknown): Alertas {
  const f = comoFila(raw)
  const counts = comoFila(f.counts)
  return {
    businessDate: textoONulo(f.business_date) ?? '',
    ventanaDias: Number(f.window_days ?? 0),
    recuentos: Object.fromEntries(TIPOS_ALERTA.map((t) => [t, leerRecuento(counts[t])])) as Record<
      TipoAlerta,
      RecuentoAlertas
    >,
    total: Number(f.total ?? 0),
    truncada: f.truncated === true,
    filas: comoLista(f.rows)
      .map(leerAlerta)
      .filter((a): a is Alerta => a !== null),
  }
}

// ── Leer una alerta ────────────────────────────────────────────────────────

function lista(partes: string[]): string {
  if (partes.length <= 1) return partes.join('')
  return `${partes.slice(0, -1).join(', ')} y ${partes.at(-1)}`
}

function veces(n: number | null, singular: string, plural: string): string {
  return n === null ? plural : `${n} ${n === 1 ? singular : plural}`
}

/**
 * Qué pasó, en una frase. Las de H10 leen su detalle campo a campo con
 * nombres razonables; si un campo no viene, la frase sale sin la cifra, nunca
 * con un «undefined».
 */
export function describirAlerta(d: DetalleAlerta): string {
  switch (d.tipo) {
    case 'cuenta_relacionada':
      return d.motivos.length > 0
        ? `Comparte ${lista(d.motivos.map((m) => ROTULO_MOTIVO[m]))} con otra cuenta.`
        : 'Comparte datos con otra cuenta.'
    case 'consumo_sobre_cupo': {
      // Su parte es financiamiento (financed): lo dice, para no leerse como una cuota.
      const consumo = `Se financió ${formatUsd(d.monto)} (sin fee)${d.local ? ` en ${d.local}` : ''} el ${formatDay(d.dia)}`
      const cupo =
        d.limite === null
          ? 'por encima de su cupo'
          : `con ${formatUsd(d.ocupado)} ya ocupados de un cupo de ${formatUsd(d.limite)}`
      if (d.sobreCupo && d.enMora) return `${consumo} ${cupo}, y con una cuota vencida.`
      if (d.enMora) return `${consumo} con una cuota vencida sin pagar.`
      return `${consumo} ${cupo}.`
    }
    default:
      return describirAlertaNueva(d.tipo, d.datos)
  }
}

function describirAlertaNueva(tipo: TipoAlerta, d: Record<string, unknown>): string {
  const n = (clave: string) => numeroONulo(d[clave])
  const t = (clave: string) => textoONulo(d[clave])
  const pacientes = n('patient_count') ?? n('profile_count') ?? n('count')
  const dia = t('business_date') ?? t('day')
  const elDia = dia ? ` el ${formatDay(dia)}` : ''
  const umbral = n('threshold')

  switch (tipo) {
    case 'telefono_repetido': {
      const tel = t('phone_e164') ?? t('phone')
      return `${tel ? `El teléfono ${formatPhone(tel)}` : 'Su teléfono'} está en ${veces(pacientes, 'paciente', 'pacientes')}.`
    }
    case 'correo_repetido':
      return `${t('email') ? `El correo ${t('email')}` : 'Su correo'} está en ${veces(pacientes, 'paciente', 'pacientes')}.`
    case 'correo_rebotado': {
      const orden = n('order_number')
      return `El comprobante${orden !== null ? ` del financiamiento #${orden}` : ''} rebotó${t('email') ? ` en ${t('email')}` : ''}: hay que corregir el correo y reenviarlo.`
    }
    case 'rafaga_de_altas':
      return `Registró ${veces(n('charge_count') ?? n('count'), 'financiamiento', 'financiamientos')}${elDia}${umbral !== null ? `; el umbral es ${umbral}` : ''}.`
    case 'rafaga_de_pacientes_nuevos':
      return `Dio de alta ${veces(n('new_patients') ?? n('count'), 'paciente nuevo', 'pacientes nuevos')}${elDia}${umbral !== null ? `; el umbral es ${umbral}` : ''}.`
    case 'secretaria_concentrada': {
      const pct = n('share_pct') ?? n('pct')
      const clinica = t('merchant_name')
      return `Registró ${pct !== null ? `el ${Math.round(pct)} %` : 'casi todos'} de los financiamientos de la semana${clinica ? ` de ${clinica}` : ''}.`
    }
    case 'impago_primera_cuota_clinica': {
      const pct = n('fpd_pct') ?? n('pct')
      const casos = n('cases') ?? n('case_count')
      return `${pct !== null ? `El ${Math.round(pct)} %` : 'Demasiados'} de sus pacientes no pagaron la primera cuota${casos !== null ? ` (${casos} casos)` : ''}.`
    }
    case 'exposicion_clinica': {
      const deuda = n('exposure_usd') ?? n('open_debt_usd') ?? n('amount_usd')
      return `La deuda viva de sus financiamientos es de ${deuda !== null ? formatUsd(deuda) : 'más del umbral'}${umbral !== null ? `, por encima de ${formatUsd(umbral)}` : ''}.`
    }
    case 'referencia_repetida': {
      const ref = t('reference')
      return `La referencia ${ref ?? 'de un pago'}${t('bank') ? ` de ${t('bank')}` : ''} aparece en pagos de ${veces(pacientes, 'paciente', 'pacientes distintos')}.`
    }
    case 'cupo_al_limite_al_estrenar': {
      const pct = n('used_pct') ?? n('pct')
      const monto = n('financed_usd')
      const limite = n('limit_usd')
      return `En su primer financiamiento usó ${pct !== null ? `el ${Math.round(pct)} %` : 'casi todo'} de su cupo${monto !== null && limite !== null ? ` (${formatUsd(monto)} de ${formatUsd(limite)})` : ''}.`
    }
    case 'consultas_de_cedula_excesivas':
      return `Hizo ${veces(n('lookups') ?? n('count'), 'consulta de cédula', 'consultas de cédula')}${elDia}${umbral !== null ? `; el límite es ${umbral}` : ''}.`
    default:
      return TIPOS[tipo].descripcion
  }
}

/**
 * La clínica a la que pertenece una alerta: la propia si es de una clínica,
 * o la del detalle (`merchant_id`) si es de alguien de su personal o de un
 * paciente registrado en ella.
 */
export function clinicaDeLaAlerta(a: Alerta): string | null {
  if (a.sujeto.tipo === 'clinica') return a.sujeto.id || null
  const d = a.detalle
  return 'datos' in d ? textoONulo(d.datos.merchant_id) : null
}

// ── Filtros ────────────────────────────────────────────────────────────────

export type EstadoRevision = 'pendientes' | 'revisadas' | 'todas'

export function filtrarAlertas(
  filas: readonly Alerta[],
  filtro: { gravedad?: Gravedad; estado: EstadoRevision },
): Alerta[] {
  return filas.filter(
    (a) =>
      (!filtro.gravedad || a.gravedad === filtro.gravedad) &&
      (filtro.estado === 'todas' || (filtro.estado === 'revisadas') === a.revisada),
  )
}

/** Las de una clínica: suyas, de su personal o con su id en el detalle. */
export function alertasDeLaClinica(filas: readonly Alerta[], merchantId: string): Alerta[] {
  return filas.filter((a) => clinicaDeLaAlerta(a) === merchantId)
}
