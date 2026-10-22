/**
 * Las herramientas: esquemas válidos para `strict`, parámetros que existen en
 * la RPC, recortes y enmascarado. Sin red: la base es de mentira.
 */

import assert from 'node:assert/strict';

import type { Base, RespuestaDeBase } from '../base.ts';
import { recortarResumenGeneral } from '../herramientas/caja.ts';
import { ejecutarHerramienta, serializarAcotado } from '../herramientas/ejecutar.ts';
import { definiciones, HERRAMIENTAS } from '../herramientas/index.ts';
import type { Herramienta, HerramientaDeDatos } from '../herramientas/tipos.ts';
import { leerMapa } from '../mapa.ts';

/**
 * Los parámetros de cada RPC tal como están en Helios
 * (`pg_get_function_identity_arguments`, 2026-10-23). Si una migración los
 * cambia, esta tabla y la herramienta cambian juntas.
 */
const FIRMAS: Record<string, readonly string[]> = {
  admin_weekly_summary: ['p_weeks'],
  admin_daily_series: ['p_days'],
  admin_unit_economics: ['p_from', 'p_to'],
  admin_growth_overview: ['p_from', 'p_to', 'p_merchant_id'],
  admin_overview: ['p_days', 'p_merchant_id'],
  admin_merchant_payables: ['p_merchant_id'],
  admin_reconciliation_health: ['p_from', 'p_to'],
  admin_cash_forecast: ['p_weeks', 'p_merchant_id'],
  admin_collections: ['p_horizon_days', 'p_merchant_id', 'p_cohorte'],
  admin_collection_promises: ['p_from', 'p_to', 'p_merchant_id'],
  admin_collection_recovered: ['p_from', 'p_to', 'p_merchant_id'],
  admin_contact_effectiveness: ['p_from', 'p_to', 'p_merchant_id'],
  admin_collection_flow: ['p_weeks', 'p_merchant_id', 'p_hasta'],
  admin_first_payment_default: ['p_months', 'p_dim', 'p_merchant_id', 'p_hasta', 'p_cuota'],
  admin_credit_utilization: ['p_merchant_id'],
  admin_risk_alert_counts: [],
  admin_risk_alerts: ['p_limit', 'p_kinds', 'p_subject_id'],
  admin_cohort_curves: ['p_months', 'p_merchant_id'],
  admin_merchant_risk: ['p_days', 'p_merchant_id'],
  admin_user_directory: ['p_search', 'p_status', 'p_limit', 'p_level', 'p_is_test', 'p_blacklisted', 'p_offset', 'p_orden', 'p_dir'],
  admin_user_detail: ['p_user_id'],
  admin_collection_case: ['p_user', 'p_horizon_days'],
  admin_charges: ['p_search', 'p_merchant_id', 'p_status', 'p_from', 'p_to', 'p_limit'],
  admin_charge_detail: ['p_charge_id'],
  admin_merchant_stats: ['p_merchant_id', 'p_days', 'p_semana'],
  admin_assistant_query: ['p_sql', 'p_max_rows'],
  admin_merchant_performance: ['p_desde', 'p_hasta'],
  admin_receivables_by_day: ['p_desde', 'p_hasta', 'p_incluir_pagadas'],
};

const ID = '839bba23-640e-4f57-9280-c814013233bc';

