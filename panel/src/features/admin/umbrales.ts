import type { BadgeTone, SenalDeCifra } from '@/components/ui'
import { valorDe } from '@/features/admin/parametros'
import type { Parametros } from '@/features/admin/parametros'

// ═══════════════════════════════════════════════════════════════════════════
// De qué color se pinta una tasa.
//
// Los cortes estaban escritos a mano y no coincidían: la mora era roja desde
// el 15 % en Cartera y desde otro número en la ficha del local. Desde
// 20260925110000 son parámetros (`umbral_*`) y se cambian en Ajustes sin
// desplegar. Aquí solo se decide qué significa cada uno.
//
// Mientras los parámetros no llegan, o si una clave no tiene valor, la tasa
// se pinta neutra: un color inventado es peor que ninguno.
//
// En una cifra (`Stat`) el número va siempre en blanco y el estado sale en
// una pastilla al lado: eso es `senalPorUmbral` y `senalPorUmbralAlto`.
// ═══════════════════════════════════════════════════════════════════════════

/** Dos cortes: desde `alerta` es ámbar y desde `critico`, rojo. */
export type Umbral = { alerta: number; critico: number }

/** Para lo que es mejor cuanto más alto: desde `bueno` es verde, desde `alerta` ámbar. */
export type UmbralAlto = { bueno: number; alerta: number }

/** Cuanto más alto, peor (mora, impago). */
export function tonoPorUmbral(valor: number | null, umbral: Umbral | null): BadgeTone {
  if (valor === null || umbral === null) return 'neutral'
  if (valor >= umbral.critico) return 'error'
  if (valor >= umbral.alerta) return 'warning'
  return 'success'
}

/** Cuanto más alto, mejor (cobro a tiempo). */
export function tonoPorUmbralAlto(valor: number | null, umbral: UmbralAlto | null): BadgeTone {
  if (valor === null || umbral === null) return 'neutral'
  if (valor >= umbral.bueno) return 'success'
  if (valor >= umbral.alerta) return 'warning'
  return 'error'
}

/**
 * La pastilla de estado de una cifra que es peor cuanto más alta (mora,
 * impago), para `Stat senal`: 'Alerta · desde 7 %', 'Crítico · desde 15 %'.
 *
 * Por debajo de la alerta no hay pastilla: una cifra que no cruza ningún
 * umbral no tiene color. Tampoco la hay si falta el valor o el umbral: un
 * color inventado es peor que ninguno.
 */
export function senalPorUmbral(
  valor: number | null,
  umbral: Umbral | null,
  formato: (n: number) => string,
): SenalDeCifra | undefined {
  if (valor === null || umbral === null || !Number.isFinite(valor)) return undefined
  if (valor >= umbral.critico) return { tone: 'error', texto: `Crítico · desde ${formato(umbral.critico)}` }
  if (valor >= umbral.alerta) return { tone: 'warning', texto: `Alerta · desde ${formato(umbral.alerta)}` }
  return undefined
}

/**
 * La pastilla de una cifra que es mejor cuanto más alta (cobro a tiempo):
 * 'En meta' desde `bueno`, y 'Bajo · meta 90 %' por debajo, en ámbar hasta
 * `alerta` y en rojo por debajo de ella. Aquí sí hay pastilla en verde: que se
 * llegue a la meta es la noticia.
 */
export function senalPorUmbralAlto(
  valor: number | null,
  umbral: UmbralAlto | null,
  formato: (n: number) => string,
): SenalDeCifra | undefined {
  if (valor === null || umbral === null || !Number.isFinite(valor)) return undefined
  if (valor >= umbral.bueno) return { tone: 'success', texto: 'En meta' }
  const texto = `Bajo · meta ${formato(umbral.bueno)}`
  return { tone: valor >= umbral.alerta ? 'warning' : 'error', texto }
}

function par(alerta: number | null, critico: number | null): Umbral | null {
  return alerta === null || critico === null ? null : { alerta, critico }
}

/**
 * Los cortes de la mora. Valen para la mora global, la de una cosecha y la de
 * un local: una sola pareja para que el mismo porcentaje no tenga dos colores.
 */
export function umbralMora(p: Parametros | undefined): Umbral | null {
  return par(valorDe(p, 'umbral_mora_alerta_pct'), valorDe(p, 'umbral_mora_critica_pct'))
}

export function umbralImpago(p: Parametros | undefined): Umbral | null {
  return par(valorDe(p, 'umbral_impago_alerta_pct'), valorDe(p, 'umbral_impago_critico_pct'))
}

export function umbralCobroATiempo(p: Parametros | undefined): UmbralAlto | null {
  const bueno = valorDe(p, 'umbral_cobro_a_tiempo_bueno_pct')
  const alerta = valorDe(p, 'umbral_cobro_a_tiempo_alerta_pct')
  return bueno === null || alerta === null ? null : { bueno, alerta }
}

export function tonoMora(pct: number | null, p: Parametros | undefined): BadgeTone {
  return tonoPorUmbral(pct, umbralMora(p))
}

export function tonoImpago(pct: number | null, p: Parametros | undefined): BadgeTone {
  return tonoPorUmbral(pct, umbralImpago(p))
}

export function tonoCobroATiempo(pct: number | null, p: Parametros | undefined): BadgeTone {
  return tonoPorUmbralAlto(pct, umbralCobroATiempo(p))
}
