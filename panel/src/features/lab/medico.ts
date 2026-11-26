import { queryOptions, useQuery } from '@tanstack/react-query'

import { llamarRpc } from '@/features/admin/metricas/consulta'
import { extensionDelComprobante } from '@/features/admin/pagosRegistrados/registrarPago'
import { PASOS_MUESTRA } from '@/features/lab/tipos'
import type { EstadoMuestra, EstadoPago, KitTipo } from '@/features/lab/tipos'
import { booleano, comoFila, filas, numero, numeroONulo, texto, textoONulo } from '@/lib/json'
import { describeError, supabase } from '@/lib/supabase'

// ═══════════════════════════════════════════════════════════════════════════
// Helios Lab, lado del médico: lectura de las RPC de docs/09 §5.1, helpers de
// validación y errores en español. Todo en dólares; los bolívares solo se
// muestran en la cotización.
// ═══════════════════════════════════════════════════════════════════════════

export const BUCKET_LAB = 'lab-comprobantes'

// ── Tipos ─────────────────────────────────────────────────────────────────

export type AccesoLab = {
  habilitado: boolean
  modo: string | null
  rol: string | null
  cargoHeliosUsd: number
}

export type PrecioLab = {
  examenId: string
  codigo: string
  nombre: string
  kitTipo: KitTipo | null
  indicaciones: string | null
  laboratorioId: string
  laboratorioNombre: string
  baseUsd: number
  cargoHeliosUsd: number
  comisionUsd: number
  precioUsd: number
}

export type Cotizacion = {
  baseUsd: number
  cargoHeliosUsd: number
  comisionUsd: number
  precioUsd: number
  tasaBcv: number
  montoVes: number
  fechaTasa: string | null
}

export type MuestraRegistrada = {
  id: string
  codigo: string
  precioUsd: number
  montoVes: number
  tasaBcv: number
  pagoEstado: EstadoPago | null
  kitsRestantes: number | null
}

export type MuestraLab = {
  id: string
  codigo: string
  pacienteNombre: string
  examenNombre: string
  laboratorioNombre: string
  precioUsd: number
  estado: EstadoMuestra
  pagoEstado: EstadoPago | null
  creadaEn: string | null
  totalCount: number
}

export type KitLab = {
  kitTipo: KitTipo
  nombre: string
  enConsultorio: number
  pedidosPendientes: number
}

// ── Lectores ──────────────────────────────────────────────────────────────

const ESTADOS: readonly string[] = [...PASOS_MUESTRA, 'anulada']
const PAGOS: readonly string[] = ['por_leer', 'cuadra', 'para_revisar', 'verificado', 'rechazado']
const KIT_TIPOS: readonly string[] = ['sangre', 'orina', 'biopsia']

function kitDe(v: unknown): KitTipo | null {
  return typeof v === 'string' && KIT_TIPOS.includes(v) ? (v as KitTipo) : null
}

function pagoDe(v: unknown): EstadoPago | null {
  const p = texto(v)
  return PAGOS.includes(p) ? (p as EstadoPago) : null
}

export function leerAcceso(raw: unknown): AccesoLab {
  const f = comoFila(raw)
  return {
    habilitado: booleano(f.habilitado),
    modo: textoONulo(f.modo),
    rol: textoONulo(f.rol),
    cargoHeliosUsd: numero(f.cargo_helios_usd),
  }
}

function leerPrecio(f: Record<string, unknown>): PrecioLab {
  return {
    examenId: texto(f.examen_id),
    codigo: texto(f.codigo),
    nombre: texto(f.nombre),
    kitTipo: kitDe(f.kit_tipo),
    indicaciones: textoONulo(f.indicaciones),
    laboratorioId: texto(f.laboratorio_id),
    laboratorioNombre: texto(f.laboratorio_nombre),
    baseUsd: numero(f.base_usd),
    cargoHeliosUsd: numero(f.cargo_helios_usd),
    comisionUsd: numero(f.comision_usd),
    precioUsd: numero(f.precio_usd),
  }
}

function leerCotizacion(raw: unknown): Cotizacion {
  const f = comoFila(raw)
  return {
    baseUsd: numero(f.base_usd),
    cargoHeliosUsd: numero(f.cargo_helios_usd),
    comisionUsd: numero(f.comision_usd),
    precioUsd: numero(f.precio_usd),
    tasaBcv: numero(f.tasa_bcv),
    montoVes: numero(f.monto_ves),
    fechaTasa: textoONulo(f.fecha_tasa),
  }
}

function leerRegistrada(raw: unknown): MuestraRegistrada {
  const f = comoFila(raw)
  return {
    id: texto(f.id),
    codigo: texto(f.codigo),
    precioUsd: numero(f.precio_usd),
    montoVes: numero(f.monto_ves),
    tasaBcv: numero(f.tasa_bcv),
    pagoEstado: pagoDe(f.pago_estado),
    kitsRestantes: numeroONulo(f.kits_restantes),
  }
}

