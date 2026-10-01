import type { Entrada } from '../tipos'

/**
 * Las cifras, acciones y términos de la pestaña Semana de Métricas, para la
 * búsqueda (Ctrl K) y el asistente. Solo lo NUEVO de la pestaña: el financiado,
 * el service fee y las metas de la semana ya están en `gerencia.ts`
 * (`financiado-de-la-semana`, `ingreso-por-servicio`, `metas-del-negocio`), y
 * la mora, el cobro a tiempo y la caja de hoy en los archivos de su equipo.
 */
export const metricasSemana = [
  {
    tipo: 'cifra',
    id: 'semana-a-semana',
    titulo: 'Semana a semana',
    descripcion:
      'Todas las cifras del negocio, una columna por semana, con la semana elegida frente a la anterior.',
    espacio: 'metricas',
    sinonimos: [
      'tabla semanal',
      'evolución semanal',
      'comparar semanas',
      'semana contra semana',
      'histórico por semana',
      'week over week',
      'mora al cierre de cada semana',
      'caja al cierre de cada semana',
      'cobro a tiempo por semana',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'semana', sub: 'rendimiento' } },
    que: 'Financiamiento, ingreso de Helios, cobro, riesgo, pacientes y caja de las últimas 8, 12 o 26 semanas (de lunes a domingo, por día operativo), de todas las clínicas o de una. La semana elegida va al final y se compara con la anterior; si está en curso, con la anterior hasta el mismo momento. El total financiado va sin el service fee; el importe de las cuotas va con su financiado y su service fee + IVA en filas aparte.',
    rpc: 'admin_metricas_semanas',
  },
  {
    tipo: 'cifra',
    id: 'cuotas-que-vencian',
    titulo: 'Cuotas que vencían en la semana (financiado + fee)',
    descripcion: 'El importe de las cuotas que vencían cada semana: el financiado (sin fee) más el service fee + IVA, con las dos partes.',
    espacio: 'metricas',
    sinonimos: ['vencimientos de la semana', 'lo que vencía', 'cuotas de la semana', 'por cobrar de la semana'],
    destino: { to: '/admin/metricas', search: { vista: 'semana', sub: 'rendimiento' } },
    que: 'La suma de las cuotas cuyo vencimiento caía en la semana (hasta hoy si está en curso), pagadas o no: el financiado (sin fee) más el service fee + IVA, que se enseñan siempre como dos líneas aparte.',
    rpc: 'admin_metricas_semanas',
  },
  {
    tipo: 'accion',
    id: 'descargar-semana-a-semana',
    titulo: 'Descargar la semana a semana en CSV',
    descripcion: 'La tabla de Métricas › Semana › Rendimiento, con las columnas elegidas, en un archivo para Excel.',
    espacio: 'metricas',
    sinonimos: ['exportar semanas', 'csv semanal', 'excel de la semana', 'bajar la tabla'],
    destino: { to: '/admin/metricas', search: { vista: 'semana', sub: 'rendimiento' } },
  },
  {
    tipo: 'termino',
    id: 'a-la-misma-altura',
    titulo: 'A la misma altura',
    descripcion: 'Cómo se compara una semana que todavía no ha terminado.',
    espacio: 'metricas',
    sinonimos: ['mismos días', 'semana en curso', 'comparar con la semana anterior', 'hasta el mismo momento'],
    destino: { to: '/admin/metricas', search: { vista: 'semana' } },
    definicion:
      'Una semana en curso se compara con la semana anterior hasta el mismo momento (hace exactamente siete días), nunca con la anterior entera ni con sus días enteros: el sábado a las 15:00 se mide contra el lunes hasta el sábado a las 15:00 de la semana pasada, sin el día del sábado. Lo que es foto (lo vencido, la mora, la caja) se toma al cierre del día equivalente, y el cobro a tiempo se juzga con los mismos días de vencimiento.',
  },
  // ── Semana › Resumen (sub-pestaña por defecto de Semana) ─────────────────
  // El destino es Métricas a secas: Semana es la pestaña por defecto y
  // Resumen su sub-pestaña por defecto.
  {
    tipo: 'cifra',
    id: 'total-facturado-de-la-semana',
    titulo: 'Total financiado de la semana (sin fee)',
    descripcion: 'Lo financiado en las clínicas en la semana, sin el service fee, frente a la semana anterior.',
    espacio: 'metricas',
    sinonimos: [
      'total financiado',
      'financiado',
      'facturación de la semana',
      'cuánto se facturó',
      'financiamientos de la semana',
      'financiamiento sin fee',
      'resumen de la semana',
    ],
    destino: { to: '/admin/metricas' },
    que: 'Sin el service fee: la suma de los financiamientos confirmados de la semana (de lunes a domingo, por día operativo; la semana en curso, hasta ahora), de todas las clínicas o de una. Es la fila «Total financiado» de Semana › Rendimiento. Se compara con la semana anterior a la misma altura y va junto al service fee + IVA y al total a cobrar, que suman con él.',
    rpc: 'admin_metricas_semana_resumen',
  },
  {
    tipo: 'cifra',
    id: 'service-fee-e-iva-de-la-semana',
    titulo: 'Service fee + IVA de la semana',
    descripcion: 'El service fee de los financiamientos de la semana con su IVA, partido en el fee sin IVA y el IVA.',
    espacio: 'metricas',
    sinonimos: ['service fee', 'fee de la semana', 'fee más iva', 'iva del fee', 'servicio', 'servicio de helios', 'comisión'],
    destino: { to: '/admin/metricas' },
    que: 'El service fee de los financiamientos de la semana con su IVA dentro: el total a cobrar menos el total financiado. Se enseña partido en el service fee sin IVA (el ingreso de Helios) y el IVA, y siempre entre el total financiado y el total a cobrar, frente a la semana anterior a la misma altura.',
    rpc: 'admin_metricas_semana_resumen',
  },
  {
    tipo: 'cifra',
    id: 'total-a-cobrar-de-la-semana',
    titulo: 'Total a cobrar de la semana',
    descripcion: 'Lo que se cobra en cuotas por los financiamientos de la semana: el total financiado más el service fee y su IVA.',
    espacio: 'metricas',
    sinonimos: ['total a cobrar', 'financiamiento más fee', 'financiamiento + fee', 'lo que se cobra de la semana', 'financiado más fee'],
    destino: { to: '/admin/metricas' },
    que: 'Lo que los pacientes pagan en sus dos cuotas por los financiamientos de la semana: el total financiado (sin fee) más el service fee y su IVA. No es un total suelto: se enseña siempre con sus dos sumandos al lado, en la tarjeta, en la tabla y en el CSV.',
    rpc: 'admin_metricas_semana_resumen',
  },
  {
    tipo: 'cifra',
    id: 'consumos-de-la-semana',
    titulo: 'Financiamientos de la semana',
    descripcion: 'Cuántos financiamientos se confirmaron en la semana, frente a la semana anterior.',
    espacio: 'metricas',
    sinonimos: ['número de financiamientos', 'nro. financiamientos', 'cuántos financiamientos', 'consultas de la semana', 'transacciones'],
    destino: { to: '/admin/metricas' },
    que: 'Los financiamientos confirmados de la semana (de lunes a domingo, por día operativo), de todas las clínicas o de una, sin los de prueba. Se compara con la semana anterior a la misma altura.',
    rpc: 'admin_metricas_semana_resumen',
  },
  {
    tipo: 'cifra',
    id: 'usuarios-que-consumieron-en-la-semana',
    titulo: 'Pacientes que se financiaron en la semana',
    descripcion: 'Los pacientes distintos con cuota en los financiamientos de la semana, frente a la semana anterior.',
    espacio: 'metricas',
    sinonimos: ['nro. pacientes', 'pacientes de la semana', 'se financiaron en la semana'],
    destino: { to: '/admin/metricas' },
    que: 'Los pacientes distintos con cuota en los financiamientos de la semana, de todas las clínicas o de una. Quien vino dos días o a dos clínicas cuenta una vez. Se compara con la semana anterior a la misma altura.',
    rpc: 'admin_metricas_semana_resumen',
  },
] as const satisfies ReadonlyArray<Entrada>