/** Entrada de ejemplo → argumentos esperados, para cada herramienta de datos. */
const CASOS: Record<string, { entrada: Record<string, unknown>; args: Record<string, unknown> }> = {
  admin_weekly_summary: { entrada: { semanas: 8 }, args: { p_weeks: 8 } },
  admin_daily_series: { entrada: { dias: 14 }, args: { p_days: 14 } },
  admin_unit_economics: { entrada: { desde: '2026-09-01', hasta: '2026-09-24' }, args: { p_from: '2026-09-01', p_to: '2026-09-24' } },
  admin_growth_overview: { entrada: { desde: '2026-08-01', hasta: '2026-08-31' }, args: { p_from: '2026-08-01', p_to: '2026-08-31' } },
  admin_overview: { entrada: { dias: 7 }, args: { p_days: 7 } },
  admin_merchant_payables: { entrada: {}, args: {} },
  admin_reconciliation_health: { entrada: { desde: '2026-09-20', hasta: '2026-09-24' }, args: { p_from: '2026-09-20', p_to: '2026-09-24' } },
  admin_cash_forecast: { entrada: { semanas: 6 }, args: { p_weeks: 6 } },
  admin_collections: { entrada: { horizonte_dias: 0 }, args: { p_horizon_days: 0 } },
  admin_collection_promises: { entrada: { desde: '2026-09-20', hasta: '2026-09-30' }, args: { p_from: '2026-09-20', p_to: '2026-09-30' } },
  admin_collection_recovered: { entrada: { desde: '2026-09-01', hasta: '2026-09-24' }, args: { p_from: '2026-09-01', p_to: '2026-09-24' } },
  admin_contact_effectiveness: { entrada: { desde: '2026-09-01', hasta: '2026-09-24' }, args: { p_from: '2026-09-01', p_to: '2026-09-24' } },
  admin_collection_flow: { entrada: { semanas: 12 }, args: { p_weeks: 12 } },
  admin_first_payment_default: {
    entrada: { meses: 3, dimension: 'local', cuota: 2 },
    args: { p_months: 3, p_dim: 'local', p_cuota: 2 },
  },
  admin_credit_utilization: { entrada: {}, args: {} },
  admin_risk_alert_counts: { entrada: {}, args: {} },
  admin_risk_alerts: {
    entrada: { tipos: ['telefono_repetido', 'telefono_repetido', 'kyc_red_sospechosa'], limite: 10 },
    args: { p_limit: 10, p_kinds: ['telefono_repetido'] },
  },
  admin_cohort_curves: { entrada: { meses: 12 }, args: { p_months: 12 } },
  admin_merchant_risk: { entrada: { dias: 30 }, args: { p_days: 30 } },
  admin_user_directory: {
    entrada: { buscar: '  María ', estado: 'frozen', limite: 80 },
    args: { p_search: 'María', p_status: 'frozen', p_limit: 50 },
  },
  admin_user_detail: { entrada: { persona_id: ID }, args: { p_user_id: ID } },
  admin_collection_case: { entrada: { persona_id: ID, horizonte_dias: 30 }, args: { p_user: ID, p_horizon_days: 30 } },
  admin_charges: {
    entrada: { buscar: '1043', local_id: ID, estado: 'confirmed', desde: '2026-09-01', hasta: '2026-09-24', limite: 10 },
    args: { p_search: '1043', p_merchant_id: ID, p_status: 'confirmed', p_from: '2026-09-01', p_to: '2026-09-24', p_limit: 10 },
  },
  admin_charge_detail: { entrada: { consumo_id: ID }, args: { p_charge_id: ID } },
  admin_merchant_stats: { entrada: { local_id: ID, dias: 60 }, args: { p_merchant_id: ID, p_days: 60 } },
  consultar_datos: {
    entrada: { sql: '  select sexo, count(*) as n from pacientes group by 1 ', titulo: 'Por sexo', mostrar: 'barras', etiqueta: 'sexo', valor: 'n', valor2: 'n', unidad: 'numero' },
    args: { p_sql: 'select sexo, count(*) as n from pacientes group by 1', p_max_rows: 200 },
  },
  admin_merchant_performance: { entrada: { desde: '2026-09-01', hasta: '2026-09-24' }, args: { p_desde: '2026-09-01', p_hasta: '2026-09-24' } },
  admin_receivables_by_day: {
    entrada: { desde: '2026-09-22', hasta: '2026-09-28', incluir_pagadas: true },
    args: { p_desde: '2026-09-22', p_hasta: '2026-09-28', p_incluir_pagadas: true },
  },
};

const deDatos = HERRAMIENTAS.filter((h): h is HerramientaDeDatos => h.clase === 'datos');

const esObjeto = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

function propiedadesDe(esquema: unknown): Record<string, unknown> {
  return esObjeto(esquema) && esObjeto(esquema.properties) ? esquema.properties : {};
}

