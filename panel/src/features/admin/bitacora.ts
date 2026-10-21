import { formatDay, formatUsd } from '@/components/ui'
import {
  ACCION_VERBO,
  CANAL_GESTION,
  CLASE_DE_CUENTA,
  RESULTADO_GESTION,
  TIPO_ALERTA,
} from '@/features/admin/bitacoraAcciones'
import { destinoDe } from '@/features/admin/bitacoraDestino'
import type { DestinoBitacora } from '@/features/admin/bitacoraDestino'
import { estadoDePersona } from '@/features/admin/estados'
import type { AuditEntry } from '@/features/admin/ops'
import type { Parametro } from '@/features/admin/parametros'
import { formatValorParametro } from '@/features/admin/parametrosPantalla'

export {
  ACCION_VERBO,
  FILTROS_BITACORA,
  TEMAS_BITACORA,
  accionesDelTema,
} from '@/features/admin/bitacoraAcciones'
export { destinoDe, rotuloDeDestino } from '@/features/admin/bitacoraDestino'
export type { DestinoBitacora } from '@/features/admin/bitacoraDestino'

// ═══════════════════════════════════════════════════════════════════════════
// La bitácora, en español.
//
// La tabla guarda un código de acción (`payment.reconciled`) y un `detail` en
// jsonb con las claves que cada acción quiso guardar. Eso está bien para
// filtrar y es lo que hay que conservar; lo que no se puede es enseñarlo tal
// cual. Una línea que no se entiende no sirve de prueba de nada.
//
// Aquí se traduce: el verbo en pasado, los datos clave con su nombre y, cuando
// la acción cambió un valor, el antes y el después aparte. El vocabulario
// (verbos, temas, valores con nombre) vive en `bitacoraAcciones.ts` y a qué
// apunta cada línea, en `bitacoraDestino.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Cómo se llama cada clave del `detail` cuando se pinta. */
const CLAVE_LABEL: Record<string, string | undefined> = {
  amount_usd: 'monto',
  amount_ves: 'monto en bolívares',
  amount: 'monto',
  financed_usd: 'financiamiento (sin comisión)',
  pending_usd: 'quedaba a deber',
  installments: 'cuotas saldadas',
  late_fee_usd: 'cargo por atraso cobrado',
  late_fee_count: 'cuotas con cargo por atraso',
  days_late: 'días de atraso',
  partial: 'pago parcial',
  settlements: 'liquidaciones',
  has_receipt: 'con comprobante',
  paid_on: 'día del banco',
  reference: 'referencia',
  bank: 'banco',
  bank_name: 'banco',
  holder_name: 'titular',
  rif: 'RIF',
  method: 'medio',
  channel: 'canal',
  outcome: 'resultado',
  promise_date: 'fecha prometida',
  next_action_on: 'próxima acción',
  template: 'plantilla',
  approve: 'resultado',
  approved: 'resultado',
  status: 'estado',
  user_status: 'estado de la cuenta',
  level: 'nivel',
  sequence: 'cuota',
  merchant_name: 'local',
  full_name: 'persona',
  name: 'nombre',
  kind: 'tipo',
  key: 'parámetro',
  value: 'valor',
  effective_from: 'desde',
  effective_date: 'vigencia',
  version: 'versión',
  summary: 'qué cambia',
  require_mfa: 'segundo factor',
  waited_hours: 'horas esperando',
  phone: 'teléfono',
  document: 'cédula',
  business_date: 'día operativo',
  due_date: 'vencimiento',
  day: 'día',
  rate: 'tasa',
  fx_rate: 'tasa',
  role: 'rol',
  email: 'correo',
  count: 'registros',
  lines: 'movimientos',
  inserted: 'nuevos',
  duplicates: 'ya estaban',
  deposits: 'abonos',
  rows_read: 'filas leídas',
  file_name: 'archivo',
  platform: 'plataforma',
  min_build: 'versión mínima',
  latest_build: 'última publicada',
  is_active: 'encendido',
  blocks_balance: 'saldo apagado',
  is_test: 'de prueba',
  title: 'título',
  audience: 'público',
  people: 'personas',
  devices: 'teléfonos',
  flag: 'marca',
  message: 'mensaje',
  monthly_limit_usd: 'límite',
  label: 'rótulo',
  // Lo que guarda una pregunta al asistente (admin_assistant_log).
  question: 'pregunta',
  tools: 'consultas',
  model: 'modelo',
  input_tokens: 'tokens de entrada',
  output_tokens: 'tokens de salida',
}

/** Claves que no aportan nada al leer: identificadores internos. */
const CLAVE_OCULTA = /(^|_)(id|ids|uuid|key)$/

/** `ok` solo dice que la función terminó. Eso no es un dato de nada. */
const CLAVE_MUDA = new Set(['ok'])

