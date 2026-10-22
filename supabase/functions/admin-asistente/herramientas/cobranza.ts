/** Cobranza: quién debe, qué prometió y si lo que se hace funciona. */

import { DESDE, entero, HASTA, leerEntero, objeto, rango, sinVacios } from './esquema.ts';
import type { HerramientaDeDatos, PantallaDeHerramienta } from './tipos.ts';

const DEUDA =
  'Los montos son deuda, con la Comisión Helios dentro (lo que el paciente tiene que pagar); nunca se mezclan con ' +
  'lo financiado.';

const RENDIMIENTO: PantallaDeHerramienta = { ruta: '/admin/metricas', search: { vista: 'mora', sub: 'rendimiento' } };

export const cobranza: HerramientaDeDatos[] = [
  {
    clase: 'datos',
    nombre: 'admin_collections',
    rpc: 'admin_collections',
    rotulo: 'Leyendo la cartera vencida',
    descripcion:
      'Contesta quién debe AHORA: «¿cuánta deuda vencida hay?», «¿a quién hay que llamar hoy?», «¿quién lleva más ' +
      'días de atraso?». Una fila por paciente con cuotas vencidas o que vencen dentro del horizonte, con tramo ' +
      '(bucket), días de atraso, montos, las clínicas donde se atendió (merchants), última gestión, promesa y último ' +
      'pago. NO contesta cuánto se recuperó (admin_collection_recovered). ' + DEUDA +
      ' Nombres acortados; teléfono y cédula tapados.',
    esquema: objeto({
      horizonte_dias: entero('Incluye también lo que vence en estos días, de 0 a 30. Por defecto 3.'),
    }),
    argumentos: (e) => sinVacios({ p_horizon_days: leerEntero(e.horizonte_dias, 0, 30) }),
    pantalla: { ruta: '/admin/cobranza' },
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_collection_promises',
    rpc: 'admin_collection_promises',
    rotulo: 'Leyendo las promesas de pago',
    descripcion:
      'Contesta sobre promesas de pago: las que vencen hoy, las pendientes, las cumplidas y las rotas, con quién la ' +
      'hizo, quién la anotó y el último pago después de la gestión. Filtra por la fecha prometida. Sin fechas: ' +
      'desde hace 30 días y todas las futuras. ' + DEUDA,
    esquema: objeto({ desde: DESDE, hasta: HASTA }),
    argumentos: (e) => sinVacios(rango(e)),
    pantalla: { ruta: '/admin/cobranza', search: { vista: 'promesas' } },
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_collection_recovered',
    rpc: 'admin_collection_recovered',
    rotulo: 'Leyendo lo recuperado',
    descripcion:
      'Contesta «¿cuánto se recuperó?» (esta semana, este mes, en un rango): la cifra es recovered.usd, las cuotas ' +
      'cobradas en el rango que ya estaban vencidas al pagarse, con su número (recovered.installments) y por tramo ' +
      'de atraso; y recovery_pct, qué parte de lo vencido al empezar el rango (overdue_at_start) se cobró. NO la ' +
      'confundas con admin_weekly_summary, que no mide lo recuperado. Rango en días; para «esta semana», desde el ' +
      'lunes; sin fechas, los últimos 30 días. ' + DEUDA,
    esquema: objeto({ desde: DESDE, hasta: HASTA }),
    argumentos: (e) => sinVacios(rango(e)),
    pantalla: RENDIMIENTO,
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_contact_effectiveness',
    rpc: 'admin_contact_effectiveness',
    rotulo: 'Leyendo el rendimiento de las gestiones',
    descripcion:
      'Contesta si las gestiones de cobranza funcionan: gestiones y cuántas tuvieron un pago en las 72 horas ' +
      'siguientes, por canal, por resultado y por hora del día. rate_pct solo cuenta las gestiones cuya ventana ya ' +
      'cerró; es una señal, no una causa. Sin fechas, los últimos 30 días.',
    esquema: objeto({ desde: DESDE, hasta: HASTA }),
    argumentos: (e) => sinVacios(rango(e)),
    pantalla: RENDIMIENTO,
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_collection_flow',
    rpc: 'admin_collection_flow',
    rotulo: 'Leyendo cómo se mueve la cartera',
    descripcion:
      'Contesta cómo se mueve la cartera vencida entre tramos semana a semana: pacientes por tramo en cada lunes, ' +
      'transiciones desde el lunes anterior y cuántos de cada tramo se pusieron al día. ' + DEUDA,
    esquema: objeto({ semanas: entero('Cuántos lunes hacia atrás, de 1 a 26. Por defecto 8.') }),
    argumentos: (e) => sinVacios({ p_weeks: leerEntero(e.semanas, 1, 26) }),
    pantalla: RENDIMIENTO,
    datosPersonales: 'lista',
  },
];
