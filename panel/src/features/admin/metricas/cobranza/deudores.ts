import { formatPorcentaje } from '@/components/ui'
import { leerDesglose } from '@/features/admin/metricas/lectura'
import type { Desglose } from '@/features/admin/metricas/lectura'
import { TRAMOS_VENCIDOS } from '@/features/admin/tramos'
import type { Tramo } from '@/features/admin/tramos'
import { unoDe } from '@/lib/busqueda'
import { booleano, comoFila, comoLista, numero, numeroONulo, texto, textoONulo, textos } from '@/lib/json'
import { PERFILES_DEUDOR, PRIORIDADES, PRIORIDAD_DEL_PERFIL, UMBRALES_DEL_CONTRATO, estaEnMora } from './perfiles'
import type { PerfilDeudor, Prioridad, UmbralesDePerfil } from './perfiles'

// ═══════════════════════════════════════════════════════════════════════════
// Los deudores por comportamiento, leídos de `admin_deudores_por_perfil`.
//
// Todo importe es PAYABLE (lo que la persona tiene que transferir, con el
// service fee dentro) y llega siempre con su desglose: se enseña con
// «Consumo $ + service fee $», nunca como un total suelto.
//
// Puro: se prueba en `deudores.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

const CERO: Desglose = { payableUsd: 0, financedUsd: 0, feeUsd: 0 }

/** Lo que se ha recuperado, en la historia, de la gente de un perfil. */
export type RecuperacionDePerfil = {
  /** Cuántas veces alguien encajó en el perfil con el plazo ya cumplido. */
  episodios: number
  personas: number
  vencido: Desglose
  recuperado: Desglose
  /** Sobre lo que se debía; `null` sin episodios: no es un 0 %. */
  pct: number | null
  /** Los días que se le dan a cada episodio para cobrarse. */
  dias: number
}

export type ResumenDePerfil = {
  perfil: PerfilDeudor
  prioridad: Prioridad
  personas: number
  vencido: Desglose
  porVencer: Desglose
  /** Días de atraso de media; `null` si nadie está en mora (vigilar). */
  atrasoMedioDias: number | null
  /** `null` en vigilar: no es un perfil de mora. */
  recuperacion: RecuperacionDePerfil | null
}

export type Deudor = {
  userId: string
  nombre: string | null
  telefono: string | null
  estado: string
  nivel: number
  perfil: PerfilDeudor
  prioridad: Prioridad
  /** El orden de la cola de cobro: 1 es a quien se llama primero. */
  orden: number
  motivo: string
  vencido: Desglose
  porVencer: Desglose
  diasAtraso: number
  tramo: Tramo
  cuotasVencidas: number
  proximoVencimiento: string | null
  cuotasPagadas: number
  pagadasATiempo: number
  pagadasTarde: number
  atrasoMedioAlPagar: number | null
  promesasHechas: number
  promesasCumplidas: number
  promesasRotas: number
  gestiones: number
  gestionesSinRespuesta: number
  diasDesdeUltimaGestion: number | null
  reportesRechazados: number
  antiguedadDias: number | null
  tienePush: boolean
  locales: string[]
}

export type DeudoresPorPerfil = {
  hoy: string
  local: string | null
  umbrales: UmbralesDePerfil
  /** Quien está en mora (sin vigilar): cuántos y cuánto debe vencido. */
  enMora: { personas: number; vencido: Desglose }
  /** Siempre los siete, en el orden de `PERFILES_DEUDOR`. */
  perfiles: ResumenDePerfil[]
  /** Ordenada por `orden`: la prioridad de la cola. */
  personas: Deudor[]
}

function desglose(v: unknown): Desglose {
  return leerDesglose(v) ?? CERO
}

/** Los umbrales de los perfiles que manda la base; los que falten, del contrato. */
export function leerUmbralesDePerfil(v: unknown): UmbralesDePerfil {
  const u = comoFila(v)
  const n = (clave: string, respaldo: number) => numeroONulo(u[clave]) ?? respaldo
  const c = UMBRALES_DEL_CONTRATO
  return {
    promesaRotaDias: n('promesa_rota_dias', c.promesaRotaDias),
    sinRespuestaGestiones: n('sin_respuesta_gestiones', c.sinRespuestaGestiones),
    sinRespuestaDiasAtraso: n('sin_respuesta_dias_atraso', c.sinRespuestaDiasAtraso),
    sinRespuestaHoras: n('sin_respuesta_horas', c.sinRespuestaHoras),
    reincidenteTarde: n('reincidente_tarde', c.reincidenteTarde),
    seLePasoDias: n('se_le_paso_dias', c.seLePasoDias),
    seLePasoPct: n('se_le_paso_pct', c.seLePasoPct),
    vigilarDias: n('vigilar_dias', c.vigilarDias),
    vigilarPctTarde: n('vigilar_pct_tarde', c.vigilarPctTarde),
    vigilarMinPagadas: n('vigilar_min_pagadas', c.vigilarMinPagadas),
    recuperacionDias: n('recuperacion_dias', c.recuperacionDias),
  }
}

