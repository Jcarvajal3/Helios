import type { Entrada } from '../tipos'

/**
 * Las cifras nuevas de la pestaña Clínicas de Métricas, para la búsqueda
 * (Ctrl K) y el asistente.
 *
 * Las que ya existían no se repiten aquí: «Rendimiento de las clínicas»
 * (`catalogo/directorio.ts`) y «Clínicas por volumen» (`catalogo/riesgo.ts`)
 * ya apuntan a esta pestaña. Todas salen de `admin_metricas_locales` y todas
 * respetan la semana y la clínica de arriba.
 */
export const metricasLocales = [
  {
    tipo: 'cifra',
    id: 'consumo-por-semana-de-cada-local',
    titulo: 'Financiado por semana y clínica (sin comisión)',
    descripcion: 'El financiado de cada clínica semana a semana, sin la Comisión Helios, todos con la misma escala.',
    espacio: 'metricas',
    sinonimos: [
      'financiamiento por semana de cada clínica',
      'financiamiento por semana',
      'pequeños múltiplos',
      'evolución por clínica',
      'financiamientos por semana por clínica',
      'tendencia de las clínicas',
      'crecimiento por clínica',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'locales' } },
    que: 'Sin la Comisión Helios: el financiado de cada clínica en las ocho últimas semanas hasta la elegida, con una escala común para que las alturas se comparen. La nota dice cuándo empezó a financiar una clínica nueva o cómo va frente a la semana anterior a la misma altura.',
    rpc: 'admin_metricas_locales',
  },
  {
    tipo: 'cifra',
    id: 'como-paga-la-gente-de-cada-local',
    titulo: 'Cuota 1 cobrada a tiempo (%), por clínica',
    descripcion: 'La cuota 1 cobrada a tiempo de lo financiado en cada clínica, semana de financiamiento a semana de financiamiento.',
    espacio: 'metricas',
    sinonimos: [
      'cómo pagan los pacientes de cada clínica',
      'cómo pagan los pacientes',
      'cobro a tiempo por clínica',
      'mora por clínica',
      'calidad de los pacientes de una clínica',
      'qué clínica paga mejor',
      'primera cuota por clínica',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'locales' } },
    que: 'De las cuotas 1 de lo financiado en cada clínica cada semana, las pagadas a tiempo entre las que ya cerraron su plazo (el vencimiento más los días de gracia). Una semana sin financiamientos no es un cero, y una todavía en plazo no tiene veredicto. Es la misma cuenta que Métricas › Cobros.',
    rpc: 'admin_metricas_locales',
  },
  {
    tipo: 'cifra',
    id: 'vencido-de-la-gente-de-un-local',
    titulo: 'Vencido por clínica (financiamiento + comisión)',
    descripcion: 'Las cuotas vencidas y sin pagar de los financiamientos en cada clínica (financiamiento + comisión), con su financiamiento y su Comisión Helios por separado.',
    espacio: 'metricas',
    sinonimos: ['vencido de los pacientes de una clínica', 'vencido de sus pacientes', 'deuda por clínica', 'vencido por clínica', 'cartera por clínica', 'impago de una clínica'],
    destino: { to: '/admin/metricas', search: { vista: 'locales' } },
    que: 'Las cuotas vencidas y sin pagar de lo financiado en cada clínica, al cierre de la semana elegida (hoy, si está en curso), en financiamiento + comisión: su financiamiento y la Comisión Helios (IVA incluido), siempre por separado. Lo dado por perdido no entra. La suma de las clínicas es el vencido de toda la cartera.',
    rpc: 'admin_metricas_locales',
  },
  {
    tipo: 'cifra',
    id: 'se-le-transfiere-el-lunes',
    titulo: 'Liquidación de la semana, por clínica (neto)',
    descripcion: 'Lo que se le paga a cada clínica por las cuotas que vencen en la semana, cada mitad el día siguiente a su vencimiento.',
    espacio: 'metricas',
    sinonimos: [
      'lo que se le transfiere a cada clínica el lunes',
      'se le transfiere el lunes',
      'liquidación de la semana',
      'pago a la clínica',
      'transferencia a la clínica',
      'cierre del lunes por clínica',
      'cuánto le pagamos',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'locales' } },
    que: 'Por clínica, las liquidaciones de las cuotas que vencen de lunes a domingo, que se le transfieren se paguen o no, cada una el día siguiente a su vencimiento (de martes a lunes): lo ya generado más lo que el cron generará hasta el domingo con las condiciones del día de cada financiamiento. Es su neto, que no lleva la Comisión Helios, y la misma cuenta que Pagos a clínicas. Lo atrasado de semanas anteriores va aparte.',
    rpc: 'admin_metricas_locales',
  },
  {
    tipo: 'cifra',
    id: 'cobrado-a-tiempo-en-la-semana-por-local',
    titulo: 'Cobrado a tiempo (%) de las cuotas que vencían en la semana, por clínica',
    descripcion: 'De las cuotas de los financiamientos en cada clínica que vencían en la semana, las pagadas a tiempo.',
    espacio: 'metricas',
    sinonimos: ['cobrado a tiempo en la semana, por clínica', 'a tiempo por clínica', 'puntualidad por clínica', 'cuotas de la semana por clínica'],
    destino: { to: '/admin/metricas', search: { vista: 'locales' } },
    que: 'Las cuotas de lo financiado en cada clínica que vencían entre el lunes y el domingo y ya cerraron su plazo, y cuántas se pagaron dentro de él. Las que siguen en plazo todavía no cuentan.',
    rpc: 'admin_metricas_locales',
  },
] as const satisfies ReadonlyArray<Entrada>
