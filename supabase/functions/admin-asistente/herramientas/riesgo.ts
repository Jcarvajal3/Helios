/** Riesgo: a quién se le cobra en cuotas, cuánto, y si paga. */

import {
  entero,
  filasSinClaves,
  leerEntero,
  leerOpcion,
  objeto,
  opcion,
  sinParametros,
  sinVacios,
} from './esquema.ts';
import type { HerramientaDeDatos } from './tipos.ts';

export const DIMENSIONES_PRIMERA_CUOTA = ['mes', 'semana', 'local', 'nivel', 'primera_compra'] as const;

/** Las alertas de Helios (`admin_risk_alerts`), no las de la app de Ronda. */
export const TIPOS_DE_ALERTA = [
  'telefono_repetido',
  'correo_repetido',
  'correo_rebotado',
  'rafaga_de_altas',
  'rafaga_de_pacientes_nuevos',
  'secretaria_concentrada',
  'impago_primera_cuota_clinica',
  'exposicion_clinica',
  'referencia_repetida',
  'cupo_al_limite_al_estrenar',
  'consultas_de_cedula_excesivas',
  'consumo_sobre_cupo',
] as const;

/**
 * Columnas viejas de `admin_merchant_risk` que suman la comisión
 * (`financed_usd`, `volume_share_pct`) o cuentan lo dado por perdido como mora
 * (`overdue_usd`, `arrears_pct`), o solo a quien abrió la orden.
 */
const COLUMNAS_VIEJAS_DE_LOCAL = ['financed_usd', 'volume_share_pct', 'overdue_usd', 'arrears_pct', 'distinct_users'];

