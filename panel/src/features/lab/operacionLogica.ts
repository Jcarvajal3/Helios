/**
 * Helios Lab — operación del equipo, la parte que no toca la red: los tipos,
 * la lectura de lo que devuelven las RPC (docs/09-HELIOS-LAB.md §5.2), los
 * roles y el orden de las paradas. Una columna que falte se lee como cero o
 * como vacío, nunca revienta la pantalla. Vive aparte de `operacion.ts` para
 * poder probarse sin cliente de Supabase.
 */
import { KITS } from '@/features/lab/tipos'
import type { EstadoParada, EstadoRuta, KitTipo, TipoParada } from '@/features/lab/tipos'
import { booleano, comoFila, filas, numero, texto, textoONulo } from '@/lib/json'

// ── Roles ──────────────────────────────────────────────────────────────────

/** Quién entra a Helios Lab: el super admin y el operador a todo; el driver, solo a la ruta. */
export type AccesoLab = 'completo' | 'solo_ruta' | 'ninguno'

export function accesoDeLab(rol: string | null | undefined): AccesoLab {
  if (rol === 'super_admin' || rol === 'operador') return 'completo'
  if (rol === 'driver') return 'solo_ruta'
  return 'ninguno'
}

/** La ruta del driver, la única que ve. */
export const RUTA_DEL_DRIVER = '/lab/ruta'

/** Si un driver puede estar en esa dirección: la ruta del día y nada más. */
export function rutaPermitidaAlDriver(pathname: string): boolean {
  const limpia = pathname.length > 1 ? pathname.replace(/\/+$/, '') : pathname
  return limpia === RUTA_DEL_DRIVER
}

// ── Kits ───────────────────────────────────────────────────────────────────

export type KitDeLab = {
  tipo: KitTipo
  nombre: string
  stockHelios: number
  enMedicos: number
  minimoHelios: number
  minimoPorMedico: number
  reponer: boolean
}

export function esKit(valor: unknown): valor is KitTipo {
  return KITS.some((k) => k === valor)
}

export function leerKit(crudo: Record<string, unknown>): KitDeLab | null {
  if (!esKit(crudo.tipo)) return null
  const stock = numero(crudo.stock_helios)
  const minimo = numero(crudo.minimo_helios)
  return {
    tipo: crudo.tipo,
    nombre: texto(crudo.nombre, crudo.tipo),
    stockHelios: stock,
    enMedicos: numero(crudo.en_medicos),
    minimoHelios: minimo,
    minimoPorMedico: numero(crudo.minimo_por_medico),
    // La base dice si hay que reponer; sin ese dato, se deduce.
    reponer: crudo.reponer === undefined ? stock < minimo : booleano(crudo.reponer),
  }
}

export function leerKits(crudo: unknown): KitDeLab[] {
  return filas(crudo)
    .map(leerKit)
    .filter((k): k is KitDeLab => k !== null)
}

export type InventarioDeMedico = {
  merchantId: string
  medico: string
  consultorio: string | null
  kits: Record<KitTipo, number>
  entregadosTotal: number
  usadosTotal: number
  bajoMinimo: boolean
}

export function leerInventarioDeMedicos(crudo: unknown): InventarioDeMedico[] {
  return filas(crudo).map((f) => ({
    merchantId: texto(f.merchant_id),
    medico: texto(f.medico, 'Sin nombre'),
    consultorio: textoONulo(f.consultorio),
    kits: { sangre: numero(f.sangre), orina: numero(f.orina), biopsia: numero(f.biopsia) },
    entregadosTotal: numero(f.entregados_total),
    usadosTotal: numero(f.usados_total),
    bajoMinimo: booleano(f.bajo_minimo),
  }))
}

/** Los que están bajo el mínimo, primero; luego por nombre. */
export function ordenarInventario(lista: ReadonlyArray<InventarioDeMedico>): InventarioDeMedico[] {
  return [...lista].sort(
    (a, b) => Number(b.bajoMinimo) - Number(a.bajoMinimo) || a.medico.localeCompare(b.medico, 'es'),
  )
}

// ── Logística ──────────────────────────────────────────────────────────────

export type RetiroDeConsultorio = {
  merchantId: string
  medico: string
  consultorio: string | null
  direccion: string | null
  /** Códigos de las muestras por retirar (si la base los manda) y cuántas son. */
  codigos: string[]
  muestras: number
}

export type PedidoDeKits = {
  id: string | null
  merchantId: string
  medico: string
  consultorio: string | null
  kit: KitTipo | null
  cantidad: number
  nota: string | null
}

export type MedicoBajoMinimo = {
  merchantId: string
  medico: string
  consultorio: string | null
  /** Lo que tiene de cada kit; `null` si la base no lo dice. */
  kits: Record<KitTipo, number | null>
}

export type LogisticaDelDia = {
  porRetirar: RetiroDeConsultorio[]
  pedidos: PedidoDeKits[]
  bajoMinimo: MedicoBajoMinimo[]
}

function nombreDelMedico(f: Record<string, unknown>): string {
  return texto(f.medico, texto(f.nombre, texto(f.merchant_name, 'Sin nombre')))
}

function cantidadDeMuestras(valor: unknown): { codigos: string[]; n: number } {
  if (Array.isArray(valor)) {
    const codigos = valor
      .map((m) => (typeof m === 'string' ? m : texto(comoFila(m).codigo)))
      .filter((c) => c !== '')
    return { codigos, n: valor.length }
  }
  return { codigos: [], n: numero(valor) }
}

