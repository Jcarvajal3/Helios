import { comoDia } from '@/lib/busqueda'
import { comoFila, comoLista, filaONula, numero, numeroONulo } from '@/lib/json'
import { leerDesglose, leerHoyUsado } from '@/features/admin/metricas/lectura'
import type { Desglose } from '@/features/admin/metricas/lectura'
import type {
  CobroATiempo,
  CuotasConDesglose,
  DineroGeneral,
  General,
  PorCadaCien,
  SemanaDeLaCurva,
} from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// De la respuesta de `admin_metricas_general` a `General`.
//
// Aquí no se calcula nada: se traducen nombres. Un recuento o una suma que la
// base siempre manda se lee con `numero`; lo que puede faltar de verdad (lo
// que no se parte por local, una tasa sin denominador) con `numeroONulo`.
//
// Lo que se paga en cuotas no se lee sin sus dos partes: si a un importe
// payable le falta el consumo, la respuesta está rota y se lanza un error.
// Así la pantalla dice «No se pudo leer» en vez de pintar un total sin su
// desglose (la regla de la comisión) o un cero que no es.
//
// Puro: se prueba en `lectura.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

export const RPC_GENERAL = 'admin_metricas_general'

/** La respuesta no tiene la forma pactada. */
export class RespuestaGeneralRota extends Error {
  constructor(que: string) {
    super(`La respuesta de ${RPC_GENERAL} no trae ${que}.`)
    this.name = 'RespuestaGeneralRota'
  }
}

function desgloseDe(v: unknown, que: string): Desglose {
  const d = leerDesglose(v)
  if (!d) throw new RespuestaGeneralRota(`el desglose de ${que}`)
  return d
}

function cuotasConDesglose(v: unknown, que: string): CuotasConDesglose {
  const f = comoFila(v)
  return { ...desgloseDe(f, que), cuotas: numero(f.cuotas), personas: numero(f.personas) }
}

/** Todo lo movido; `null` si la base no lo manda (una respuesta de antes de 20260928210000). */
function leerMovido(v: unknown): DineroGeneral['movido'] {
  const f = filaONula(v)
  if (f === null) return null
  return { ...desgloseDe(f, 'lo movido'), cuotas: numero(f.cuotas), consumos: numero(f.consumos) }
}

function leerCobroATiempo(v: unknown): CobroATiempo {
  const f = comoFila(v)
  return {
    cuota: numero(f.cuota),
    juzgadas: numero(f.juzgadas),
    aTiempo: numero(f.a_tiempo),
    pct: numeroONulo(f.pct),
  }
}

function leerPorCadaCien(v: unknown): PorCadaCien {
  const f = comoFila(v)
  const p = filaONula(f.por_100)
  return {
    financedUsd: numero(f.financed_usd),
    consumos: numero(f.consumos),
    financedMaduroUsd: numero(f.financed_maduro_usd),
    servicioUsd: numero(f.servicio_usd),
    cargosUsd: numero(f.cargos_usd),
    personalUsd: numero(f.personal_usd),
    perdidoUsd: numero(f.perdido_usd),
    por100: p
      ? {
          servicioUsd: numero(p.servicio_usd),
          cargosUsd: numero(p.cargos_usd),
          personalUsd: numero(p.personal_usd),
          perdidoUsd: numero(p.perdido_usd),
          margenUsd: numero(p.margen_usd),
        }
      : null,
  }
}

function leerSemana(v: unknown): SemanaDeLaCurva | null {
  const f = comoFila(v)
  const semana = comoDia(f.semana)
  if (!semana) return null
  return {
    semana,
    registros: numeroONulo(f.registros),
    registrosAcum: numeroONulo(f.registros_acum),
    consumos: numero(f.consumos),
    financedUsd: numero(f.financed_usd),
    financedAcumUsd: numero(f.financed_acum_usd),
  }
}

/** Lee la respuesta entera. Lanza `RespuestaGeneralRota` si falta lo que no puede faltar. */
export function leerGeneral(crudo: unknown): General {
  const r = filaONula(crudo)
  if (!r) throw new RespuestaGeneralRota('nada')
  const hoy = leerHoyUsado(r.hoy)
  if (!hoy) throw new RespuestaGeneralRota('el día que usó')

  const gente = comoFila(r.gente)
  const consumo = comoFila(r.consumo)
  const dinero = comoFila(r.dinero)
  const cargos = comoFila(dinero.cargos_por_atraso)
  const perdido = comoFila(dinero.perdido)
  const cobrado = comoFila(dinero.cobrado)
  const porPagar = comoFila(dinero.por_pagar_locales)
  const riesgo = comoFila(r.riesgo)
  const aTiempo = comoLista(riesgo.a_tiempo).map(leerCobroATiempo)

  return {
    hoy,
    desde: comoDia(r.desde) ?? null,
    local: typeof r.local === 'string' ? r.local : null,
    ventanaDias: numero(r.ventana_dias),
    graciaDias: numero(r.gracia_dias),
    temporadaDias: numero(r.temporada_dias),
    gente: {
      registros: numeroONulo(gente.registros),
      verificados: numeroONulo(gente.verificados),
      hanComprado: numeroONulo(gente.han_comprado),
      hanCompradoPct: numeroONulo(gente.han_comprado_pct),
      activos: numero(gente.activos),
      repiten: numero(gente.repiten),
      solicitaron: numeroONulo(gente.solicitaron),
      telefonoConfirmado: numeroONulo(gente.telefono_confirmado),
    },
    consumo: {
      financedUsd: numero(consumo.financed_usd),
      consumos: numero(consumo.consumos),
      ticketUsd: numeroONulo(consumo.ticket_usd),
      personas: numero(consumo.personas),
      locales: numeroONulo(consumo.locales),
      localesActivos: numeroONulo(consumo.locales_activos),
    },
    dinero: {
      movido: leerMovido(dinero.movido),
      porCobrar: cuotasConDesglose(dinero.por_cobrar, 'lo por cobrar'),
      vencido: cuotasConDesglose(dinero.vencido, 'lo vencido'),
      cobrado: { ...desgloseDe(cobrado, 'lo cobrado'), cuotas: numero(cobrado.cuotas) },
      servicioUsd: numero(dinero.servicio_usd),
      cargos: {
        devengadoUsd: numero(cargos.devengado_usd),
        cobradoUsd: numero(cargos.cobrado_usd),
        cargos: numero(cargos.cargos),
      },
      perdido: { ...desgloseDe(perdido, 'lo perdido'), personas: numero(perdido.personas) },
      cajaUsd: numeroONulo(dinero.caja_usd),
      porPagarLocales: {
        totalUsd: numero(porPagar.total_usd),
        atrasadoUsd: numero(porPagar.atrasado_usd),
        locales: numero(porPagar.locales),
      },
    },
    riesgo: {
      moraPct: numeroONulo(riesgo.mora_pct),
      impagoPct: numeroONulo(riesgo.impago_pct),
      empatePct: numeroONulo(riesgo.empate_pct),
      aTiempo,
    },
    porCadaCien: leerPorCadaCien(r.por_cada_100),
    curva: comoLista(r.curva)
      .map(leerSemana)
      .filter((s): s is SemanaDeLaCurva => s !== null),
  }
}
