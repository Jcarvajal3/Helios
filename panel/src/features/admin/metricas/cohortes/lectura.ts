import { leerDesglose, leerHoyUsado, leerSemanaUsada } from '@/features/admin/metricas/lectura'
import type { Desglose } from '@/features/admin/metricas/lectura'
import { comoDia } from '@/lib/busqueda'
import { booleano, comoLista, filaONula, numero, numeroONulo, texto, textos } from '@/lib/json'
import { ESTADOS_DE_CUOTA } from './tipos'
import type {
  ACobrar,
  Cobro,
  Cohorte,
  CohorteDeLocal,
  CuotaDeCohorte,
  CurvaDeCuota,
  DetalleDeCohorte,
  EstadoDeCuota,
  ListaDeCohortes,
  NumeroDeCuota,
  ParteDeCuota,
  PuntoDeCurva,
} from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// Leer el JSON de `admin_metricas_cohortes` y `admin_metricas_cohorte`.
//
// Lo que puede faltar de verdad (un porcentaje sin nada que cobrar, un día de
// la curva que no ha cerrado) se queda en `null`. Lo que la base manda
// SIEMPRE (la semana, lo que hay que cobrar de ella, el importe de una cuota
// con su desglose, sus cinco estados) y no llega es un contrato roto: se
// lanza un error, y la pantalla dice «No se pudo leer» en vez de pintar un
// cero que parecería un dato.
//
// Puro: se prueba en `lectura.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** La respuesta no tiene la forma que promete la base. */
export class RespuestaRota extends Error {
  constructor(que: string) {
    super(`La respuesta de las cohortes llegó sin ${que}. Vuelve a intentarlo; si se repite, avisa.`)
    this.name = 'RespuestaRota'
  }
}

function exigir<T>(valor: T | null | undefined, que: string): T {
  if (valor === null || valor === undefined) throw new RespuestaRota(que)
  return valor
}

function numeroDeCuota(v: unknown): NumeroDeCuota | null {
  const n = numeroONulo(v)
  return n === 1 || n === 2 ? n : null
}

function desglose(v: unknown, que: string): Desglose {
  return exigir(leerDesglose(v), `el importe de ${que}`)
}

/** Las cuotas de una cohorte en un estado (o en un grupo de estados). */
export function leerParte(v: unknown, que: string): ParteDeCuota {
  const f = exigir(filaONula(v), que)
  return { cuotas: numero(f.cuotas), personas: numero(f.personas), importe: desglose(f, que) }
}

/** Lo común de una cuota y del total a cobrar: el importe, los porcentajes y los cinco estados. */
function leerCobro(f: Record<string, unknown>, que: string): Cobro {
  const crudos = exigir(filaONula(f.estados), `los estados de ${que}`)
  const estados = Object.fromEntries(
    ESTADOS_DE_CUOTA.map((e) => [e, leerParte(crudos[e], `${que} (${e})`)]),
  ) as Record<EstadoDeCuota, ParteDeCuota>

  return {
    cuotas: numero(f.cuotas),
    personas: numero(f.personas),
    importe: desglose(f, que),
    cobradoPct: numeroONulo(f.cobrado_pct),
    aTiempoPct: numeroONulo(f.a_tiempo_pct),
    vencidoPct: numeroONulo(f.vencido_pct),
    estados,
  }
}

/** Una cuota de una cohorte, con sus cinco estados. */
export function leerCuota(v: unknown): CuotaDeCohorte {
  const f = exigir(filaONula(v), 'una cuota')
  const n = exigir(numeroDeCuota(f.sequence), 'el número de una cuota')
  const que = `la cuota ${n}`
  return {
    ...leerCobro(f, que),
    numero: n,
    venceDesde: exigir(comoDia(f.vence_desde), `el vencimiento de ${que}`),
    venceHasta: exigir(comoDia(f.vence_hasta), `el vencimiento de ${que}`),
  }
}

