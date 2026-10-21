import { formatUsd, formatPct } from '@/components/ui'
import { busquedaDelLugar } from '@/features/admin/metricas/busqueda'
import type { BusquedaComun, BusquedaMetricas } from '@/features/admin/metricas/busqueda'
import { delta } from '@/features/admin/metricas/formato'
import type { Delta, OpcionesDelta } from '@/features/admin/metricas/formato'
import { nombreDelLugar } from '@/features/admin/metricas/pestanas'
import type { Lugar, TonoDePestana } from '@/features/admin/metricas/pestanas'
import type { CifrasDePeriodo, RespuestaSemanas } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// Las filas de «Semana a semana»: qué cifra es cada una, cómo se escribe,
// cómo se compara con la semana anterior y a qué pestaña lleva.
//
// Es el único sitio que lo decide: la tabla, el CSV y las pruebas leen de
// aquí. Una fila nueva es una entrada más en `GRUPOS_DE_FILAS`.
//
// La regla de la comisión, fila a fila: lo que se paga en cuotas (lo que vencía, lo
// vencido) va con sus dos sumandos debajo, en filas propias —«financiado» y
// «Comisión Helios»—, así que nunca hay un total con la comisión dentro sin sus
// partes a la vista. El financiado va sin comisión, la Comisión Helios de Helios sin
// IVA y los cargos por atraso aparte. Lo dado por perdido se cuenta en financiado.
//
// Las palabras: la comisión se llama «Comisión Helios» (o «comisión» donde no cabe),
// nunca «servicio»; todo financiado dice si lleva la comisión, en su nombre, en su
// unidad o al empezar su ayuda.
//
// Puro: se prueba en `filas.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Cómo se escribe una cifra. */
export type Formato = 'eur' | 'numero' | 'pct'

/**
 * A qué pestaña (y sub-pestaña) de Métricas lleva una fila, con la misma
 * semana y local. Sin `sub`, la primera de esa pestaña.
 */
export type DestinoDeFila = Lugar

export type DefinicionDeFila = {
  id: string
  nombre: string
  /** Al lado del nombre, en gris: «sin comisión», «al cierre». */
  unidad?: string
  formato: Formato
  /** Cómo se mide el cambio frente a la anterior: en % o en puntos, y si subir es bueno. */
  comparar: OpcionesDelta
  valor: (c: CifrasDePeriodo) => number | null
  /** Qué es y cómo se calcula. Una o dos frases. */
  ayuda: string
  destino: DestinoDeFila
  /**
   * Es un sumando de la fila de encima (el consumo o la Comisión Helios de lo que
   * se paga en cuotas). Se pinta más pequeña y sin cambio propio.
   */
  sumando?: true
  /** No se parte por local: con un local elegido va `NoSeParte`, nunca un cero. */
  soloSinLocal?: true
}

export type GrupoDeFilas = {
  id: string
  titulo: string
  /** El punto de color del grupo: el tono del área que lo explica. */
  tono: TonoDePestana
  filas: ReadonlyArray<DefinicionDeFila>
}

const EUR_NEUTRO: OpcionesDelta = { tipo: 'relativo', arribaEsBueno: null }
const MAS_ES_BUENO: OpcionesDelta = { tipo: 'relativo', arribaEsBueno: true }
const MAS_ES_MALO: OpcionesDelta = { tipo: 'relativo', arribaEsBueno: false }
const PUNTOS_ARRIBA: OpcionesDelta = { tipo: 'puntos', arribaEsBueno: true }
const PUNTOS_ABAJO: OpcionesDelta = { tipo: 'puntos', arribaEsBueno: false }

const DEL_CONSUMO = 'Sale de los financiamientos confirmados de la semana (día operativo, de lunes a domingo), sin cuentas de prueba.'