/** Claves que son el motivo de la acción: van aparte, en su columna. */
const CLAVE_MOTIVO = new Set(['note', 'reason', 'rejection_reason'])

/** Claves cuyo cero es ruido: un pago sin cargo por atraso no dice «0 €». */
const CERO_ES_NADA = new Set(['late_fee_usd', 'late_fee_count'])

/**
 * Lo que una acción guarda y no se enseña. Revertir un consumo guarda también
 * el monto con la Comisión Helios dentro, y un consumo se lee sin la comisión: se
 * enseña `financed_usd`.
 */
const OCULTAS_POR_ACCION: Record<string, ReadonlySet<string> | undefined> = {
  'charge.reverted': new Set(['amount_usd', 'payable_usd']),
}

/** Pares antes/después que las acciones guardan con distintos nombres. */
const PREFIJOS_ANTES = ['from_', 'previous_', 'old_', 'before_']
const PREFIJOS_DESPUES = ['to_', 'new_', 'after_']

/** Claves que son un día (`date`) y se leen como tal. */
function esDia(clave: string): boolean {
  return /(_date|_on|_from)$/.test(clave) || clave === 'day'
}

export type LineaBitacora = {
  /** "Javier aprobó un pago reportado". */
  frase: string
  /** Los datos clave, ya con nombre y formato. */
  datos: Array<{ label: string; valor: string }>
  /** El cambio de valor, si la acción cambió uno, y el nombre de lo que cambió. */
  cambio: { antes: string; despues: string; campo: string | null } | null
  /** El motivo, cuando la acción lo pidió. */
  motivo: string | null
  /** Lo que afectó la acción: su ficha o su sección, si la hay. */
  destino: DestinoBitacora | null
}

/** Lo que la bitácora sabe de fuera: el rótulo y la unidad de cada parámetro. */
export type ContextoBitacora = {
  parametros?: ReadonlyArray<Pick<Parametro, 'key' | 'label' | 'unit'>>
}

export function describirEvento(entry: AuditEntry, contexto: ContextoBitacora = {}): LineaBitacora {
  const quien = entry.actorName ?? (entry.actor ? 'Alguien del equipo' : 'El sistema')
  const verbo = ACCION_VERBO[entry.action] ?? legibleDesdeCodigo(entry.action)
  const destino = destinoDe(entry)
  const ocultas = OCULTAS_POR_ACCION[entry.action]

  // Un cambio de parámetro se lee con el rótulo y la unidad del parámetro, y
  // un cambio de estado de una cuenta, con el nombre del estado.
  const parametro =
    entry.action === 'parameter.set'
      ? contexto.parametros?.find((p) => p.key === entry.detail.key)
      : undefined
  const formatear = (clave: string, valor: unknown): string => {
    const esValor = clave === 'value' || clave === 'to_value' || clave === 'from_value'
    if (parametro && esValor && typeof valor === 'number') {
      return formatValorParametro(valor, parametro.unit)
    }
    if (typeof valor === 'string' && (clave === 'user_status' || (esValor && entry.action === 'user.set_status'))) {
      return estadoDePersona(valor).label
    }
    return formatearValor(clave, valor)
  }

  const datos: LineaBitacora['datos'] = []
  let motivo: string | null = null
  const antes = new Map<string, string>()
  const despues = new Map<string, string>()

  for (const [clave, valorCrudo] of aplanar(entry.detail)) {
    if (valorCrudo === null || valorCrudo === '' || valorCrudo === undefined) continue
    if (CLAVE_MUDA.has(clave) || ocultas?.has(clave)) continue
    if (CERO_ES_NADA.has(clave) && valorCrudo === 0) continue
    // El nombre que ya lleva el enlace no se repite en los datos.
    if (destino && 'claveNombre' in destino && destino.claveNombre === clave) continue

    const prefijoAntes = PREFIJOS_ANTES.find((p) => clave.startsWith(p))
    if (prefijoAntes) {
      antes.set(clave.slice(prefijoAntes.length), formatear(clave, valorCrudo))
      continue
    }

    const prefijoDespues = PREFIJOS_DESPUES.find((p) => clave.startsWith(p))
    if (prefijoDespues) {
      despues.set(clave.slice(prefijoDespues.length), formatear(clave, valorCrudo))
      continue
    }

    if (CLAVE_MOTIVO.has(clave)) {
      motivo = formatearValor(clave, valorCrudo)
      continue
    }

    if (CLAVE_OCULTA.test(clave) && clave !== 'key') continue

    const valor =
      clave === 'key' && parametro?.label ? parametro.label : formatear(clave, valorCrudo)
    datos.push({ label: etiquetaDe(entry.action, clave), valor })
  }

  // El cambio es el primer campo que de verdad cambió. Los demás que también
  // cambiaron van a los datos; los que se quedaron igual no dicen nada.
  const campos = [...new Set([...despues.keys(), ...antes.keys()])]
  const cambiados = campos.filter((c) => antes.get(c) !== despues.get(c))
  const primero = cambiados.at(0)
  const cambio =
    primero === undefined
      ? null
      : {
          antes: antes.get(primero) ?? '—',
          despues: despues.get(primero) ?? '—',
          // `value` es el valor de la propia acción (el parámetro, el estado):
          // nombrarlo no añade nada.
          campo: primero === 'value' ? null : etiquetaDe(entry.action, primero),
        }
  for (const campo of cambiados.slice(1)) {
    datos.push({
      label: etiquetaDe(entry.action, campo),
      valor: `${antes.get(campo) ?? '—'} → ${despues.get(campo) ?? '—'}`,
    })
  }

  return { frase: `${quien} ${verbo}`, datos, cambio, motivo, destino }
}

