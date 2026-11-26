/**
 * Helios Lab — lo que lee y escribe el equipo (RPC `admin_lab_*`,
 * docs/09-HELIOS-LAB.md §5.2).
 *
 * Los lectores son tolerantes: la base manda `jsonb` y aquí se mira campo a
 * campo (`@/lib/json`). Un dato que falta se queda en `null`, nunca en cero.
 */
import { keepPreviousData, queryOptions } from '@tanstack/react-query'

import { whatsappNumber } from '@/components/ui'
import { llamarRpc } from '@/features/admin/metricas/consulta'
import { booleano, comoFila, comoLista, filas, numero, numeroONulo, texto, textoONulo } from '@/lib/json'
import { describeError, supabase } from '@/lib/supabase'
import { KITS, ROTULO_ESTADO, ROTULO_PAGO } from './tipos'
import type { CanalResultado, EstadoMuestra, EstadoPago, KitTipo, ModoLab } from './tipos'

export const CLAVE_LAB = ['lab-admin'] as const

export const BUCKET_LAB = 'lab-comprobantes'

export const SOLO_SUPER_ADMIN_LAB = 'Solo el super admin puede hacer esto'

// ── Errores ───────────────────────────────────────────────────────────────

/** El error de una RPC, en castellano y sin códigos sueltos. */
export function mensajeDeError(error: unknown): string {
  const e = typeof error === 'object' && error !== null ? (error as { code?: string; message?: string }) : {}
  if (e.code === '42501') return 'No tienes permiso para hacer esto. Pídeselo a un super admin.'
  if (e.code === 'P0002') return 'Ya no existe: puede que otra persona lo haya cambiado. Actualiza la pantalla.'
  if (e.code === '22023' && e.message) return e.message
  return describeError(error) ?? 'Algo salió mal. Vuelve a intentarlo.'
}

// ── Lectores de valores cerrados ──────────────────────────────────────────

function unoDeLista<T extends string>(valores: readonly T[], v: unknown): T | null {
  return valores.find((x) => x === v) ?? null
}

const ESTADOS = Object.keys(ROTULO_ESTADO) as EstadoMuestra[]
const PAGOS = Object.keys(ROTULO_PAGO) as EstadoPago[]
export const MODOS: readonly ModoLab[] = ['apagado', 'prueba', 'todos']

export function leerEstado(v: unknown): EstadoMuestra {
  return unoDeLista(ESTADOS, v) ?? 'lista_para_retirar'
}
export function leerPago(v: unknown): EstadoPago {
  return unoDeLista(PAGOS, v) ?? 'para_revisar'
}
export function leerKit(v: unknown): KitTipo | null {
  return unoDeLista(KITS, v)
}
function leerModo(v: unknown): ModoLab {
  return unoDeLista(MODOS, v) ?? 'apagado'
}

// ── Tipos ─────────────────────────────────────────────────────────────────

export type ResumenLab = {
  porEstado: Partial<Record<EstadoMuestra, number>>
  pagosPorRevisar: number
  kits: Array<{ tipo: KitTipo; stockHelios: number; minimo: number; enMedicos: number }>
  gananciaHoyUsd: number
  gananciaMesUsd: number
  muestrasHoy: number
}

export type AjustesLab = {
  modo: ModoLab
  cargoHeliosUsd: number
  clinicasDePrueba: number
  updatedAt: string | null
}

export type Laboratorio = {
  id: string
  nombre: string
  correo: string | null
  telefono: string | null
  direccion: string | null
  activo: boolean
}

export type PrecioExamen = {
  laboratorioId: string
  baseUsd: number
  activo: boolean
}

export type Examen = {
  id: string
  codigo: string
  nombre: string
  kitTipo: KitTipo | null
  indicaciones: string | null
  activo: boolean
  precios: PrecioExamen[]
}

/** Lo que dijo el lector de comprobantes sobre la captura. */
export type LecturaPago = {
  estado: string | null
  cuadra: boolean | null
  montoVes: number | null
  referencia: string | null
  banco: string | null
  fecha: string | null
  error: string | null
}