export const GRUPOS_DE_FILAS: ReadonlyArray<GrupoDeFilas> = [
  {
    id: 'consumo',
    titulo: 'Financiamiento',
    tono: 'gerencia',
    filas: [
      {
        id: 'consumo',
        // El mismo número y el mismo nombre que «Total facturado (sin comisión)» de Semana › Resumen.
        nombre: 'Total financiado',
        unidad: 'sin comisión',
        formato: 'eur',
        comparar: MAS_ES_BUENO,
        valor: (c) => c.consumo.consumoUsd,
        ayuda: `Sin la Comisión Helios: lo que los pacientes se financiaron en las clínicas. ${DEL_CONSUMO}`,
        destino: { vista: 'locales' },
      },
      {
        id: 'consumos',
        nombre: 'Financiamientos',
        formato: 'numero',
        comparar: MAS_ES_BUENO,
        valor: (c) => c.consumo.consumos,
        ayuda: `Cuántos financiamientos se confirmaron. ${DEL_CONSUMO}`,
        destino: { vista: 'locales' },
      },
      {
        id: 'ticket-medio',
        nombre: 'Ticket medio',
        unidad: 'sin comisión',
        formato: 'eur',
        comparar: MAS_ES_BUENO,
        valor: (c) => c.consumo.ticketMedioUsd,
        ayuda: 'Sin la Comisión Helios: el total financiado dividido entre los financiamientos.',
        destino: { vista: 'locales' },
      },
      {
        id: 'personas',
        nombre: 'Pacientes que se financiaron',
        formato: 'numero',
        comparar: MAS_ES_BUENO,
        valor: (c) => c.consumo.personas,
        ayuda:
          'Pacientes distintos con cuota en algún financiamiento de la semana. Quien se financió dos veces cuenta una vez.',
        destino: { vista: 'gente' },
      },
      {
        id: 'locales',
        nombre: 'Clínicas con financiamientos',
        formato: 'numero',
        comparar: MAS_ES_BUENO,
        valor: (c) => c.consumo.locales,
        ayuda: 'Clínicas que confirmaron al menos un financiamiento en la semana. Las de prueba no cuentan.',
        destino: { vista: 'locales' },
      },
    ],
  },
  {
    id: 'ingreso',
    titulo: 'Ingreso de Helios',
    tono: 'gerencia',
    filas: [
      {
        id: 'servicio',
        nombre: 'Comisión Helios',
        unidad: 'sin IVA',
        formato: 'eur',
        comparar: MAS_ES_BUENO,
        valor: (c) => c.ingreso.servicioUsd,
        ayuda:
          'La Comisión Helios de los financiamientos de la semana, sin el IVA: lo que gana Helios. Se gana al confirmar el financiamiento y se cobra con las cuotas. Nunca se suma al financiamiento.',
        destino: { vista: 'caja', sub: 'balance' },
      },
      {
        id: 'cargos-por-atraso',
        nombre: 'Cargos por atraso',
        unidad: 'sin IVA',
        formato: 'eur',
        comparar: EUR_NEUTRO,
        valor: (c) => c.ingreso.cargosPorAtrasoUsd,
        ayuda:
          'Los cargos por atraso que se cargaron en la semana, sin los condonados. Van aparte del financiamiento y de la Comisión Helios. Con una clínica, solo los de cuotas de esa clínica.',
        destino: { vista: 'caja', sub: 'balance' },
      },
    ],
  },
  {
    id: 'cobro',
    titulo: 'Cobro',
    tono: 'cobranza',
    filas: [
      {
        id: 'vencian',
        nombre: 'Cuotas que vencían',
        unidad: 'financiado + comisión',
        formato: 'eur',
        comparar: EUR_NEUTRO,
        valor: (c) => c.cobro.vencian.payableUsd,
        ayuda:
          'El importe de las cuotas cuyo vencimiento caía en la semana (hasta hoy, si está en curso), estén pagadas o no: el financiado (sin comisión) más la Comisión Helios + IVA, que van en las dos filas de debajo.',
        destino: { vista: 'mora', sub: 'resumen' },
      },
      {
        id: 'vencian-consumo',
        nombre: 'financiado (sin comisión)',
        formato: 'eur',
        comparar: EUR_NEUTRO,
        valor: (c) => c.cobro.vencian.financedUsd,
        ayuda: 'Sin la Comisión Helios: la parte financiada de las cuotas que vencían.',
        destino: { vista: 'mora', sub: 'resumen' },
        sumando: true,
      },
      {
        id: 'vencian-servicio',
        nombre: 'Comisión Helios + IVA',
        formato: 'eur',
        comparar: EUR_NEUTRO,
        valor: (c) => c.cobro.vencian.feeUsd,
        ayuda: 'La Comisión Helios con su IVA, dentro de las cuotas que vencían.',
        destino: { vista: 'mora', sub: 'resumen' },
        sumando: true,
      },
      {
        id: 'a-tiempo',
        nombre: 'Cobrado a tiempo',
        unidad: 'de las cuotas',
        formato: 'pct',
        comparar: PUNTOS_ARRIBA,
        valor: (c) => c.cobro.aTiempo.pct,
        ayuda:
          'De las cuotas que vencían en la semana y ya tienen el plazo cerrado (el vencimiento más los días de gracia), qué parte se pagó a tiempo. Las dadas por perdidas cuentan como no cobradas.',
        destino: { vista: 'mora', sub: 'resumen' },
      },
      {
        id: 'cuota-1',
        nombre: 'Cuota 1 a tiempo',
        formato: 'pct',
        comparar: PUNTOS_ARRIBA,
        valor: (c) => c.cobro.cuota1.pct,
        ayuda: 'Lo mismo, solo con las primeras cuotas: la primera señal de si alguien va a pagar.',
        destino: { vista: 'cobros', sub: 'impago-por-cuota' },
      },
      {
        id: 'cuota-2',
        nombre: 'Cuota 2 a tiempo',
        formato: 'pct',
        comparar: PUNTOS_ARRIBA,
        valor: (c) => c.cobro.cuota2.pct,
        ayuda: 'Lo mismo, solo con las segundas cuotas.',
        destino: { vista: 'cobros', sub: 'impago-por-cuota' },
      },
    ],
  },
  {
    id: 'riesgo',
    titulo: 'Riesgo',
    tono: 'cobranza',
    filas: [
      {
        id: 'vencido',
        nombre: 'Vencido',
        unidad: 'financiado + comisión, al cierre',
        formato: 'eur',
        comparar: MAS_ES_MALO,
        valor: (c) => c.riesgo.vencido.payableUsd,
        ayuda:
          'Las cuotas vencidas y sin pagar al cierre del domingo (ahora, si la semana está en curso), sin lo perdido: el financiado (sin comisión) más la Comisión Helios + IVA, en las dos filas de debajo.',
        destino: { vista: 'mora', sub: 'resumen' },
      },
      {
        id: 'vencido-consumo',
        nombre: 'financiado (sin comisión)',
        formato: 'eur',
        comparar: MAS_ES_MALO,
        valor: (c) => c.riesgo.vencido.financedUsd,
        ayuda: 'Sin la Comisión Helios: la parte financiada de lo vencido.',
        destino: { vista: 'mora', sub: 'resumen' },
        sumando: true,
      },
      {
        id: 'vencido-servicio',
        nombre: 'Comisión Helios + IVA',
        formato: 'eur',
        comparar: MAS_ES_MALO,
        valor: (c) => c.riesgo.vencido.feeUsd,
        ayuda: 'La Comisión Helios con su IVA, dentro de lo vencido.',
        destino: { vista: 'mora', sub: 'resumen' },
        sumando: true,
      },
      {
        id: 'mora',
        nombre: 'Mora',
        unidad: 'al cierre',
        formato: 'pct',
        comparar: PUNTOS_ABAJO,
        valor: (c) => c.riesgo.moraPct,
        ayuda:
          'Vencido ÷ (vencido + por vencer), en importe de cuotas (financiado + comisión), al cierre de la semana (ahora, si está en curso) y sin lo perdido. Es la misma mora de toda la cartera.',
        destino: { vista: 'mora', sub: 'resumen' },
      },
      {
        id: 'perdido',
        nombre: 'Perdido',
        unidad: 'sin comisión',
        formato: 'eur',
        comparar: MAS_ES_MALO,
        valor: (c) => c.riesgo.perdido.financedUsd,
        ayuda:
          'Sin la Comisión Helios: el financiado de las cuotas que se dieron por perdidas en la semana y seguían sin pagar al cierre. Es lo que Helios adelantó y no va a volver.',
        destino: { vista: 'mora', sub: 'resumen' },
      },
    ],
  },
  {
    id: 'gente',
    titulo: 'Pacientes',
    tono: 'gerencia',
    filas: [
      {
        id: 'registros',
        nombre: 'Registros',
        formato: 'numero',
        comparar: MAS_ES_BUENO,
        valor: (c) => c.gente.registros,
        ayuda:
          'Pacientes que una clínica dio de alta en la semana, en el mismo paso que su primer financiamiento. Sin cuentas de prueba.',
        destino: { vista: 'gente' },
        soloSinLocal: true,
      },
      {
        id: 'primer-consumo',
        nombre: 'Pacientes nuevos',
        formato: 'numero',
        comparar: MAS_ES_BUENO,
        valor: (c) => c.gente.primerConsumo,
        ayuda:
          'Pacientes cuyo primer financiamiento en Helios cayó en la semana. Con una clínica, los que se financiaron por primera vez en esa clínica. No es «nuevos en alguna clínica» de Semana › Resumen.',
        destino: { vista: 'gente' },
      },
    ],
  },
  {
    id: 'caja',
    titulo: 'Caja',
    tono: 'caja',
    filas: [
      {
        id: 'transferido',
        nombre: 'Transferido a clínicas',
        formato: 'eur',
        comparar: EUR_NEUTRO,
        valor: (c) => c.caja.transferidoALocalesUsd,
        ayuda:
          'Lo que se les pagó a las clínicas en la semana, por el día en que se registró el pago. Con una clínica, lo que se le pagó a ella.',
        destino: { vista: 'caja', sub: 'balance' },
      },
      {
        id: 'en-caja',
        nombre: 'Dinero en caja',
        unidad: 'al cierre',
        formato: 'eur',
        comparar: MAS_ES_BUENO,
        valor: (c) => c.caja.enCajaUsd,
        ayuda:
          'El dinero en caja según el libro al cierre del domingo (ahora, si la semana está en curso): lo cobrado menos lo pagado a las clínicas y los demás movimientos de caja. No es el saldo del banco.',
        destino: { vista: 'caja', sub: 'balance' },
        soloSinLocal: true,
      },
    ],
  },
]