/**
 * Las claves del `detail`, con las anidadas subidas un nivel.
 *
 *   · `result`: varias acciones guardan ahí lo que devolvió la función, y ahí
 *     están los datos del hecho. Su `status` no sube: es el verbo otra vez.
 *   · `before` / `after`: el mantenimiento, la versión de la app y los niveles
 *     guardan el antes y el después como objetos; el estado y el nivel de una
 *     persona, como valores sueltos. Los dos se convierten en pares
 *     `from_x` / `to_x`.
 *   · La tasa a mano guarda `rate` y `previous`: son el después y el antes.
 */
function aplanar(detail: Record<string, unknown>): Array<[string, unknown]> {
  const salida: Array<[string, unknown]> = []
  const tasaConAnterior = 'previous' in detail && 'rate' in detail

  for (const [clave, valor] of Object.entries(detail)) {
    if (clave === 'result' && esObjeto(valor)) {
      for (const [interna, interno] of Object.entries(valor)) {
        if (interna === 'status') continue
        salida.push([interna, interno])
      }
      continue
    }

    if (clave === 'before' || clave === 'after') {
      const prefijo = clave === 'before' ? 'from_' : 'to_'
      if (esObjeto(valor)) {
        for (const [interna, interno] of Object.entries(valor)) {
          salida.push([`${prefijo}${interna}`, interno])
        }
      } else {
        salida.push([`${prefijo}value`, valor])
      }
      continue
    }

    if (tasaConAnterior && (clave === 'rate' || clave === 'previous')) {
      salida.push([clave === 'rate' ? 'to_rate' : 'from_rate', valor])
      continue
    }

    salida.push([clave, valor])
  }

  return salida
}

function esObjeto(valor: unknown): valor is Record<string, unknown> {
  return typeof valor === 'object' && valor !== null && !Array.isArray(valor)
}

/**
 * El nombre de una clave en los datos. `key` es el parámetro en un cambio de
 * parámetro y la plantilla en un aviso: la misma clave, dos cosas.
 */
function etiquetaDe(accion: string, clave: string): string {
  if (clave === 'key' && accion.startsWith('notification.')) return 'aviso'
  return CLAVE_LABEL[clave] ?? legibleDesdeCodigo(clave)
}

/** `user.set_blacklist` → "user set blacklist". El último recurso. */
function legibleDesdeCodigo(code: string): string {
  return code.replace(/[._]/g, ' ')
}

/** El nombre de los valores que guardan algunas claves. */
function valorConNombre(clave: string, valor: string): string | undefined {
  if (clave === 'outcome') return RESULTADO_GESTION[valor]
  if (clave === 'channel') return CANAL_GESTION[valor]
  if (clave === 'kind') return TIPO_ALERTA[valor] ?? CLASE_DE_CUENTA[valor]
  return undefined
}

function formatearValor(clave: string, valor: unknown): string {
  if (typeof valor === 'boolean') {
    if (clave === 'approve' || clave === 'approved') return valor ? 'aprobado' : 'rechazado'
    return valor ? 'sí' : 'no'
  }

  if (Array.isArray(valor)) return String(valor.length)

  if (typeof valor === 'number') {
    if (clave.endsWith('_usd') || clave === 'amount') return formatUsd(valor)
    const cifra = valor.toLocaleString('es-VE', { maximumFractionDigits: 4 })
    return clave.endsWith('_pct') ? `${cifra} %` : cifra
  }

  if (typeof valor === 'object' && valor !== null) return JSON.stringify(valor)

  const texto = String(valor)
  if (esDia(clave) && /^\d{4}-\d{2}-\d{2}$/.test(texto)) return formatDay(texto)
  return valorConNombre(clave, texto) ?? texto
}
