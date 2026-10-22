/**
 * Gerencia: cómo va el negocio, semana a semana y día a día.
 *
 * Las RPC son las de Ronda portadas a Helios: sus campos siguen en inglés y
 * hablan de «consumos» (órdenes) y «usuarios» (pacientes). Las descripciones
 * los traducen para el modelo.
 */

import { DESDE, entero, HASTA, leerEntero, objeto, rango, sinVacios } from './esquema.ts';
import type { HerramientaDeDatos } from './tipos.ts';

export const gerencia: HerramientaDeDatos[] = [
  {
    clase: 'datos',
    nombre: 'admin_weekly_summary',
    rpc: 'admin_weekly_summary',
    rotulo: 'Leyendo el resumen de las semanas',
    descripcion:
      'Contesta «¿cuánto se financió esta semana?» y lo que pasó en una semana o entre semanas: financiado ' +
      '(financed_usd), número de órdenes (charge_count), pacientes con orden (active_users), clínicas con órdenes ' +
      '(merchants_with_sales), pacientes nuevos, primeras órdenes (first_time_buyers), Comisión Helios y la mora al ' +
      'cierre. NO contesta cuánto se recuperó de cuotas vencidas (eso es admin_collection_recovered). Semanas de ' +
      'lunes a domingo; la última es la actual y va a medias (complete: false). Clases: financed_usd y ' +
      'written_off_financed_usd son financiado, sin comisión; service_fee_usd es la Comisión Helios sin IVA (línea ' +
      'aparte, nunca se suma a lo financiado); open_debt_usd, overdue_debt_usd y written_off_debt_usd son deuda con ' +
      'la comisión. late_fee_* va siempre en cero (no hay mora).',
    esquema: objeto({ semanas: entero('Cuántas semanas, de 1 a 52. Por defecto 12.') }),
    argumentos: (e) => sinVacios({ p_weeks: leerEntero(e.semanas, 1, 52) }),
    pantalla: { ruta: '/admin/metricas', search: { vista: 'semana', sub: 'rendimiento' } },
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_daily_series',
    rpc: 'admin_daily_series',
    rotulo: 'Leyendo la serie diaria',
    descripcion:
      'Contesta preguntas sobre días concretos («¿cómo fue ayer?», «¿qué día se financió más?») y compara un día ' +
      'con el mismo día de la semana anterior. NO es para semanas enteras (admin_weekly_summary). Una fila por día ' +
      '(de medianoche a medianoche), también los días sin nada, del más viejo a hoy (hoy va a medias). Clases: ' +
      'financed_usd y written_off_financed_usd son financiado, sin comisión; collected_usd es lo cobrado de cuotas ' +
      '(deuda, con la comisión); service_fee_usd es la Comisión Helios sin IVA; settled_usd es lo pagado a clínicas.',
    esquema: objeto({ dias: entero('Cuántos días hasta hoy, de 1 a 365. Por defecto 30.') }),
    argumentos: (e) => sinVacios({ p_days: leerEntero(e.dias, 1, 365) }),
    pantalla: { ruta: '/admin/metricas', search: { vista: 'semana' } },
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_unit_economics',
    rpc: 'admin_unit_economics',
    rotulo: 'Leyendo la economía por cada $100 financiados',
    descripcion:
      'Contesta la rentabilidad por orden: Comisión Helios e impago por cada $100 financiados, y el punto de ' +
      'equilibrio (break_even_pct). Es por cosecha: las órdenes del rango y lo que les pasó después; si matured es ' +
      'false, el impago todavía puede subir y hay que decirlo. No hay margen ni total que sume financiado y ' +
      'comisión. Clases: financed_usd y written_off_financed_usd son financiado, sin comisión; service_fee_usd es ' +
      'la Comisión Helios sin IVA. Sin fechas, los últimos 30 días.',
    esquema: objeto({ desde: DESDE, hasta: HASTA }),
    argumentos: (e) => sinVacios(rango(e)),
    pantalla: { ruta: '/admin/metricas', search: { vista: 'global' } },
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_growth_overview',
    rpc: 'admin_growth_overview',
    rotulo: 'Leyendo el crecimiento',
    descripcion:
      'Contesta crecimiento en un periodo: pacientes registrados, pacientes con orden, órdenes, y financiado por ' +
      'paciente (spend.per_user_usd) y por orden (per_order_usd), cada uno con el periodo anterior del mismo largo, ' +
      'y una serie por día. Clases: spend.financed_usd, per_user_usd y per_order_usd son financiado, sin comisión; ' +
      'spend.revenue_usd es el ingreso de Helios (línea aparte). Sin fechas, los últimos 30 días.',
    esquema: objeto({ desde: DESDE, hasta: HASTA }),
    argumentos: (e) => sinVacios(rango(e)),
    pantalla: { ruta: '/admin/metricas', search: { vista: 'gente' } },
    datosPersonales: 'lista',
  },
];