function leerMuestra(f: Record<string, unknown>): MuestraLab {
  const estado = texto(f.estado)
  return {
    id: texto(f.id),
    codigo: texto(f.codigo),
    pacienteNombre: texto(f.paciente_nombre),
    examenNombre: texto(f.examen_nombre ?? f.examen),
    laboratorioNombre: texto(f.laboratorio_nombre ?? f.laboratorio),
    precioUsd: numero(f.precio_usd),
    estado: ESTADOS.includes(estado) ? (estado as EstadoMuestra) : 'lista_para_retirar',
    pagoEstado: pagoDe(f.pago_estado),
    creadaEn: textoONulo(f.created_at ?? f.creada_en),
    totalCount: numero(f.total_count),
  }
}

function leerKit(f: Record<string, unknown>): KitLab | null {
  const tipo = kitDe(f.kit_tipo)
  if (!tipo) return null
  return {
    kitTipo: tipo,
    nombre: texto(f.nombre, tipo),
    enConsultorio: numero(f.en_consultorio),
    pedidosPendientes: numero(f.pedidos_pendientes),
  }
}

// ── Llamadas ──────────────────────────────────────────────────────────────

export const claveLab = {
  acceso: (m: string) => ['lab-medico', 'acceso', m] as const,
  precios: (m: string) => ['lab-medico', 'precios', m] as const,
  cotizacion: (m: string, e: string, l: string) => ['lab-medico', 'cotizacion', m, e, l] as const,
  muestras: (m: string, estado: string | null, q: string) => ['lab-medico', 'muestras', m, estado, q] as const,
  muestrasTodas: (m: string) => ['lab-medico', 'muestras', m] as const,
  kits: (m: string) => ['lab-medico', 'kits', m] as const,
}

export const accesoLabOptions = (merchantId: string) =>
  queryOptions({
    queryKey: claveLab.acceso(merchantId),
    queryFn: ({ signal }) =>
      llamarRpc('lab_mi_acceso', { p_merchant_id: merchantId }, { signal, leer: leerAcceso }),
    staleTime: 5 * 60_000,
    retry: false,
  })

/**
 * ¿Se le enseña Laboratorio a esta clínica? Mientras carga, o si la RPC no
 * existe o falla, no: el menú nunca promete lo que no hay.
 */
export function useLabHabilitado(merchantId: string | undefined): boolean {
  const q = useQuery({
    ...accesoLabOptions(merchantId ?? ''),
    enabled: !!merchantId,
  })
  return q.data?.habilitado === true
}

export const preciosLabOptions = (merchantId: string) =>
  queryOptions({
    queryKey: claveLab.precios(merchantId),
    queryFn: ({ signal }) =>
      llamarRpc('lab_precios', { p_merchant_id: merchantId }, { signal, leer: (r) => filas(r).map(leerPrecio) }),
  })

export const cotizacionLabOptions = (merchantId: string, examenId: string, laboratorioId: string) =>
  queryOptions({
    queryKey: claveLab.cotizacion(merchantId, examenId, laboratorioId),
    queryFn: ({ signal }) =>
      llamarRpc(
        'lab_muestra_cotizar',
        { p_merchant_id: merchantId, p_examen_id: examenId, p_laboratorio_id: laboratorioId },
        { signal, leer: leerCotizacion },
      ),
    staleTime: 60_000,
  })

export const muestrasLabOptions = (merchantId: string, estado: EstadoMuestra | null, busqueda: string) =>
  queryOptions({
    queryKey: claveLab.muestras(merchantId, estado, busqueda),
    queryFn: ({ signal }) =>
      llamarRpc(
        'lab_mis_muestras',
        {
          p_merchant_id: merchantId,
          p_estado: estado,
          p_busqueda: busqueda.trim() || null,
          p_limit: 100,
          p_offset: 0,
        },
        { signal, leer: (r) => filas(r).map(leerMuestra) },
      ),
  })

export const kitsLabOptions = (merchantId: string) =>
  queryOptions({
    queryKey: claveLab.kits(merchantId),
    queryFn: ({ signal }) =>
      llamarRpc(
        'lab_mis_kits',
        { p_merchant_id: merchantId },
        { signal, leer: (r) => filas(r).map(leerKit).filter((k): k is KitLab => k !== null) },
      ),
  })

export function fijarComision(params: { merchantId: string; examenId: string; comisionUsd: number }) {
  return llamarRpc('lab_comision_set', {
    p_merchant_id: params.merchantId,
    p_examen_id: params.examenId,
    p_comision_usd: params.comisionUsd,
  })
}

export type DatosDeMuestra = {
  merchantId: string
  examenId: string
  laboratorioId: string
  pacienteNombre: string
  pacienteWhatsapp: string
  pacienteCorreo: string
  pagoReferencia: string
  pagoBanco: string
  comprobantePath: string | null
  clave: string
}