function deDatosLlamada(nombre: string): HerramientaDeDatos {
  const h = herramienta(nombre);
  assert.ok(h.clase === 'datos');
  return h;
}

function herramienta(nombre: string): Herramienta {
  const h = HERRAMIENTAS.find((x) => x.nombre === nombre);
  assert.ok(h, `no existe ${nombre}`);
  return h;
}

function baseDeMentira(respuesta: RespuestaDeBase, llamadas: Array<[string, unknown]> = []): Base {
  return {
    usuario: () => Promise.resolve(ID),
    rpc: (nombre, args) => {
      llamadas.push([nombre, args]);
      return Promise.resolve(respuesta);
    },
  };
}

const MAPA = leerMapa({ pantallas: [], fichas: [], cifras: [] });

/** Recorre un esquema y comprueba lo que `strict` exige a cada objeto. */
function comprobarEstricto(esquema: unknown, donde: string): void {
  if (!esObjeto(esquema)) return;
  const e = esquema;
  if (e.type === 'object') {
    assert.equal(e.additionalProperties, false, `${donde}: falta additionalProperties: false`);
    const propiedades = propiedadesDe(e);
    const requeridas = Array.isArray(e.required) ? e.required : [];
    for (const r of requeridas) assert.ok(String(r) in propiedades, `${donde}: requerida sin propiedad ${r}`);
    for (const [k, v] of Object.entries(propiedades)) comprobarEstricto(v, `${donde}.${k}`);
  }
  if (e.items) comprobarEstricto(e.items, `${donde}[]`);
  for (const prohibida of ['minimum', 'maximum', 'minLength', 'maxLength', 'multipleOf']) {
    assert.ok(!(prohibida in e), `${donde}: «${prohibida}» no vale en strict`);
  }
}

Deno.test('la lista cerrada: 28 de datos y 3 de presentación, sin nombres repetidos', () => {
  assert.equal(deDatos.length, 28);
  assert.equal(HERRAMIENTAS.length, 31);
  assert.equal(new Set(HERRAMIENTAS.map((h) => h.nombre)).size, HERRAMIENTAS.length);
  assert.deepEqual(new Set(deDatos.map((h) => h.rpc)), new Set(Object.keys(FIRMAS)));
});

Deno.test('cada esquema es un objeto cerrado y cada definición dice cuándo usarla', () => {
  for (const h of HERRAMIENTAS) comprobarEstricto(h.esquema, h.nombre);
  for (const d of definiciones()) {
    assert.equal(d.esquema.type, 'object');
    assert.ok(d.descripcion.length > 40, `${d.nombre}: descripción pobre`);
  }
});

Deno.test('cada herramienta de datos traduce su entrada a los p_* de su RPC', () => {
  for (const h of deDatos) {
    const caso = CASOS[h.nombre];
    assert.ok(caso, `falta el caso de ${h.nombre}`);
    const args = h.argumentos(caso.entrada);
    assert.deepEqual(args, caso.args, h.nombre);
    for (const clave of Object.keys(args)) {
      assert.ok(FIRMAS[h.rpc].includes(clave), `${h.nombre}: ${clave} no es un parámetro de ${h.rpc}`);
    }
    // El caso usa todas las propiedades del esquema: ninguna queda sin probar.
    for (const p of Object.keys(propiedadesDe(h.esquema))) {
      assert.ok(p in caso.entrada, `${h.nombre}: el caso no prueba «${p}»`);
    }
  }
});

Deno.test('los rangos se recortan y lo que no encaja se descarta', () => {
  const semanal = deDatosLlamada('admin_weekly_summary');
  assert.deepEqual(semanal.argumentos({ semanas: 500 }), { p_weeks: 52 });
  assert.deepEqual(semanal.argumentos({ semanas: -3 }), { p_weeks: 1 });
  assert.deepEqual(semanal.argumentos({ semanas: 'doce' }), {});
  const economia = deDatosLlamada('admin_unit_economics');
  assert.deepEqual(economia.argumentos({ desde: '2026-02-30', hasta: 'ayer' }), {});
  const impago = deDatosLlamada('admin_first_payment_default');
  assert.deepEqual(impago.argumentos({ dimension: 'pais' }), {});
  // «grupo» es de Ronda: en Helios no hay órdenes en grupo.
  assert.deepEqual(impago.argumentos({ dimension: 'grupo', cuota: 3 }), { p_cuota: 2 });
  const alertas = deDatosLlamada('admin_risk_alerts');
  assert.deepEqual(alertas.argumentos({ tipos: ['inventado'] }), { p_limit: 50 });
});