export type MuestraFila = {
  id: string
  codigo: string
  creada: string | null
  merchantId: string | null
  medico: string
  paciente: string
  pacienteWhatsapp: string | null
  pacienteCorreo: string | null
  examen: string
  laboratorio: string
  baseUsd: number
  cargoUsd: number
  comisionUsd: number
  precioUsd: number
  montoVes: number | null
  tasaBcv: number | null
  estado: EstadoMuestra
  pagoEstado: EstadoPago
  pagoReferencia: string | null
  pagoBanco: string | null
  pagoNota: string | null
  comprobantePath: string | null
  lectura: LecturaPago | null
  total: number
}

export type PasoHistoria = { cuando: string | null; texto: string; quien: string | null }

export type DetalleMuestra = {
  muestra: MuestraFila
  motivoAnulada: string | null
  canalResultado: CanalResultado | null
  pasos: PasoHistoria[]
  historia: PasoHistoria[]
}

export type FilaGanancia = {
  id: string
  codigo: string
  fecha: string | null
  medico: string
  examen: string
  laboratorio: string
  cobradoUsd: number
  baseUsd: number
  comisionUsd: number
  cargoUsd: number
}

export type Ganancia = {
  muestras: number
  cobradoUsd: number
  baseUsd: number
  comisionUsd: number
  cargoUsd: number
  filas: FilaGanancia[]
}

export type PorPagarMedico = {
  merchantId: string
  medico: string
  comisionUsd: number
  muestraIds: string[]
  muestras: number
}

export type PorPagarLaboratorio = {
  laboratorioId: string
  nombre: string
  baseUsd: number
  muestraIds: string[]
  muestras: number
}

export type PorPagar = { medicos: PorPagarMedico[]; laboratorios: PorPagarLaboratorio[] }

// ── Lectores ──────────────────────────────────────────────────────────────

export function leerResumen(crudo: unknown): ResumenLab {
  const r = comoFila(crudo)
  const porEstado: Partial<Record<EstadoMuestra, number>> = {}
  const origen = comoFila(r.muestras_por_estado)
  for (const e of ESTADOS) if (origen[e] !== undefined) porEstado[e] = numero(origen[e])
  const kits = filas(r.kits).flatMap((k) => {
    const tipo = leerKit(k.tipo ?? k.kit_tipo)
    return tipo
      ? [
          {
            tipo,
            stockHelios: numero(k.stock_helios),
            minimo: numero(k.minimo ?? k.minimo_helios),
            enMedicos: numero(k.en_medicos),
          },
        ]
      : []
  })
  return {
    porEstado,
    pagosPorRevisar: numero(r.pagos_por_revisar),
    kits,
    gananciaHoyUsd: numero(r.ganancia_hoy_usd),
    gananciaMesUsd: numero(r.ganancia_mes_usd),
    muestrasHoy: numero(r.muestras_hoy),
  }
}

export function leerAjustes(crudo: unknown): AjustesLab {
  const r = comoFila(crudo)
  return {
    modo: leerModo(r.modo),
    cargoHeliosUsd: numero(r.cargo_helios_usd),
    clinicasDePrueba: numero(r.clinicas_de_prueba),
    updatedAt: textoONulo(r.updated_at),
  }
}

export function leerLaboratorio(crudo: unknown): Laboratorio {
  const r = comoFila(crudo)
  return {
    id: texto(r.id),
    nombre: texto(r.nombre),
    correo: textoONulo(r.correo),
    telefono: textoONulo(r.telefono),
    direccion: textoONulo(r.direccion),
    activo: r.activo === undefined ? true : booleano(r.activo),
  }
}

export function leerExamen(crudo: unknown): Examen {
  const r = comoFila(crudo)
  return {
    id: texto(r.id),
    codigo: texto(r.codigo),
    nombre: texto(r.nombre),
    kitTipo: leerKit(r.kit_tipo),
    indicaciones: textoONulo(r.indicaciones),
    activo: r.activo === undefined ? true : booleano(r.activo),
    precios: filas(r.precios).map((p) => ({
      laboratorioId: texto(p.laboratorio_id),
      baseUsd: numero(p.base_usd),
      activo: p.activo === undefined ? true : booleano(p.activo),
    })),
  }
}