/** Todas las filas, en orden. */
export const FILAS: ReadonlyArray<DefinicionDeFila> = GRUPOS_DE_FILAS.flatMap((g) => g.filas)

/** El tono del grupo de una fila: el área que la explica. */
export function tonoDeFila(id: string): TonoDePestana {
  return GRUPOS_DE_FILAS.find((g) => g.filas.some((f) => f.id === id))?.tono ?? 'neutro'
}

// ── Escribir ───────────────────────────────────────────────────────────────

/** Un número con los miles de aquí: «1.234». */
function entero(n: number): string {
  return Math.round(n).toLocaleString('es-VE')
}

/** Una tasa: «81,2 %», y «100 %» sin decimales de más. */
function tasa(n: number): string {
  return n >= 99.95 ? '100 %' : formatPct(n, 1)
}

/** La cifra escrita. `null` es «no hay con qué medirlo»: una raya, nunca un cero. */
export function escribir(valor: number | null, formato: Formato): string {
  if (valor === null || !Number.isFinite(valor)) return '—'
  if (formato === 'eur') return formatUsd(valor)
  if (formato === 'pct') return tasa(valor)
  return entero(valor)
}

/**
 * Por qué una celda va en raya. Solo las cifras que pueden no tener dato lo
 * tienen (`puedeIrEnRaya`): lo dice la ayuda de su fila, y el lector de
 * pantalla lo lee en la misma celda.
 */