/** Lo que hay que cobrar de una semana: las dos cuotas juntas, lo cobrado y lo que falta. */
export function leerACobrar(v: unknown): ACobrar {
  const que = 'lo que hay que cobrar de una semana'
  const f = exigir(filaONula(v), que)
  return {
    ...leerCobro(f, que),
    venceDesde: comoDia(f.vence_desde) ?? null,
    venceHasta: comoDia(f.vence_hasta) ?? null,
    faltaPct: numeroONulo(f.falta_pct),
    cobrado: leerParte(f.cobrado, `lo cobrado de ${que}`),
    falta: leerParte(f.falta, `lo que falta de ${que}`),
  }
}

/** Una cohorte: lo que hay que cobrar de la semana y sus cuotas, la 1 antes que la 2. */
export function leerCohorte(v: unknown): Cohorte {
  const f = exigir(filaONula(v), 'una semana')
  const semana = exigir(comoDia(f.semana), 'el lunes de una semana')
  const cuotas = comoLista(f.cuotas)
    .map(leerCuota)
    .sort((a, b) => a.numero - b.numero)

  return {
    semana,
    hasta: comoDia(f.hasta) ?? semana,
    enCurso: booleano(f.en_curso),
    consumos: numero(f.consumos),
    consumoUsd: exigir(numeroONulo(f.financed_usd), 'el financiamiento de una semana'),
    personas: numero(f.personas),
    aCobrar: leerACobrar(f.a_cobrar),
    cuotas,
  }
}

/** Una fila de «Por local». */
export function leerCohorteDeLocal(v: unknown): CohorteDeLocal {
  const f = exigir(filaONula(v), 'una clínica')
  return {
    ...leerCohorte(f),
    merchantId: exigir(texto(f.merchant_id) || null, 'el id de una clínica'),
    nombre: texto(f.nombre, 'Clínica sin nombre'),
  }
}

function leerPunto(v: unknown): PuntoDeCurva {
  const f = exigir(filaONula(v), 'un día de la curva')
  return {
    dia: exigir(numeroONulo(f.dia), 'el día de la curva'),
    estaPct: numeroONulo(f.esta_pct),
    mediaPct: numeroONulo(f.media_pct),
    semanasEnMedia: numero(f.semanas_en_media),
  }
}

function leerCurva(v: unknown): CurvaDeCuota {
  const f = exigir(filaONula(v), 'una curva')
  return {
    numero: exigir(numeroDeCuota(f.sequence), 'el número de cuota de una curva'),
    semanasMedia: textos(f.semanas_media),
    puntos: comoLista(f.dias)
      .map(leerPunto)
      .sort((a, b) => a.dia - b.dia),
  }
}

/** `admin_metricas_cohortes`: la lista de todas las semanas. */
export function leerListaDeCohortes(crudo: unknown): ListaDeCohortes {
  const f = exigir(filaONula(crudo), 'nada')
  const hoy = exigir(leerHoyUsado(f.hoy), 'el día de hoy')
  return {
    hoy,
    graciaDias: numero(f.gracia_dias),
    semanaEnCurso: comoDia(f.semana_en_curso) ?? hoy,
    cohortes: comoLista(f.cohortes)
      .map(leerCohorte)
      .sort((a, b) => (a.semana < b.semana ? 1 : a.semana > b.semana ? -1 : 0)),
  }
}

/** `admin_metricas_cohorte`: el detalle de una semana. */
export function leerDetalleDeCohorte(crudo: unknown): DetalleDeCohorte {
  const f = exigir(filaONula(crudo), 'nada')
  return {
    semana: exigir(leerSemanaUsada(f.semana), 'la semana que se usó'),
    hoy: exigir(leerHoyUsado(f.hoy), 'el día de hoy'),
    graciaDias: numero(f.gracia_dias),
    cohorte: f.cohorte === null || f.cohorte === undefined ? null : leerCohorte(f.cohorte),
    curvas: comoLista(f.curvas)
      .map(leerCurva)
      .sort((a, b) => a.numero - b.numero),
    porLocal: comoLista(f.por_local).map(leerCohorteDeLocal),
  }
}