export function leerLectura(crudo: unknown): LecturaPago | null {
  if (typeof crudo !== 'object' || crudo === null) return null
  const r = comoFila(crudo)
  // La lectura del lector puede venir anidada en `lectura`.
  const l = typeof r.lectura === 'object' && r.lectura !== null ? comoFila(r.lectura) : r
  const cuadra = r.cuadra ?? l.cuadra
  return {
    estado: textoONulo(r.status ?? r.estado),
    cuadra: typeof cuadra === 'boolean' ? cuadra : null,
    montoVes: numeroONulo(l.monto_ves ?? l.monto ?? l.amount_ves),
    referencia: textoONulo(l.referencia ?? l.reference),
    banco: textoONulo(l.banco ?? l.bank),
    fecha: textoONulo(l.fecha ?? l.date),
    error: textoONulo(r.error),
  }
}

export function leerMuestra(crudo: unknown): MuestraFila {
  const r = comoFila(crudo)
  const lectura = leerLectura(r.lectura ?? r.comprobante_lectura ?? null)
  return {
    id: texto(r.id),
    codigo: texto(r.codigo),
    creada: textoONulo(r.created_at ?? r.creada),
    merchantId: textoONulo(r.merchant_id),
    medico: texto(r.medico, '—'),
    paciente: texto(r.paciente_nombre ?? r.paciente, '—'),
    pacienteWhatsapp: textoONulo(r.paciente_whatsapp),
    pacienteCorreo: textoONulo(r.paciente_correo),
    examen: texto(r.examen ?? r.examen_nombre, '—'),
    laboratorio: texto(r.laboratorio ?? r.laboratorio_nombre, '—'),
    baseUsd: numero(r.base_usd),
    cargoUsd: numero(r.cargo_helios_usd),
    comisionUsd: numero(r.comision_usd),
    precioUsd: numero(r.precio_usd),
    montoVes: numeroONulo(r.monto_ves),
    tasaBcv: numeroONulo(r.tasa_bcv),
    estado: leerEstado(r.estado),
    pagoEstado: leerPago(r.pago_estado),
    pagoReferencia: textoONulo(r.pago_referencia),
    pagoBanco: textoONulo(r.pago_banco),
    pagoNota: textoONulo(r.pago_nota),
    comprobantePath: textoONulo(r.comprobante_path),
    lectura,
    total: numero(r.total_count),
  }
}

const ROTULO_ACCION: Record<string, string> = {
  'lab.muestra_estado': 'Cambio de estado',
  'lab.pago_revisar': 'Revisión del pago',
  'lab.pagos_confirmar': 'Pago confirmado',
  'lab.marcar_pagado': 'Marcada como pagada',
  'lab.parada_completar': 'Parada completada',
}

function leerHistoria(v: unknown): PasoHistoria[] {
  return filas(v).map((h) => {
    const accion = textoONulo(h.accion ?? h.action)
    const base = accion ? (ROTULO_ACCION[accion] ?? accion) : texto(h.texto ?? h.detalle, '—')
    const nota = textoONulo(h.nota)
    return {
      cuando: textoONulo(h.created_at ?? h.at ?? h.cuando),
      texto: nota ? `${base}: ${nota}` : base,
      quien: textoONulo(h.actor_nombre ?? h.actor ?? h.quien),
    }
  })
}

/** Los pasos que la propia muestra guarda con su fecha, en orden de recorrido. */
function pasosDeLaMuestra(r: Record<string, unknown>): PasoHistoria[] {
  const marcas: Array<[string, string]> = [
    ['created_at', 'Registrada por el médico'],
    ['retirada_at', ROTULO_ESTADO.retirada],
    ['en_laboratorio_at', ROTULO_ESTADO.en_laboratorio],
    ['resultado_recibido_at', ROTULO_ESTADO.resultado_recibido],
    ['resultado_entregado_at', ROTULO_ESTADO.resultado_entregado],
    ['anulada_at', ROTULO_ESTADO.anulada],
  ]
  return marcas.flatMap(([campo, rotulo]) => {
    const cuando = textoONulo(r[campo])
    return cuando ? [{ cuando, texto: rotulo, quien: null }] : []
  })
}