function kitsDeFila(f: Record<string, unknown>): Record<KitTipo, number | null> {
  const dentro = comoFila(f.kits)
  const valor = (k: KitTipo): number | null => {
    const v = f[k] ?? dentro[k]
    return v === undefined || v === null ? null : numero(v)
  }
  return { sangre: valor('sangre'), orina: valor('orina'), biopsia: valor('biopsia') }
}

export function leerLogistica(crudo: unknown): LogisticaDelDia {
  const raiz = comoFila(crudo)
  return {
    porRetirar: filas(raiz.por_retirar).map((f) => {
      const { codigos, n } = cantidadDeMuestras(f.muestras)
      return {
        merchantId: texto(f.merchant_id),
        medico: nombreDelMedico(f),
        consultorio: textoONulo(f.consultorio),
        direccion: textoONulo(f.direccion),
        codigos,
        muestras: n,
      }
    }),
    pedidos: filas(raiz.pedidos).map((f) => ({
      id: textoONulo(f.id),
      merchantId: texto(f.merchant_id),
      medico: nombreDelMedico(f),
      consultorio: textoONulo(f.consultorio),
      kit: esKit(f.kit_tipo) ? f.kit_tipo : null,
      cantidad: numero(f.cantidad),
      nota: textoONulo(f.nota),
    })),
    bajoMinimo: filas(raiz.bajo_minimo).map((f) => ({
      merchantId: texto(f.merchant_id),
      medico: nombreDelMedico(f),
      consultorio: textoONulo(f.consultorio),
      kits: kitsDeFila(f),
    })),
  }
}

// ── La ruta ────────────────────────────────────────────────────────────────

export type MuestraDeParada = { codigo: string; examen: string; kit: KitTipo | null }

export type KitDeParada = { kit: KitTipo; cantidad: number }

export type ParadaDeRuta = {
  id: string
  orden: number
  tipo: TipoParada
  estado: EstadoParada
  nombre: string
  direccion: string | null
  telefono: string | null
  kitsADejar: KitDeParada[]
  muestras: MuestraDeParada[]
}

export type RutaDelDia = {
  /** `null` si todavía no hay ruta armada para ese día. */
  id: string | null
  estado: EstadoRuta | null
  paradas: ParadaDeRuta[]
}

/** Los kits a dejar llegan como lista `[{kit_tipo, cantidad}]` o como objeto `{sangre: 2}`. */
export function leerKitsADejar(crudo: unknown): KitDeParada[] {
  const lista: KitDeParada[] = []
  if (Array.isArray(crudo)) {
    for (const f of filas(crudo)) {
      const kit = f.kit_tipo ?? f.tipo
      if (esKit(kit) && numero(f.cantidad) > 0) lista.push({ kit, cantidad: numero(f.cantidad) })
    }
  } else {
    const objeto = comoFila(crudo)
    for (const kit of KITS) {
      if (numero(objeto[kit]) > 0) lista.push({ kit, cantidad: numero(objeto[kit]) })
    }
  }
  return lista
}

const ESTADOS_PARADA: ReadonlyArray<EstadoParada> = ['pendiente', 'completada', 'saltada']
const ESTADOS_RUTA: ReadonlyArray<EstadoRuta> = ['borrador', 'en_curso', 'cerrada']

export function leerRuta(crudo: unknown): RutaDelDia {
  const raiz = comoFila(crudo)
  const ruta = comoFila(raiz.ruta)
  const estado = ESTADOS_RUTA.find((e) => e === ruta.estado) ?? null
  const paradas = filas(raiz.paradas)
    .map((f): ParadaDeRuta => ({
      id: texto(f.id),
      orden: numero(f.orden),
      tipo: f.tipo === 'laboratorio' ? 'laboratorio' : 'consultorio',
      estado: ESTADOS_PARADA.find((e) => e === f.estado) ?? 'pendiente',
      nombre: texto(f.nombre, 'Parada'),
      direccion: textoONulo(f.direccion),
      telefono: textoONulo(f.telefono),
      kitsADejar: leerKitsADejar(f.kits_a_dejar),
      muestras: filas(f.muestras).map((m) => ({
        codigo: texto(m.codigo),
        examen: texto(m.examen),
        kit: esKit(m.kit_tipo) ? m.kit_tipo : null,
      })),
    }))
    .sort((a, b) => a.orden - b.orden)
  return { id: textoONulo(ruta.id), estado, paradas }
}

/** «3 de 7»: cuántas paradas ya no esperan (completadas o saltadas) y cuántas son. */
export function progresoDeRuta(paradas: ReadonlyArray<ParadaDeRuta>): { hechas: number; total: number } {
  return { hechas: paradas.filter((p) => p.estado !== 'pendiente').length, total: paradas.length }
}

/** La primera parada que sigue esperando: la que toca ahora. */
export function paradaActual(paradas: ReadonlyArray<ParadaDeRuta>): ParadaDeRuta | null {
  return paradas.find((p) => p.estado === 'pendiente') ?? null
}

/** `n` kits de un tipo, con su rótulo: «2 de sangre». */
export function totalDeKits(kits: ReadonlyArray<KitDeParada>): number {
  return kits.reduce((suma, k) => suma + k.cantidad, 0)
}

/**
 * La posición a la que hay que mandar una parada para subirla o bajarla un
 * puesto: la `orden` de la vecina con la que cambia de sitio. `null` si ya
 * está en el borde.
 */
export function ordenAlMover(
  paradas: ReadonlyArray<Pick<ParadaDeRuta, 'id' | 'orden'>>,
  id: string,
  sentido: 'arriba' | 'abajo',
): number | null {
  const i = paradas.findIndex((p) => p.id === id)
  if (i === -1) return null
  const j = sentido === 'arriba' ? i - 1 : i + 1
  return j < 0 || j >= paradas.length ? null : paradas[j].orden
}
