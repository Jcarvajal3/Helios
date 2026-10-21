/**
 * El lector de comprobantes por WhatsApp (docs/03): el paciente manda la
 * captura de su pago (o escribe banco, teléfono y referencia) y el bot crea el
 * pago que antes tecleaba el equipo. Aquí se lee lo que hizo con cada una.
 * Lógica pura: las llamadas están en `lectorComprobantesApi.ts`.
 */
import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'
import { BANKS } from './banks'
import type { MetodoDelPaciente } from './pagosRegistrados/registrarPago'

export type ModoLector = 'apagado' | 'sombra' | 'activo'

/** `payment_receipt_reads.status`. */
export type EstadoLectura =
  | 'pendiente'
  | 'leyendo'
  | 'esperando_referencia'
  | 'esperando_aviso'
  | 'registrado'
  | 'duplicado'
  | 'para_el_equipo'
  | 'descartado'
  | 'sombra'

export type Lectura = {
  id: string
  tipo: 'captura' | 'datos'
  modo: 'sombra' | 'activo'
  estado: EstadoLectura
  /** Por qué fue al equipo, o en sombra lo que habría hecho. */
  motivo: string | null
  userId: string
  persona: string
  telefono: string
  rutaCaptura: string | null
  metodo: MetodoDelPaciente | null
  banco: string | null
  referencia: string | null
  montoVes: number | null
  pagadoEl: string | null
  telefonoPagador: string | null
  reportId: string | null
  modelo: string | null
  error: string | null
  llego: string
  decidida: string | null
}

export type RevisionLector = {
  modo: ModoLector
  topeDiario: number
  modoDesde: string | null
  modoPor: string | null
  /** Las que fueron al equipo en 7 días y aún sin pago registrado. */
  paraRevisar: number
  lecturas: Lectura[]
}

const ESTADOS: readonly EstadoLectura[] = [
  'pendiente',
  'leyendo',
  'esperando_referencia',
  'esperando_aviso',
  'registrado',
  'duplicado',
  'para_el_equipo',
  'descartado',
  'sombra',
]

export function modoDe(v: unknown): ModoLector {
  return v === 'sombra' || v === 'activo' ? v : 'apagado'
}

export function leerLectura(v: unknown): Lectura {
  const r = comoFila(v)
  const estado = ESTADOS.find((e) => e === r.status) ?? 'pendiente'
  const metodo = r.method === 'pago_movil' || r.method === 'transferencia' ? r.method : null
  return {
    id: String(r.id),
    tipo: r.kind === 'datos' ? 'datos' : 'captura',
    modo: r.mode === 'activo' ? 'activo' : 'sombra',
    estado,
    motivo: textoONulo(r.reason),
    userId: String(r.user_id),
    persona: textoONulo(r.user_name) ?? 'Sin nombre',
    telefono: String(r.phone ?? ''),
    rutaCaptura: textoONulo(r.receipt_path),
    metodo,
    banco: textoONulo(r.bank),
    referencia: textoONulo(r.reference),
    montoVes: numeroONulo(r.amount_ves),
    pagadoEl: textoONulo(r.paid_on),
    telefonoPagador: textoONulo(r.payer_phone),
    reportId: textoONulo(r.report_id),
    modelo: textoONulo(r.model),
    error: textoONulo(r.error),
    llego: String(r.created_at),
    decidida: textoONulo(r.decided_at),
  }
}

export function leerRevisionLector(v: unknown): RevisionLector {
  const r = comoFila(v)
  return {
    modo: modoDe(r.mode),
    topeDiario: numeroONulo(r.daily_cap) ?? 10,
    modoDesde: textoONulo(r.mode_updated_at),
    modoPor: textoONulo(r.mode_updated_by_name),
    paraRevisar: numeroONulo(r.para_revisar) ?? 0,
    lecturas: comoLista(r.reads).map(leerLectura),
  }
}

/** Lo que hizo con la lectura, para el equipo. */
export const ESTADO_DE_LA_LECTURA: Record<EstadoLectura, string> = {
  pendiente: 'Por leer',
  leyendo: 'Leyéndola',
  esperando_referencia: 'Pidió la referencia',
  esperando_aviso: 'Espera el SMS del BNC',
  registrado: 'Registró el pago',
  duplicado: 'Ya estaba registrado',
  para_el_equipo: 'Para el equipo',
  descartado: 'No es un comprobante',
  sombra: 'Sombra',
}

/** Por qué fue al equipo (o, en sombra, lo que habría hecho). */
export const MOTIVO_DE_LA_LECTURA: Record<string, string> = {
  monto_no_cuadra: 'El monto no salda cuotas completas',
  cuenta_ajena: 'Se pagó a otra cuenta',
  operacion_no_exitosa: 'La operación no salió exitosa',
  metodo_desconocido: 'No se sabe si fue Pago Móvil o transferencia',
  sin_monto: 'No se leyó el monto',
  fecha_fuera_de_rango: 'La fecha del pago está fuera de rango',
  no_es_comprobante: 'No es un comprobante',
  no_se_pudo_leer: 'No se pudo leer la captura',
  no_se_pudo_registrar: 'No se pudo registrar el pago',
  sin_referencia: 'No llegó la referencia',
  referencia_ilegible: 'La referencia escrita no se entendió',
  sin_aviso: 'No llegó el SMS del BNC en 24 h',
  varios: 'Encaja con más de un pago o aviso',
  duplicado: 'Ya estaba registrado',
  registraria: 'Habría registrado el pago',
  pediria_referencia: 'Habría pedido la referencia',
}

export function motivoDeLaLectura(m: string | null): string | null {
  return m === null ? null : (MOTIVO_DE_LA_LECTURA[m] ?? m)
}

/** Lo que leyó el bot, listo para el formulario de «Registrar pago». */
export type LoQueLeyo = {
  metodo: MetodoDelPaciente | null
  /** Solo si es un banco de la lista (el formulario no admite otros). */
  banco: string | null
  referencia: string
  /** AAAA-MM-DD, o null. */
  fecha: string | null
  /** Como se escribe a mano: «10624,18». */
  montoBs: string
  rutaCaptura: string | null
}

export function paraElFormulario(l: Lectura): LoQueLeyo {
  return {
    metodo: l.metodo,
    banco: BANKS.some((b) => b.name === l.banco) ? l.banco : null,
    referencia: l.referencia ?? '',
    fecha: l.pagadoEl,
    montoBs: l.montoVes === null ? '' : l.montoVes.toFixed(2).replace('.', ','),
    rutaCaptura: l.rutaCaptura,
  }
}
