import { formatUsd, formatPct, formatPorcentaje } from '@/components/ui'
import type { ClaveParametro, Parametros } from '@/features/admin/parametros'
import { valorDe } from '@/features/admin/parametros'
import { progresoDeMeta } from '@/features/admin/semana'
import type { Progreso, Sentido } from '@/features/admin/semana'

/**
 * Las metas que el Resumen sabe medir: qué parámetro, en qué sentido se
 * cumple y cómo se escribe el número.
 *
 * El rótulo de verdad es el del catálogo de la base; el de aquí solo se usa
 * si la base no trae ninguno.
 */
export type DefinicionDeMeta = {
  clave: ClaveParametro
  rotulo: string
  /**
   * Lo que el rótulo tiene que decir siempre, venga de donde venga: la meta
   * del consumo va sin el service fee, y el rótulo de la base no lo dice.
   */
  aclaracion?: string
  sentido: Sentido
  formato: (n: number) => string
}

/** La meta de «Usuarios que consumieron»: «6 usuarios». */
function personas(n: number): string {
  return `${Math.round(n)} ${Math.round(n) === 1 ? 'paciente' : 'pacientes'}`
}

function locales(n: number): string {
  return `${Math.round(n)} ${Math.round(n) === 1 ? 'clínica' : 'clínicas'}`
}

export const METAS = {
  financiado: {
    clave: 'meta_financiado_semana_usd',
    rotulo: 'Total financiado de la semana',
    aclaracion: '(sin fee)',
    sentido: 'subir',
    formato: formatUsd,
  },
  mora: {
    clave: 'meta_mora_pct',
    rotulo: 'Mora',
    sentido: 'bajar',
    formato: (n: number) => formatPct(n),
  },
  cobroATiempo: {
    clave: 'meta_cobro_a_tiempo_pct',
    rotulo: 'Cobrado a tiempo',
    sentido: 'subir',
    formato: (n: number) => formatPct(n),
  },
  personas: {
    clave: 'meta_personas_activas_semana',
    rotulo: 'Pacientes que se financiaron en la semana',
    sentido: 'subir',
    formato: personas,
  },
  locales: {
    clave: 'meta_locales_activos',
    rotulo: 'Clínicas con financiamientos en la semana',
    sentido: 'subir',
    formato: locales,
  },
} as const satisfies Record<string, DefinicionDeMeta>

export type Meta = keyof typeof METAS

/** La meta vigente y cómo va, o `null` en `meta` si no tiene valor. */
export function medirMeta(
  def: DefinicionDeMeta,
  valor: number | null,
  parametros: Parametros | undefined,
): { meta: number | null; progreso: Progreso | null } {
  const meta = valorDe(parametros, def.clave)
  return { meta, progreso: progresoDeMeta(valor, meta, def.sentido) }
}

/**
 * La frase de la meta para el pie de una cifra: «Lleva el 45 % de la meta de
 * €500,00.». `null` si no hay meta o no hay valor que medir.
 */
export function fraseDeMeta(
  def: DefinicionDeMeta,
  valor: number | null,
  parametros: Parametros | undefined,
): string | null {
  const { meta, progreso } = medirMeta(def, valor, parametros)
  if (meta === null || progreso === null) return null

  const cuanto = def.formato(meta)
  if (def.sentido === 'bajar') {
    return progreso.cumplida
      ? `Por debajo de la meta de ${cuanto}.`
      : `Por encima de la meta de ${cuanto}.`
  }
  if (progreso.cumplida) return `Cumple la meta de ${cuanto}.`
  return progreso.pct === null
    ? `La meta es ${cuanto}.`
    : `Lleva el ${formatPorcentaje(progreso.pct)} de la meta de ${cuanto}.`
}