export const riesgo: HerramientaDeDatos[] = [
  {
    clase: 'datos',
    nombre: 'admin_first_payment_default',
    rpc: 'admin_first_payment_default',
    rotulo: 'Leyendo el impago por cuota',
    descripcion:
      'Contesta «¿cómo va el impago de la primera cuota?» (o de la segunda, con cuota: 2): quién no paga la cuota, ' +
      'impago temprano (tras la gracia, defaulted_pct) y a 30 días (defaulted_30_pct), sobre cuotas maduras, en ' +
      'total (total) y partido por mes, semana, clínica (local), nivel o si fue la primera orden del paciente ' +
      '(primera_compra). Un porcentaje null significa que todavía no hay cuotas maduras con qué medirlo, no un cero. ' +
      'Los montos *_financed_usd son financiado, sin comisión.',
    esquema: objeto({
      meses: entero('Meses de órdenes hacia atrás, de 1 a 24. Por defecto 6.'),
      dimension: opcion(DIMENSIONES_PRIMERA_CUOTA, 'Cómo se parte («local» es por clínica). Por defecto mes.'),
      cuota: entero('Qué cuota se mide: 1 o 2. Por defecto 1.'),
    }),
    argumentos: (e) =>
      sinVacios({
        p_months: leerEntero(e.meses, 1, 24),
        p_dim: leerOpcion(e.dimension, DIMENSIONES_PRIMERA_CUOTA),
        p_cuota: leerEntero(e.cuota, 1, 2),
      }),
    pantalla: { ruta: '/admin/metricas', search: { vista: 'cobros', sub: 'impago-por-cuota' } },
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_credit_utilization',
    rpc: 'admin_credit_utilization',
    rotulo: 'Leyendo el uso del límite',
    descripcion:
      'Contesta cuánto límite tienen ocupado los pacientes, por nivel: pacientes, límite total, límite ocupado, ' +
      'disponible, lo que se puede usar hoy (spendable_now_usd) y la exposición. Todos los montos son financiado, ' +
      'sin comisión.',
    esquema: sinParametros(),
    argumentos: () => ({}),
    pantalla: { ruta: '/admin/metricas', search: { vista: 'mora', sub: 'cupos' } },
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_risk_alert_counts',
    rpc: 'admin_risk_alert_counts',
    rotulo: 'Contando las alertas de riesgo',
    descripcion:
      'Contesta «¿cuántas alertas hay sin revisar?»: alertas de riesgo sin revisar de gravedad alta ' +
      '(pendientes_alta) y media (pendientes_media), y cuántas revisadas. Para ver cuáles son, admin_risk_alerts.',
    esquema: sinParametros(),
    argumentos: () => ({}),
    pantalla: { ruta: '/admin/alertas' },
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_risk_alerts',
    rpc: 'admin_risk_alerts',
    rotulo: 'Leyendo las alertas de riesgo',
    descripcion:
      'Contesta cuáles son las alertas de riesgo: pacientes con el mismo teléfono o correo, correos que rebotan, ' +
      'ráfagas de órdenes o de pacientes nuevos en una clínica, una secretaria que concentra las órdenes de su ' +
      'clínica, clínicas con mucho impago de la primera cuota o mucha exposición, referencias de pago repetidas, ' +
      'pacientes que estrenan con el límite casi lleno, consultas de cédula excesivas del personal y órdenes que ' +
      'pasaron del límite. Sin revisar primero y las de gravedad alta antes. counts trae los totales sin filtrar. ' +
      'Para solo contarlas, admin_risk_alert_counts. Los montos son financiado, sin comisión.',
    esquema: objeto({
      tipos: {
        type: 'array',
        items: { type: 'string', enum: [...TIPOS_DE_ALERTA] },
        description: 'Solo estos tipos. Si se omite, todos.',
      },
      limite: entero('Cuántas filas como mucho, de 1 a 200. Por defecto 50.'),
    }),
    argumentos: (e) => {
      const tipos = Array.isArray(e.tipos)
        ? e.tipos.flatMap((t) => {
          const v = leerOpcion(t, TIPOS_DE_ALERTA);
          return v ? [v] : [];
        })
        : [];
      return sinVacios({
        p_limit: leerEntero(e.limite, 1, 200) ?? 50,
        p_kinds: tipos.length > 0 ? [...new Set(tipos)] : undefined,
      });
    },
    pantalla: { ruta: '/admin/alertas' },
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_cohort_curves',
    rpc: 'admin_cohort_curves',
    rotulo: 'Leyendo las curvas de cada cosecha',
    descripcion:
      'Contesta cómo se comparan las cosechas (mes de la orden) a la misma edad: por semana de edad, qué parte está ' +
      'vencida sin pagar y qué parte se dio por perdida. Una celda con complete false mide solo una parte de la ' +
      'cosecha y hay que decirlo. Todo es financiado, sin comisión.',
    esquema: objeto({ meses: entero('Cosechas hacia atrás, de 1 a 24. Por defecto 6.') }),
    argumentos: (e) => sinVacios({ p_months: leerEntero(e.meses, 1, 24) }),
    pantalla: { ruta: '/admin/metricas', search: { vista: 'cobros' } },
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_merchant_risk',
    rpc: 'admin_merchant_risk',
    rotulo: 'Leyendo el riesgo por clínica',
    descripcion:
      'Contesta «¿qué clínicas tienen más mora?» (overdue_debt_pct, sin lo dado por perdido) y el peso de cada ' +
      'clínica: financiado y su peso, pacientes, deuda generada, deuda vencida, impago y lo pendiente de pagarle. ' +
      'También da el merchant_id de una clínica por su nombre. NO contesta cuánto se les debe en total a las ' +
      'clínicas (admin_merchant_payables). Clases: financed_volume_usd y written_off_financed_usd son financiado, ' +
      'sin comisión; billed_debt_usd y overdue_debt_usd son deuda con la comisión.',
    esquema: objeto({ dias: entero('Ventana en días, de 1 a 365. Por defecto 90.') }),
    argumentos: (e) => sinVacios({ p_days: leerEntero(e.dias, 1, 365) }),
    recortar: (datos) => filasSinClaves(datos, COLUMNAS_VIEJAS_DE_LOCAL),
    pantalla: { ruta: '/admin/metricas', search: { vista: 'locales' } },
    datosPersonales: 'lista',
  },
];