export function leerDetalle(crudo: unknown): DetalleMuestra {
  const raiz = comoFila(crudo)
  const m = comoFila(raiz.muestra ?? raiz)
  const muestra = leerMuestra({ ...m, lectura: m.lectura ?? raiz.lectura ?? raiz.comprobante_lectura })
  const canal = m.resultado_canal
  return {
    muestra,
    motivoAnulada: textoONulo(m.anulada_motivo),
    canalResultado: canal === 'correo' || canal === 'whatsapp' ? canal : null,
    pasos: pasosDeLaMuestra(m),
    historia: leerHistoria(raiz.historia ?? raiz.auditoria),
  }
}

export function leerGanancia(crudo: unknown): Ganancia {
  const r = comoFila(crudo)
  const t = comoFila(r.totales)
  return {
    muestras: numero(t.muestras),
    cobradoUsd: numero(t.cobrado_usd),
    baseUsd: numero(t.base_usd),
    comisionUsd: numero(t.comision_usd),
    cargoUsd: numero(t.cargo_helios_usd),
    filas: filas(r.filas).map((f) => ({
      id: texto(f.id ?? f.muestra_id),
      codigo: texto(f.codigo, '—'),
      fecha: textoONulo(f.fecha ?? f.created_at),
      medico: texto(f.medico, '—'),
      examen: texto(f.examen, '—'),
      laboratorio: texto(f.laboratorio, '—'),
      cobradoUsd: numero(f.cobrado_usd ?? f.precio_usd),
      baseUsd: numero(f.base_usd),
      comisionUsd: numero(f.comision_usd),
      cargoUsd: numero(f.cargo_helios_usd),
    })),
  }
}

/**
 * Los ids de las muestras de un grupo «por pagar». Se aceptan `muestra_ids`,
 * `ids` o `muestras` como lista (de ids o de objetos con `id`); si `muestras`
 * es solo un número, no hay ids y el grupo no se puede marcar.
 */
function idsDelGrupo(f: Record<string, unknown>): string[] {
  const lista = comoLista(f.muestra_ids ?? f.ids ?? f.muestras)
  return lista.flatMap((x) => {
    if (typeof x === 'string') return [x]
    const id = textoONulo(comoFila(x).id)
    return id ? [id] : []
  })
}

function cuantas(f: Record<string, unknown>, ids: string[]): number {
  return Array.isArray(f.muestras) ? f.muestras.length : (numeroONulo(f.muestras) ?? ids.length)
}

export function leerPorPagar(crudo: unknown): PorPagar {
  const r = comoFila(crudo)
  return {
    medicos: filas(r.medicos).map((f) => {
      const ids = idsDelGrupo(f)
      return {
        merchantId: texto(f.merchant_id),
        medico: texto(f.medico, '—'),
        comisionUsd: numero(f.comision_usd),
        muestraIds: ids,
        muestras: cuantas(f, ids),
      }
    }),
    laboratorios: filas(r.laboratorios).map((f) => {
      const ids = idsDelGrupo(f)
      return {
        laboratorioId: texto(f.laboratorio_id),
        nombre: texto(f.nombre, '—'),
        baseUsd: numero(f.base_usd),
        muestraIds: ids,
        muestras: cuantas(f, ids),
      }
    }),
  }
}

// ── Lecturas ──────────────────────────────────────────────────────────────

export type FiltroMuestras = {
  estado?: EstadoMuestra
  /** Uno o varios estados de pago (la cola de cobros pide tres). */
  pago?: EstadoPago
  medico?: string
  desde?: string
  hasta?: string
  q?: string
  /** Desde 1. */
  pagina?: number
  porPagina?: number
}

export const POR_PAGINA = 25

export function listarMuestras(f: FiltroMuestras, signal?: AbortSignal): Promise<MuestraFila[]> {
  const porPagina = f.porPagina ?? POR_PAGINA
  return llamarRpc(
    'admin_lab_muestras',
    {
      p_estado: f.estado ?? null,
      p_pago_estado: f.pago ?? null,
      p_merchant_id: f.medico ?? null,
      p_desde: f.desde ?? null,
      p_hasta: f.hasta ?? null,
      p_busqueda: f.q ?? null,
      p_limit: porPagina,
      p_offset: ((f.pagina ?? 1) - 1) * porPagina,
    },
    { signal, leer: (c) => filas(c).map(leerMuestra) },
  )
}

