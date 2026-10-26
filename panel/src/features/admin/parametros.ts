import { comoFila, comoLista, numeroONulo, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Los parámetros del negocio, leídos una vez para todo el panel.
//
// Las cifras del producto —días de gracia, cargo por atraso, días de baja y
// de expulsión— y, desde 20260925110000, los umbrales de color, las metas y
// el capital disponible viven en `business_parameters` con vigencia. Ninguna
// pantalla las escribe a mano: las lee de aquí.
//
// Una clave puede existir y no tener valor (el capital y las metas nacen así).
// Eso llega como `null` y se pinta «Sin definir», nunca como cero.
// ═══════════════════════════════════════════════════════════════════════════

/** Las claves que el panel lee por su nombre. Hay más en la tabla. */
export type ClaveParametro =
  | 'consumer_fee_pct'
  | 'vat_pct'
  | 'late_fee_usd'
  | 'late_fee_grace_days'
  | 'installment_interval_days'
  | 'mora_demotion_days'
  | 'mora_expulsion_days'
  | 'on_time_grace_days'
  | 'charge_ttl_minutes'
  | 'umbral_mora_alerta_pct'
  | 'umbral_mora_critica_pct'
  | 'umbral_impago_alerta_pct'
  | 'umbral_impago_critico_pct'
  | 'umbral_cobro_a_tiempo_bueno_pct'
  | 'umbral_cobro_a_tiempo_alerta_pct'
  | 'capital_disponible_usd'
  | 'meta_financiado_semana_usd'
  | 'meta_mora_pct'
  | 'meta_cobro_a_tiempo_pct'
  | 'meta_personas_activas_semana'
  | 'meta_locales_activos'
  // Los de Helios (contrato §3).
  | 'min_charge_usd'
  | 'staff_commission_usd'
  | 'eligibility_lookups_per_staff_day'
  | 'payment_four_eyes'
  | 'payment_margin_under_ves'
  | 'payment_margin_over_ves'
  | 'receipt_resends_per_day'
  | 'alert_charges_per_merchant_day'
  | 'alert_new_patients_per_merchant_day'
  | 'alert_staff_share_pct'
  | 'alert_fpd_merchant_pct'
  | 'alert_fpd_min_cases'
  | 'alert_merchant_exposure_usd'
  | 'alert_first_charge_limit_pct'

export type GrupoParametro = 'producto' | 'umbral' | 'meta' | 'capital'

export type Parametro = {
  key: string
  /** Vigente hoy. `null` = la clave existe y todavía no tiene valor. */
  value: number | null
  effectiveFrom: string | null
  note: string | null
  /** El cambio ya programado, si lo hay. */
  nextValue: number | null
  nextFrom: string | null
  history: Array<{ value: number; effectiveFrom: string; note: string | null; createdAt: string }>
  /** Rótulo y unidad del catálogo de la base; `null` en claves que no están en él. */
  label: string | null
  unit: string | null
  grupo: GrupoParametro | null
}

export type Parametros = {
  /** El día operativo en que se leyeron. */
  businessDate: string
  filas: Parametro[]
}

const GRUPOS: readonly GrupoParametro[] = ['producto', 'umbral', 'meta', 'capital']

/** Una fila de `admin_business_parameters`, ya tipada. */
export function leerParametro(raw: unknown): Parametro {
  const r = comoFila(raw)
  const grupo = GRUPOS.find((g) => g === r.grupo) ?? null
  return {
    key: String(r.key),
    value: numeroONulo(r.value),
    effectiveFrom: textoONulo(r.effective_from),
    note: textoONulo(r.note),
    nextValue: numeroONulo(r.next_value),
    nextFrom: textoONulo(r.next_from),
    history: comoLista(r.history).map((h) => {
      const f = comoFila(h)
      return {
        value: Number(f.value),
        effectiveFrom: String(f.effective_from),
        note: textoONulo(f.note),
        createdAt: String(f.created_at),
      }
    }),
    label: textoONulo(r.label),
    unit: textoONulo(r.unit),
    grupo,
  }
}

/** El valor vigente de una clave, o `null` si no lo tiene o no ha llegado. */
export function valorDe(p: Parametros | undefined, clave: ClaveParametro): number | null {
  return p?.filas.find((f) => f.key === clave)?.value ?? null
}

/** Las filas de un grupo, en el orden de la base. */
export function filasDelGrupo(p: Parametros | undefined, grupo: GrupoParametro): Parametro[] {
  return p?.filas.filter((f) => f.grupo === grupo) ?? []
}