export function motivoDeRaya(fila: DefinicionDeFila): string {
  if (fila.formato === 'pct' && fila.id === 'mora') return 'Sin nada por cobrar al cierre'
  if (fila.formato === 'pct') return 'Ninguna cuota con el plazo cerrado todavía'
  if (fila.id === 'ticket-medio') return 'Sin financiamientos'
  return 'Sin dato'
}

/** Si una fila puede quedarse sin dato en alguna semana: una tasa sin nada que medir o el ticket sin financiamientos. */
export function puedeIrEnRaya(fila: DefinicionDeFila): boolean {
  return fila.formato === 'pct' || fila.id === 'ticket-medio'
}

/**
 * La ayuda de una fila tal como se lee al señalar su nombre: qué es y, si
 * puede quedarse sin dato, qué quiere decir la raya.
 */
export function ayudaDeFila(fila: DefinicionDeFila): string {
  if (!puedeIrEnRaya(fila)) return fila.ayuda
  const motivo = motivoDeRaya(fila)
  return `${fila.ayuda} Una raya: ${motivo.charAt(0).toLowerCase()}${motivo.slice(1)}.`
}

// ── Comparar ───────────────────────────────────────────────────────────────

/**
 * El cambio de la semana elegida frente a la anterior (a la misma altura si
 * está en curso). Un sumando no lleva cambio propio: lo lleva su fila.
 */
export function cambioDeFila(
  fila: DefinicionDeFila,
  elegida: CifrasDePeriodo,
  anterior: CifrasDePeriodo,
): Delta | null {
  if (fila.sumando) return null
  return delta(fila.valor(elegida), fila.valor(anterior), fila.comparar)
}

/**
 * Ninguna semana tuvo nada que contar: ni financiamientos, ni cuotas que
 * vencieran, ni nada vencido, ni cargos, ni registros, ni pagos a clínicas.
 * Entonces la
 * tabla es una pared de ceros y se dice con una frase.
 */
export function sinMovimiento(respuesta: RespuestaSemanas): boolean {
  return respuesta.semanas.every(({ cifras: c }) => {
    const hubo =
      c.consumo.consumos > 0 ||
      c.cobro.vencian.cuotas > 0 ||
      c.riesgo.vencido.cuotas > 0 ||
      c.riesgo.perdido.cuotas > 0 ||
      c.ingreso.cargosPorAtraso > 0 ||
      (c.gente.registros ?? 0) > 0 ||
      (c.gente.solicitaron ?? 0) > 0 ||
      c.caja.pagosALocales > 0
    return !hubo
  })
}

// ── Adónde lleva ───────────────────────────────────────────────────────────

/** La búsqueda de `/admin/metricas` a la que lleva una fila, con la misma semana y local. */
export function busquedaDeDestino(destino: DestinoDeFila, comun: BusquedaComun): BusquedaMetricas {
  return busquedaDelLugar(destino, comun)
}

/** El nombre del sitio al que lleva («Riesgo › Resumen»), para el rótulo accesible. */
export function nombreDelDestino(destino: DestinoDeFila): string {
  return nombreDelLugar(destino)
}