export function consultaMuestras(f: FiltroMuestras) {
  return queryOptions({
    queryKey: [...CLAVE_LAB, 'muestras', f],
    queryFn: ({ signal }) => listarMuestras(f, signal),
    placeholderData: keepPreviousData,
    staleTime: 15_000,
  })
}

export function consultaMuestra(id: string) {
  return queryOptions({
    queryKey: [...CLAVE_LAB, 'muestra', id],
    queryFn: ({ signal }) => llamarRpc('admin_lab_muestra', { p_id: id }, { signal, leer: leerDetalle }),
    staleTime: 10_000,
  })
}

export function consultaResumen() {
  return queryOptions({
    queryKey: [...CLAVE_LAB, 'resumen'],
    queryFn: ({ signal }) => llamarRpc('admin_lab_resumen', undefined, { signal, leer: leerResumen }),
    refetchInterval: 60_000,
    staleTime: 20_000,
  })
}

export function consultaAjustes() {
  return queryOptions({
    queryKey: [...CLAVE_LAB, 'ajustes'],
    queryFn: ({ signal }) => llamarRpc('admin_lab_ajustes_get', undefined, { signal, leer: leerAjustes }),
    staleTime: 20_000,
  })
}

export function consultaLaboratorios() {
  return queryOptions({
    queryKey: [...CLAVE_LAB, 'laboratorios'],
    queryFn: ({ signal }) =>
      llamarRpc('admin_lab_laboratorios', undefined, { signal, leer: (c) => filas(c).map(leerLaboratorio) }),
    staleTime: 30_000,
  })
}

export function consultaExamenes() {
  return queryOptions({
    queryKey: [...CLAVE_LAB, 'examenes'],
    queryFn: ({ signal }) =>
      llamarRpc('admin_lab_examenes', undefined, { signal, leer: (c) => filas(c).map(leerExamen) }),
    staleTime: 30_000,
  })
}

export function consultaGanancia(desde: string, hasta: string) {
  return queryOptions({
    queryKey: [...CLAVE_LAB, 'ganancia', desde, hasta],
    queryFn: ({ signal }) =>
      llamarRpc('admin_lab_ganancia', { p_desde: desde, p_hasta: hasta }, { signal, leer: leerGanancia }),
    placeholderData: keepPreviousData,
    staleTime: 30_000,
  })
}

export function consultaPorPagar() {
  return queryOptions({
    queryKey: [...CLAVE_LAB, 'por-pagar'],
    queryFn: ({ signal }) => llamarRpc('admin_lab_por_pagar', undefined, { signal, leer: leerPorPagar }),
    staleTime: 20_000,
  })
}

// ── Escrituras ────────────────────────────────────────────────────────────

export function cambiarEstado(p: { id: string; estado: EstadoMuestra; canal?: CanalResultado; nota?: string }) {
  return llamarRpc<unknown>('admin_lab_muestra_estado', {
    p_id: p.id,
    p_estado: p.estado,
    p_canal: p.canal ?? null,
    p_nota: p.nota?.trim() || null,
  })
}

export function revisarPago(p: { id: string; aprobar: boolean; nota?: string }) {
  return llamarRpc<unknown>('admin_lab_pago_revisar', {
    p_id: p.id,
    p_aprobar: p.aprobar,
    p_nota: p.nota?.trim() || null,
  })
}

export function confirmarCuadrados(ids: string[]) {
  return llamarRpc<unknown>('admin_lab_pagos_confirmar_cuadrados', { p_ids: ids })
}

export function guardarAjustes(p: { modo: ModoLab; cargoHeliosUsd: number }) {
  return llamarRpc<unknown>('admin_lab_ajustes_set', { p_modo: p.modo, p_cargo_helios_usd: p.cargoHeliosUsd })
}

export function guardarLaboratorio(l: Omit<Laboratorio, 'id'> & { id: string | null }) {
  return llamarRpc<unknown>('admin_lab_laboratorio_guardar', {
    p_id: l.id,
    p_nombre: l.nombre.trim(),
    p_correo: l.correo?.trim() || null,
    p_telefono: l.telefono?.trim() || null,
    p_direccion: l.direccion?.trim() || null,
    p_activo: l.activo,
  })
}

