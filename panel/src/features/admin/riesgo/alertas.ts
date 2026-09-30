import { formatDay, formatUsd } from '@/components/ui'
import type { BadgeTone } from '@/components/ui'
import { comoFila, comoLista, numero, numeroONulo, textoONulo, textos } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Las alertas de riesgo (`admin_risk_alerts`, 20260925201000).
//
// No se guardan: la base las deriva de los datos en cada llamada y solo guarda
// quién las revisó. Aquí se tipan, se describen en una frase y se filtran.
// ═══════════════════════════════════════════════════════════════════════════

export type TipoAlerta =
  | 'cuenta_relacionada'
  | 'consumo_sobre_cupo'

export const TIPOS_ALERTA: readonly TipoAlerta[] = [
  'cuenta_relacionada',
  'consumo_sobre_cupo',
]

export const ROTULO_TIPO_ALERTA: Record<TipoAlerta, string> = {
  cuenta_relacionada: 'Cuenta relacionada',
  consumo_sobre_cupo: 'Financiamiento por encima de su cupo',
}

export type Gravedad = 'alta' | 'media'
export const GRAVEDADES: readonly Gravedad[] = ['alta', 'media']

export const GRAVEDAD: Record<Gravedad, { rotulo: string; tono: BadgeTone }> = {
  alta: { rotulo: 'Alta', tono: 'error' },
  media: { rotulo: 'Media', tono: 'warning' },
}

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
      /** Su parte, en consumo (financed). */
      monto: number
      /** Lo que ya ocupaba su cupo al consumir, en consumo (financed). */
      ocupado: number
      /** El límite de su nivel en ese momento. */
      limite: number | null
      nivel: number | null
      /** Por qué salta: pasó del cupo, o consumió con una cuota vencida. */
      sobreCupo: boolean
      enMora: boolean
    }

export type Alerta = {
  clave: string
  tipo: TipoAlerta
  gravedad: Gravedad
  personaId: string
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
        motivos: textos(d.reasons).filter((m): m is MotivoRelacion =>
          MOTIVOS.some((x) => x === m),
        ),
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
  return {
    clave: String(f.alert_key),
    tipo,
    gravedad: f.severity === 'alta' ? 'alta' : 'media',
    personaId: String(f.user_id),
    nombre: textoONulo(f.full_name),
    estadoPersona: String(f.user_status ?? ''),
    detectadaEn: String(f.detected_at),
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
    recuentos: {
      cuenta_relacionada: leerRecuento(counts.cuenta_relacionada),
      consumo_sobre_cupo: leerRecuento(counts.consumo_sobre_cupo),
    },
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

/** Qué pasó, en una frase. El nombre de la otra cuenta va aparte, como enlace. */
export function describirAlerta(d: DetalleAlerta): string {
  switch (d.tipo) {
    case 'cuenta_relacionada':
      return d.motivos.length > 0
        ? `Comparte ${lista(d.motivos.map((m) => ROTULO_MOTIVO[m]))} con otra cuenta.`
        : 'Comparte datos con otra cuenta.'
    case 'consumo_sobre_cupo': {
      // Su parte es consumo (financed): lo dice, para no leerse como una cuota.
      const consumo = `Se financió ${formatUsd(d.monto)} (sin fee)${d.local ? ` en ${d.local}` : ''} el ${formatDay(d.dia)}`
      const cupo =
        d.limite === null
          ? 'por encima de su cupo'
          : `con ${formatUsd(d.ocupado)} ya ocupados de un cupo de ${formatUsd(d.limite)}`
      if (d.sobreCupo && d.enMora) return `${consumo} ${cupo}, y con una cuota vencida.`
      if (d.enMora) return `${consumo} con una cuota vencida sin pagar.`
      return `${consumo} ${cupo}.`
    }
  }
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