export function registrarMuestra(d: DatosDeMuestra): Promise<MuestraRegistrada> {
  return llamarRpc(
    'lab_muestra_registrar',
    {
      p_merchant_id: d.merchantId,
      p_examen_id: d.examenId,
      p_laboratorio_id: d.laboratorioId,
      p_paciente_nombre: d.pacienteNombre.trim(),
      p_paciente_whatsapp: normalizarWhatsapp(d.pacienteWhatsapp),
      p_paciente_correo: d.pacienteCorreo.trim() || null,
      p_pago_referencia: d.pagoReferencia.replace(/\D/g, ''),
      p_pago_banco: d.pagoBanco.trim() || null,
      p_comprobante_path: d.comprobantePath,
      p_idempotency_key: d.clave,
    },
    { leer: leerRegistrada },
  )
}

export function anularMuestra(params: { merchantId: string; muestraId: string; motivo: string }) {
  return llamarRpc('lab_muestra_anular', {
    p_merchant_id: params.merchantId,
    p_muestra_id: params.muestraId,
    p_motivo: params.motivo.trim(),
  })
}

export function pedirKits(params: { merchantId: string; kitTipo: KitTipo; cantidad: number; nota: string }) {
  return llamarRpc('lab_kits_pedir', {
    p_merchant_id: params.merchantId,
    p_kit_tipo: params.kitTipo,
    p_cantidad: params.cantidad,
    p_nota: params.nota.trim() || null,
  })
}

/** Sube la captura a `lab-comprobantes/<clinica>/<uuid>.<ext>` y devuelve la ruta. */
export async function subirCapturaLab(params: { merchantId: string; file: File }): Promise<string> {
  const ext = extensionDelComprobante(params.file)
  if (!ext) throw new Error('La captura tiene que ser una imagen (JPG, PNG, WEBP) o un PDF.')
  const ruta = `${params.merchantId}/${crypto.randomUUID()}.${ext}`
  const { error } = await supabase.storage
    .from(BUCKET_LAB)
    .upload(ruta, params.file, { contentType: params.file.type || undefined, upsert: false })
  if (error) throw error
  return ruta
}

// ── Validación ────────────────────────────────────────────────────────────

/** Un WhatsApp venezolano escrito como sea a E.164 (`+584141234567`), o `null`. */
export function normalizarWhatsapp(valor: string): string | null {
  let digitos = valor.replace(/\D/g, '')
  if (digitos.startsWith('58')) digitos = digitos.slice(2)
  digitos = digitos.replace(/^0/, '')
  return /^4\d{9}$/.test(digitos) ? `+58${digitos}` : null
}

/** Referencia del Pago Móvil: de 4 a 20 dígitos. */
export function referenciaValida(valor: string): boolean {
  const n = valor.replace(/\D/g, '').length
  return n >= 4 && n <= 20
}

export function correoOpcionalValido(valor: string): boolean {
  const v = valor.trim()
  return v === '' || /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v)
}

export type CamposDeMuestra = {
  pacienteNombre: string
  pacienteWhatsapp: string
  pacienteCorreo: string
  pagoReferencia: string
}

export type ErroresDeMuestra = Partial<Record<keyof CamposDeMuestra, string>>

export function validarMuestra(c: CamposDeMuestra): ErroresDeMuestra {
  const e: ErroresDeMuestra = {}
  if (c.pacienteNombre.trim().length < 3) e.pacienteNombre = 'Escribe el nombre completo del paciente.'
  if (!normalizarWhatsapp(c.pacienteWhatsapp))
    e.pacienteWhatsapp = 'El WhatsApp no es válido. Usa el formato 0414 123 4567.'
  if (!correoOpcionalValido(c.pacienteCorreo)) e.pacienteCorreo = 'El correo no parece válido.'
  if (!referenciaValida(c.pagoReferencia)) e.pagoReferencia = 'La referencia lleva de 4 a 20 dígitos.'
  return e
}

// ── Errores ───────────────────────────────────────────────────────────────

/** El error de una RPC de Lab, en palabras de la clínica. */
export function explicarErrorLab(error: unknown): string {
  const crudo = describeError(error) ?? 'No se pudo completar. Intenta de nuevo.'
  const t = crudo.toLowerCase()
  if (/lab_mi_acceso|could not find the function|does not exist|schema cache/.test(t))
    return 'Laboratorio todavía no está disponible.'
  if (/42501|permission|permiso|not allowed/.test(t)) return 'No tienes permiso para hacer esto.'
  if (/whatsapp|e\.?164|tel[eé]fono/.test(t))
    return 'El WhatsApp del paciente no es válido. Usa el formato 0414 123 4567.'
  if (/referencia/.test(t)) return 'La referencia del pago no es válida: lleva de 4 a 20 dígitos.'
  if (/comprobante|ruta/.test(t)) return 'No se pudo asociar la captura del pago. Súbela de nuevo.'
  if (/precio/.test(t)) return 'Ese examen ya no tiene precio en ese laboratorio. Actualiza la lista.'
  if (/lista_para_retirar|estado/.test(t)) return 'La muestra ya no se puede anular: cambió de estado.'
  return crudo
}

// ── Presentación ──────────────────────────────────────────────────────────

/** El paso del recorrido en el que está la muestra (0 a 4), o -1 si está anulada. */
export function pasoDe(estado: EstadoMuestra): number {
  return PASOS_MUESTRA.indexOf(estado)
}