function leerRecuperacion(v: unknown): RecuperacionDePerfil | null {
  if (v === null || v === undefined) return null
  const r = comoFila(v)
  return {
    episodios: numero(r.episodios),
    personas: numero(r.personas),
    vencido: desglose(r.vencido),
    recuperado: desglose(r.recuperado),
    pct: numeroONulo(r.pct),
    dias: numero(r.dias),
  }
}

const TRAMOS: readonly Tramo[] = ['al_dia', ...TRAMOS_VENCIDOS]

function leerDeudor(v: unknown): Deudor | null {
  const f = comoFila(v)
  const perfil = unoDe(PERFILES_DEUDOR, f.perfil)
  const userId = textoONulo(f.user_id)
  // Una fila sin perfil conocido o sin persona no se puede enseñar: se deja.
  if (!perfil || !userId) return null
  return {
    userId,
    nombre: textoONulo(f.nombre),
    telefono: textoONulo(f.telefono),
    estado: texto(f.estado),
    nivel: numero(f.nivel),
    perfil,
    prioridad: unoDe(PRIORIDADES, f.prioridad) ?? PRIORIDAD_DEL_PERFIL[perfil],
    orden: numero(f.orden),
    motivo: texto(f.motivo),
    vencido: desglose(f.vencido),
    porVencer: desglose(f.por_vencer),
    diasAtraso: numero(f.dias_atraso),
    tramo: unoDe(TRAMOS, f.tramo) ?? 'al_dia',
    cuotasVencidas: numero(f.cuotas_vencidas),
    proximoVencimiento: textoONulo(f.proximo_vencimiento),
    cuotasPagadas: numero(f.cuotas_pagadas),
    pagadasATiempo: numero(f.pagadas_a_tiempo),
    pagadasTarde: numero(f.pagadas_tarde),
    atrasoMedioAlPagar: numeroONulo(f.atraso_medio_al_pagar),
    promesasHechas: numero(f.promesas_hechas),
    promesasCumplidas: numero(f.promesas_cumplidas),
    promesasRotas: numero(f.promesas_rotas),
    gestiones: numero(f.gestiones),
    gestionesSinRespuesta: numero(f.gestiones_sin_respuesta),
    diasDesdeUltimaGestion: numeroONulo(f.dias_desde_ultima_gestion),
    reportesRechazados: numero(f.reportes_rechazados),
    antiguedadDias: numeroONulo(f.antiguedad_dias),
    tienePush: booleano(f.tiene_push),
    locales: textos(f.locales),
  }
}

/** La respuesta de `admin_deudores_por_perfil`, ya tipada. */
export function leerDeudores(raw: unknown): DeudoresPorPerfil {
  const d = comoFila(raw)
  const porPerfil = new Map(
    comoLista(d.perfiles).map((v) => {
      const f = comoFila(v)
      return [texto(f.perfil), f] as const
    }),
  )
  const enMora = comoFila(d.en_mora)
  return {
    hoy: texto(d.hoy),
    local: textoONulo(d.merchant_id),
    umbrales: leerUmbralesDePerfil(d.umbrales),
    enMora: { personas: numero(enMora.personas), vencido: desglose(enMora.vencido) },
    // Siempre los siete: un perfil que no vino es un perfil sin nadie.
    perfiles: PERFILES_DEUDOR.map((perfil) => {
      const f = porPerfil.get(perfil)
      return {
        perfil,
        prioridad: unoDe(PRIORIDADES, f?.prioridad) ?? PRIORIDAD_DEL_PERFIL[perfil],
        personas: numero(f?.personas),
        vencido: desglose(f?.vencido),
        porVencer: desglose(f?.por_vencer),
        atrasoMedioDias: numeroONulo(f?.atraso_medio_dias),
        recuperacion: estaEnMora(perfil) ? leerRecuperacion(f?.recuperacion) : null,
      }
    }),
    personas: comoLista(d.personas)
      .flatMap((v) => {
        const p = leerDeudor(v)
        return p ? [p] : []
      })
      .sort((a, b) => a.orden - b.orden),
  }
}

/**
 * La recuperación de un perfil, en pocas palabras: «Histórico: cobrado el
 * 64 % de lo vencido en 30 días (58 casos)». Sin historia todavía, se dice.
 */
export function textoDeRecuperacion(r: RecuperacionDePerfil | null): string {
  if (!r) return 'No aplica: todavía no debe nada'
  if (r.pct === null || r.episodios === 0) return 'Sin historia todavía'
  return `Histórico: cobrado el ${formatPorcentaje(r.pct)} de lo vencido en ${r.dias} días (${r.episodios} ${r.episodios === 1 ? 'caso' : 'casos'})`
}
