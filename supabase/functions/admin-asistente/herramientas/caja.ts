/** Caja y contabilidad: el dinero que hay, el que entra y el que se debe a las clínicas. */

import { DESDE, entero, esFila, HASTA, leerEntero, objeto, rango, sinClaves, sinParametros, sinVacios } from './esquema.ts';
import type { HerramientaDeDatos } from './tipos.ts';

/**
 * `admin_overview` arrastra campos viejos que llevan la comisión dentro
 * (`volume.financed_usd`, `avg_ticket_usd`) o que cuentan solo a quien abrió
 * la orden, y los de la verificación de identidad, que Helios no hace. El
 * modelo no los ve.
 */
export function recortarResumenGeneral(datos: unknown): unknown {
  if (!esFila(datos)) return datos;
  const { kyc: _kyc, ...resto } = datos;
  return {
    ...resto,
    volume: sinClaves(datos.volume, ['financed_usd', 'previous_usd', 'avg_ticket_usd', 'active_users']),
    bad_debt: sinClaves(datos.bad_debt, ['financed_usd', 'written_off_usd', 'window_usd', 'rate_pct']),
  };
}

export const caja: HerramientaDeDatos[] = [
  {
    clase: 'datos',
    nombre: 'admin_overview',
    rpc: 'admin_overview',
    rotulo: 'Leyendo la foto general',
    descripcion:
      'Contesta «¿cuánto dinero hay en caja?» (cash.cash) y la foto general del negocio en una ventana de días: ' +
      'financiado y su cambio, monto medio por orden, pacientes con orden, deuda vencida de hoy (arrears), impago ' +
      'histórico frente al punto de equilibrio, saldos del libro (cash), colas pendientes y la tasa BCV (fx). NO ' +
      'contesta lo que se debe a cada clínica (admin_merchant_payables; cash.merchant_payable es un saldo del ' +
      'libro, no esa cifra) ni lo recuperado de cuotas vencidas (admin_collection_recovered). Clases: ' +
      'volume.financed_volume_usd, avg_ticket_financed_usd y bad_debt.*_financed_usd son financiado, sin comisión; ' +
      'arrears.* es deuda con la comisión (mora = deuda vencida sobre deuda viva); cash.* son saldos del libro, ' +
      'cada uno por separado.',
    esquema: objeto({ dias: entero('Ventana en días, de 1 a 365. Por defecto 30.') }),
    argumentos: (e) => sinVacios({ p_days: leerEntero(e.dias, 1, 365) }),
    recortar: recortarResumenGeneral,
    pantalla: { ruta: '/admin/metricas', search: { vista: 'caja' } },
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_merchant_payables',
    rpc: 'admin_merchant_payables',
    rotulo: 'Leyendo lo que se debe a las clínicas',
    descripcion:
      'Contesta «¿cuánto le debemos a las clínicas?»: por clínica (merchant_name, con su médico titular en ' +
      'doctor_name), lo pendiente total (total_pending_usd, la cifra que se da), lo vencido (overdue_usd), lo que ' +
      'vence (upcoming_usd), el próximo pago con su fecha y su monto (next_pay_date, next_pay_usd: se paga a ' +
      'diario, el día siguiente a cada vencimiento de cuota) y el último pago hecho. A la clínica se le paga el ' +
      '100 % de la consulta, pague o no el paciente; comisiones_usd son comisiones del personal, aparte. NO ' +
      'contesta la mora de las clínicas (admin_merchant_risk).',
    esquema: sinParametros(),
    argumentos: () => ({}),
    pantalla: { ruta: '/admin/pagos-clinicas' },
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_reconciliation_health',
    rpc: 'admin_reconciliation_health',
    rotulo: 'Leyendo la salud de los pagos reportados',
    descripcion:
      'Contesta «¿cuántos pagos reportados hay por aprobar?» (queue.count, la cola de ahora por antigüedad) y cómo ' +
      'se aprueban: pagos resueltos en el rango (aprobados, rechazados, duplicados), cuántos aprobados tienen su ' +
      'movimiento en el extracto del banco, tiempos de resolución en minutos y hasta qué día está importado el ' +
      'extracto. queue.*.usd es deuda con la comisión (lo que el paciente dice haber pagado). Sin fechas, los ' +
      'últimos 30 días; la cola es siempre la de ahora.',
    esquema: objeto({ desde: DESDE, hasta: HASTA }),
    argumentos: (e) => sinVacios(rango(e)),
    // Pagos reportados es la vista por defecto de /admin/cobros (la otra son los abonos sin dueño).
    pantalla: { ruta: '/admin/cobros', search: { tab: 'pendientes' } },
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_cash_forecast',
    rpc: 'admin_cash_forecast',
    rotulo: 'Leyendo la proyección de caja',
    descripcion:
      'Contesta si el dinero alcanza en las próximas semanas: caja de hoy y, por semana, lo que se espera cobrar ' +
      'de cuotas (con la comisión, deuda), lo que sale hacia las clínicas y el neto.',
    esquema: objeto({ semanas: entero('Semanas hacia adelante, de 1 a 12. Por defecto 4.') }),
    argumentos: (e) => sinVacios({ p_weeks: leerEntero(e.semanas, 1, 12) }),
    pantalla: { ruta: '/admin/metricas', search: { vista: 'caja', sub: 'proyeccion' } },
    datosPersonales: 'lista',
  },
];