Deno.test('un uuid obligatorio que no es uuid vuelve al modelo y no llama a la base', async () => {
  const llamadas: Array<[string, unknown]> = [];
  const r = await ejecutarHerramienta(herramienta('admin_user_detail'), { persona_id: 'María' }, {
    base: baseDeMentira({ data: {}, error: null }, llamadas),
    mapa: MAPA,
  });
  assert.equal(r.esError, true);
  assert.match(r.contenido, /persona_id/);
  assert.equal(llamadas.length, 0);
});

Deno.test('una lista de pacientes llega con el nombre acortado, el teléfono y la cédula tapados y sin correo', async () => {
  const filas = [{ full_name: 'JAVIER CARVAJAL', phone_e164: '+584141234567', document_number: 'V-12345678', email: 'j@x.com', available_usd: 9 }];
  const r = await ejecutarHerramienta(herramienta('admin_user_directory'), { buscar: 'javier' }, {
    base: baseDeMentira({ data: filas, error: null }),
    mapa: MAPA,
  });
  const leido = JSON.parse(r.contenido);
  assert.equal(leido[0].full_name, 'JAVIER C.');
  assert.equal(leido[0].phone_e164, '+58•••••••567');
  assert.equal(leido[0].document_number, 'V-•••••678');
  assert.equal(leido[0].email, '(oculto)');
  assert.ok(!('available_usd' in leido[0]), 'el límite viejo no llega');
});

Deno.test('la ficha de un paciente trae su nombre entero, pero el teléfono tapado y sin lo que pesa', async () => {
  const ficha = {
    full_name: 'JAVIER CARVAJAL',
    phone_e164: '+584141234567',
    devices: [{ id: 1 }],
    bits_entries: [],
    charges: [],
    credit: { available_usd: 17.37, available_now_usd: 9 },
  };
  const r = await ejecutarHerramienta(herramienta('admin_user_detail'), { persona_id: ID }, {
    base: baseDeMentira({ data: ficha, error: null }),
    mapa: MAPA,
  });
  const leido = JSON.parse(r.contenido);
  assert.equal(leido.full_name, 'JAVIER CARVAJAL');
  assert.equal(leido.phone_e164, '+58•••••••567');
  assert.deepEqual(leido.credit, { available_now_usd: 9 });
  assert.ok(!('devices' in leido) && !('charges' in leido) && !('bits_entries' in leido));
});

Deno.test('ninguna orden llega con el total que lleva la comisión, y la foto general va sin KYC', async () => {
  const r = await ejecutarHerramienta(herramienta('admin_charges'), {}, {
    base: baseDeMentira({ data: [{ order_number: 1209, amount_usd: 7.39, financed_usd: 6 }], error: null }),
    mapa: MAPA,
  });
  assert.deepEqual(JSON.parse(r.contenido), [{ order_number: 1209, financed_usd: 6 }]);

  const resumen = recortarResumenGeneral({
    kyc: null,
    volume: { financed_usd: 63.78, avg_ticket_usd: 7.97, financed_volume_usd: 51.5, charge_count: 8 },
    bad_debt: { rate_pct: 0, rate_financed_pct: 0, break_even_pct: 15.56 },
    arrears: { rate_pct: 7.8 },
  });
  assert.deepEqual(resumen, {
    volume: { financed_volume_usd: 51.5, charge_count: 8 },
    bad_debt: { rate_financed_pct: 0, break_even_pct: 15.56 },
    arrears: { rate_pct: 7.8 },
  });
});

