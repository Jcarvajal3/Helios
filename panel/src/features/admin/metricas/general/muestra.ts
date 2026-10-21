// ═══════════════════════════════════════════════════════════════════════════
// Una respuesta de `admin_metricas_general` para las pruebas, con la forma
// exacta que devuelve la base (claves en snake_case, numéricos como número).
// Las cifras son las de dev con la semilla del 2026-09-27, recortadas a tres
// semanas de curva.
// ═══════════════════════════════════════════════════════════════════════════

export function respuestaDeMuestra(): Record<string, unknown> {
  return {
    hoy: '2026-09-26',
    desde: '2026-09-07',
    local: null,
    ventana_dias: 30,
    gracia_dias: 2,
    temporada_dias: 74,
    gente: {
      registros: 194,
      verificados: 194,
      han_comprado: 134,
      han_comprado_pct: 69.1,
      activos: 124,
      repiten: 101,
      solicitaron: 236,
      telefono_confirmado: 226,
    },
    consumo: {
      financed_usd: 7373,
      consumos: 318,
      ticket_usd: 23.19,
      personas: 134,
      locales: 3,
      locales_activos: 3,
    },
    dinero: {
      // Lo cobrado + lo por cobrar + lo perdido.
      movido: { payable_usd: 9083.84, financed_usd: 7373, fee_usd: 1710.84, cuotas: 642, consumos: 318 },
      por_cobrar: { payable_usd: 2589.93, financed_usd: 2102.14, fee_usd: 487.79, cuotas: 180, personas: 90 },
      vencido: { payable_usd: 527.77, financed_usd: 428.25, fee_usd: 99.52, cuotas: 40, personas: 26 },
      cobrado: { payable_usd: 6421.01, financed_usd: 5211.69, fee_usd: 1209.32, cuotas: 460 },
      servicio_usd: 1473.85,
      cargos_por_atraso: { devengado_usd: 254, cobrado_usd: 148, cargos: 51 },
      perdido: { payable_usd: 72.9, financed_usd: 59.17, fee_usd: 13.73, personas: 2 },
      caja_usd: 2346.91,
      por_pagar_locales: { total_usd: 3149.66, atrasado_usd: 379, locales: 3 },
    },
    riesgo: {
      mora_pct: 20.38,
      impago_pct: 0.8,
      empate_pct: 16.66,
      a_tiempo: [
        { cuota: 1, juzgadas: 356, a_tiempo: 272, pct: 76.4 },
        { cuota: 2, juzgadas: 290, a_tiempo: 222, pct: 76.6 },
      ],
    },
    por_cada_100: {
      financed_usd: 7373,
      consumos: 318,
      financed_maduro_usd: 2400,
      servicio_usd: 1473.85,
      cargos_usd: 254,
      personal_usd: 159,
      perdido_usd: 59.17,
      por_100: { servicio_usd: 19.99, cargos_usd: 3.45, personal_usd: 2.16, perdido_usd: 0.8, margen_usd: 20.48 },
    },
    curva: [
      { semana: '2026-09-07', registros: 150, registros_acum: 150, consumos: 200, financed_usd: 4500, financed_acum_usd: 4500 },
      { semana: '2026-09-14', registros: 0, registros_acum: 150, consumos: 0, financed_usd: 0, financed_acum_usd: 4500 },
      { semana: '2026-09-21', registros: 44, registros_acum: 194, consumos: 118, financed_usd: 2873, financed_acum_usd: 7373 },
    ],
  }
}

/** La misma respuesta con un local elegido: lo que no se parte llega nulo. */
export function respuestaDeUnLocal(): Record<string, unknown> {
  const r = respuestaDeMuestra()
  const gente = r.gente as Record<string, unknown>
  const consumo = r.consumo as Record<string, unknown>
  const dinero = r.dinero as Record<string, unknown>
  return {
    ...r,
    local: '11111111-1111-1111-1111-111111111111',
    gente: {
      ...gente,
      registros: null,
      verificados: null,
      han_comprado: null,
      han_comprado_pct: null,
      solicitaron: null,
      telefono_confirmado: null,
    },
    consumo: { ...consumo, locales: null, locales_activos: null },
    dinero: { ...dinero, caja_usd: null },
    curva: (r.curva as Array<Record<string, unknown>>).map((s) => ({ ...s, registros: null, registros_acum: null })),
  }
}