export function guardarExamen(e: {
  id: string | null
  codigo: string
  nombre: string
  kitTipo: KitTipo
  indicaciones: string | null
  activo: boolean
}) {
  return llamarRpc<unknown>('admin_lab_examen_guardar', {
    p_id: e.id,
    p_codigo: e.codigo.trim(),
    p_nombre: e.nombre.trim(),
    p_kit_tipo: e.kitTipo,
    p_indicaciones: e.indicaciones?.trim() || null,
    p_activo: e.activo,
  })
}

export function guardarPrecio(p: { laboratorioId: string; examenId: string; baseUsd: number; activo: boolean }) {
  return llamarRpc<unknown>('admin_lab_precio_guardar', {
    p_laboratorio_id: p.laboratorioId,
    p_examen_id: p.examenId,
    p_base_usd: p.baseUsd,
    p_activo: p.activo,
  })
}

export function marcarPagado(p: { tipo: 'comision' | 'base'; muestraIds: string[]; referencia: string }) {
  return llamarRpc<unknown>('admin_lab_marcar_pagado', {
    p_tipo: p.tipo,
    p_muestra_ids: p.muestraIds,
    p_referencia: p.referencia.trim(),
  })
}

// ── Captura del pago ──────────────────────────────────────────────────────

/** Enlace firmado (10 minutos) a la captura del Pago Móvil. */
export async function enlaceDeLaCaptura(ruta: string): Promise<string> {
  const { data, error } = await supabase.storage.from(BUCKET_LAB).createSignedUrl(ruta, 600)
  if (error) throw error
  return data.signedUrl
}

export function esPdf(ruta: string): boolean {
  return /\.pdf$/i.test(ruta)
}

// ── Pequeñas cuentas ──────────────────────────────────────────────────────

/** wa.me del paciente, o `null` si no hay número. El envío del resultado es manual. */
export function enlaceWhatsapp(tel: string | null): string | null {
  const n = whatsappNumber(tel)
  return n ? `https://wa.me/${n}` : null
}

export function enlaceCorreo(correo: string | null): string | null {
  return correo && /^\S+@\S+$/.test(correo) ? `mailto:${correo}` : null
}

/** Suma en centavos para no arrastrar decimales binarios. */
export function sumarUsd(valores: number[]): number {
  return Math.round(valores.reduce((a, v) => a + Math.round(v * 100), 0)) / 100
}

/** Páginas que hacen falta para `total` filas. */
export function paginasDe(total: number, porPagina = POR_PAGINA): number {
  return Math.max(1, Math.ceil(total / porPagina))
}

// ── La cola de cobros ─────────────────────────────────────────────────────

export const PAGOS_EN_COLA: readonly EstadoPago[] = ['por_leer', 'cuadra', 'para_revisar']

/**
 * Los pagos que esperan al equipo. La RPC filtra por un solo estado de pago,
 * así que se piden los tres y se juntan, los más viejos primero.
 */
export function consultaCola() {
  return queryOptions({
    queryKey: [...CLAVE_LAB, 'cola'],
    queryFn: async ({ signal }) => {
      const partes = await Promise.all(
        PAGOS_EN_COLA.map((pago) => listarMuestras({ pago, porPagina: 100 }, signal)),
      )
      return partes
        .flat()
        .filter((m) => m.estado !== 'anulada')
        .sort((a, b) => (a.creada ?? '').localeCompare(b.creada ?? ''))
    },
    refetchInterval: 30_000,
    staleTime: 10_000,
  })
}

// ── Médicos (para filtrar) ────────────────────────────────────────────────

export type MedicoLab = { id: string; nombre: string }

/** Los médicos con Lab, de `admin_lab_inventario_por_medico`, para el filtro. */
export function consultaMedicos() {
  return queryOptions({
    queryKey: [...CLAVE_LAB, 'medicos'],
    queryFn: ({ signal }) =>
      llamarRpc('admin_lab_inventario_por_medico', undefined, {
        signal,
        leer: (c): MedicoLab[] =>
          filas(c)
            .map((f) => ({ id: texto(f.merchant_id), nombre: texto(f.medico, '—') }))
            .filter((m) => m.id !== '')
            .sort((a, b) => a.nombre.localeCompare(b.nombre, 'es')),
      }),
    staleTime: 5 * 60_000,
  })
}