Deno.test('un fallo de la base vuelve al modelo como error, con el mensaje de la base', async () => {
  const r = await ejecutarHerramienta(herramienta('admin_unit_economics'), {}, {
    base: baseDeMentira({ data: null, error: { message: 'El rango de fechas está al revés', code: '22023' } }),
    mapa: MAPA,
  });
  assert.equal(r.esError, true);
  assert.match(r.contenido, /al revés/);

  const vacio = await ejecutarHerramienta(herramienta('admin_collection_case'), { persona_id: ID }, {
    base: baseDeMentira({ data: null, error: null }),
    mapa: MAPA,
  });
  assert.equal(vacio.esError, false);
  assert.match(vacio.contenido, /Sin resultado/);
});

Deno.test('un resultado enorme se corta por las listas y lo avisa', () => {
  const filas = Array.from({ length: 2000 }, (_, i) => ({ i, nombre: 'x'.repeat(40) }));
  const texto = serializarAcotado({ rows: filas }, 30000);
  assert.ok(texto.length <= 30000);
  const leido = JSON.parse(texto);
  assert.match(leido._aviso, /primeros \d+ elementos/);
  assert.ok(leido.rows.length < 2000);
  assert.equal(serializarAcotado({ a: 1 }), '{"a":1}');
});

Deno.test('mostrar_tabla convierte las filas en objetos y se queda en 50', async () => {
  const filas = Array.from({ length: 60 }, (_, i) => [`Clínica ${i}`, i * 1.5]);
  const r = await ejecutarHerramienta(herramienta('mostrar_tabla'), {
    titulo: 'Mora por clínica',
    columnas: [{ clave: 'clinica', rotulo: 'Clínica', unidad: 'texto' }, { clave: 'mora', rotulo: 'Mora', unidad: 'usd' }],
    filas,
  }, { base: baseDeMentira({ data: null, error: null }), mapa: MAPA });
  assert.equal(r.esError, false);
  assert.match(r.contenido, /primeras 50 filas de 60/);
  assert.ok(r.evento && r.evento.tipo === 'tabla');
  if (r.evento?.tipo === 'tabla') {
    assert.equal(r.evento.datos.filas.length, 50);
    assert.deepEqual(r.evento.datos.filas[1], { clinica: 'Clínica 1', mora: 1.5 });
    // El modelo dice `usd`; al panel le llega la unidad de dinero del protocolo.
    assert.equal(r.evento.datos.columnas[1].unidad, 'eur');
  }
});

Deno.test('mostrar_grafico rechaza un punto sin valor y acepta la segunda serie', async () => {
  const contexto = { base: baseDeMentira({ data: null, error: null }), mapa: MAPA };
  const malo = await ejecutarHerramienta(herramienta('mostrar_grafico'), {
    tipo: 'barras', titulo: 'x', unidad: 'usd', puntos: [{ etiqueta: 'a' }],
  }, contexto);
  assert.equal(malo.esError, true);
  // `eur` ya no es una unidad que pueda pedir el modelo.
  const euros = await ejecutarHerramienta(herramienta('mostrar_grafico'), {
    tipo: 'barras', titulo: 'x', unidad: 'eur', puntos: [{ etiqueta: 'a', valor: 1 }],
  }, contexto);
  assert.equal(euros.esError, true);

  const bueno = await ejecutarHerramienta(herramienta('mostrar_grafico'), {
    tipo: 'lineas', titulo: 'Financiado por semana ($)', unidad: 'usd',
    puntos: [{ etiqueta: '2026-09-14', valor: 10, valor2: 4 }, { etiqueta: '2026-09-21', valor: 44 }],
    leyenda: { valor: 'Financiado', valor2: 'Perdido' },
  }, contexto);
  assert.equal(bueno.contenido, 'ok');
  assert.deepEqual(bueno.evento, {
    tipo: 'grafico',
    datos: {
      tipo: 'lineas', titulo: 'Financiado por semana ($)', unidad: 'eur',
      puntos: [{ etiqueta: '14 sep', valor: 10, valor2: 4 }, { etiqueta: '21 sep', valor: 44 }],
      leyenda: { valor: 'Financiado', valor2: 'Perdido' },
    },
  });
});
