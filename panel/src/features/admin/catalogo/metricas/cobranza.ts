import type { Entrada } from '../tipos'

/**
 * Las cifras y los términos NUEVOS de Métricas › Riesgo, para la
 * búsqueda (Ctrl K) y el asistente.
 *
 * Las cifras que ya existían (tasa de mora, impago, punto de empate, cobro a
 * tiempo, mora por tramo, paso entre tramos, vencía frente a cobrado, impago
 * de la primera cuota, uso del cupo…) siguen en `catalogo/riesgo.ts` con su
 * id y ya apuntan aquí: no se duplican. Lo recuperado, la cura, la
 * efectividad y las promesas siguen en `catalogo/cobranza.ts` (Por cobrar ›
 * Rendimiento).
 */
export const metricasCobranza = [
  // ── Cifras ───────────────────────────────────────────────────────────────
  {
    tipo: 'cifra',
    id: 'vencido-sin-pagar-de-la-semana',
    titulo: 'Vencido en cartera al corte de la semana',
    descripcion: 'Lo vencido y sin pagar al cierre de la semana elegida, con su desglose y los pacientes que lo deben.',
    espacio: 'metricas',
    sinonimos: ['vencido sin pagar de la semana', 'vencido al cierre', 'vencido de la semana', 'deuda vencida de la semana', 'mora de la semana'],
    destino: { to: '/admin/metricas', search: { vista: 'mora' } },
    que: 'Las cuotas vencidas y sin pagar al cierre de la semana elegida (o ahora, si está en curso), sin lo dado por perdido, y cuántos pacientes las deben. Son cuotas: financiamiento + Comisión Helios, siempre con su desglose a la vista. Se compara con la semana anterior a la misma altura.',
    rpc: 'admin_metricas_cobranza',
  },
  {
    tipo: 'cifra',
    id: 'impago-segunda-cuota',
    titulo: 'Impago de la segunda cuota',
    descripcion: 'Qué parte de las cuotas 2 seguía sin pagar al terminar la gracia, al lado de la cuota 1.',
    espacio: 'metricas',
    sinonimos: [
      'cuota 2 sin pagar',
      'cuota 2 sin pagar tras la gracia',
      'segunda cuota',
      'impago de la cuota 2',
      'impago por cuota',
      'second payment default',
      'spd',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'cobros', sub: 'impago-por-cuota', cuota: '2' } },
    que: 'De la cuota 2 de cada paciente en cada financiamiento, qué parte seguía sin pagar el último día de la gracia; vence una semana después de la 1 y cuenta también a quien tampoco pagó la 1. Se parte por semana, mes, clínica, nivel o primer financiamiento, con la cuota 1 al lado. Los montos son financiamiento, sin la Comisión Helios.',
    rpc: 'admin_first_payment_default',
  },
  {
    tipo: 'cifra',
    id: 'deudores-por-comportamiento',
    titulo: 'Pacientes con deuda vencida, por perfil de pago',
    descripcion: 'A quién llamar primero y por qué: los pacientes en mora repartidos por cómo pagan, con su prioridad.',
    espacio: 'cobranza',
    sinonimos: [
      'perfil de deudor',
      'perfiles de deudor',
      'deudores por comportamiento',
      'a quién llamar',
      'prioridad de cobranza',
      'priorizar la cobranza',
      'deudores',
      'morosos',
    ],
    destino: { to: '/admin/cobranza' },
    que: 'Cada paciente con algo vencido cae en un solo perfil (ninguna cuota pagada, promesa de pago incumplida, sin respuesta a las gestiones, atrasos repetidos, vencido con pagos previos, atraso de pocos días con buen historial), y aparte los que están al día con riesgo de atraso. Cada perfil con sus pacientes, lo que deben vencido con su desglose, el atraso medio y lo que se ha recuperado de pacientes así. Son las tarjetas de arriba de Por cobrar: pulsar una acota la lista a ese perfil.',
    rpc: 'admin_deudores_por_perfil',
  },
  {
    tipo: 'cifra',
    id: 'recuperacion-por-perfil-de-deudor',
    titulo: 'Recuperación por perfil de deudor',
    descripcion: 'Cuánto se ha cobrado, en la historia, de los pacientes de cada perfil de deudor.',
    espacio: 'cobranza',
    sinonimos: ['recuperación histórica', 'cuánto se recupera', 'tasa de recuperación por perfil'],
    destino: { to: '/admin/cobranza' },
    que: 'De lo que debían vencido los pacientes cada vez que encajaron en un perfil, la parte que pagaron en el mes siguiente. Solo cuentan las veces con ese mes ya cumplido.',
    rpc: 'admin_deudores_por_perfil',
  },

  // ── Términos: los perfiles ───────────────────────────────────────────────
  {
    tipo: 'termino',
    id: 'perfil-nunca-ha-pagado',
    titulo: 'Ninguna cuota pagada',
    descripcion: 'Perfil de deudor: no ha pagado ninguna cuota y tiene alguna vencida.',
    espacio: 'cobranza',
    sinonimos: ['nunca ha pagado', 'no ha pagado nunca', 'primera cuota impaga', 'nunca paga'],
    destino: { to: '/admin/cobranza', search: { perfil: 'nunca_ha_pagado' } },
    definicion: 'Quien no ha pagado ninguna cuota y tiene alguna vencida. Prioridad alta: es la señal más temprana de que se le dio crédito a quien no debía.',
  },
  {
    tipo: 'termino',
    id: 'perfil-promesa-rota',
    titulo: 'Promesa de pago incumplida',
    descripcion: 'Perfil de deudor: prometió pagar un día de las dos últimas semanas y no pagó.',
    espacio: 'cobranza',
    sinonimos: ['promesa rota', 'incumplió la promesa', 'no cumplió'],
    destino: { to: '/admin/cobranza', search: { perfil: 'promesa_rota' } },
    definicion: 'Quien está en mora y rompió una promesa de pago en las dos últimas semanas. Prioridad alta.',
  },
  {
    tipo: 'termino',
    id: 'perfil-sin-respuesta',
    titulo: 'Sin respuesta a las gestiones',
    descripcion: 'Perfil de deudor: varias gestiones sin pago ni promesa y más de una semana de atraso.',
    espacio: 'cobranza',
    sinonimos: ['sin respuesta', 'no contesta', 'ilocalizable', 'silencioso'],
    destino: { to: '/admin/cobranza', search: { perfil: 'sin_respuesta' } },
    definicion: 'Quien tiene dos gestiones o más desde que le venció lo más viejo sin promesa ni un pago registrado en las 72 horas siguientes, y más de una semana de atraso. Prioridad alta.',
  },
  {
    tipo: 'termino',
    id: 'perfil-reincidente',
    titulo: 'Atrasos repetidos',
    descripcion: 'Perfil de deudor: ya pagó tarde varias veces y vuelve a deber.',
    espacio: 'cobranza',
    sinonimos: ['reincidente', 'repite', 'vuelve a atrasarse'],
    destino: { to: '/admin/cobranza', search: { perfil: 'reincidente' } },
    definicion: 'Quien ya pagó tarde dos cuotas o más y vuelve a tener algo vencido. Prioridad media.',
  },
  {
    tipo: 'termino',
    id: 'perfil-paga-tarde-pero-paga',
    titulo: 'Vencido, con pagos previos',
    descripcion: 'Perfil de deudor: el resto de los pacientes en mora que ya han pagado otras veces.',
    espacio: 'cobranza',
    sinonimos: ['paga tarde, pero paga', 'paga con atraso', 'tardío'],
    destino: { to: '/admin/cobranza', search: { perfil: 'paga_tarde_pero_paga' } },
    definicion: 'Quien tiene algo vencido, ya ha pagado otras cuotas y no encaja en ningún perfil anterior. Prioridad media.',
  },
  {
    tipo: 'termino',
    id: 'perfil-se-le-paso',
    titulo: 'Atraso de pocos días, buen historial',
    descripcion: 'Perfil de deudor: pocos días de atraso y casi siempre paga a tiempo.',
    espacio: 'cobranza',
    sinonimos: ['se le pasó', 'olvido', 'despiste', 'buen pagador'],
    destino: { to: '/admin/cobranza', search: { perfil: 'se_le_paso' } },
    definicion: 'Quien lleva muy pocos días de atraso y pagó a tiempo casi todas sus cuotas (el 80 % o más). Prioridad baja: suele bastar un recordatorio.',
  },
  {
    tipo: 'termino',
    id: 'perfil-vigilar',
    titulo: 'Al día, con riesgo de atraso',
    descripcion: 'Sin nada vencido, le vence una cuota muy pronto y suele pagar tarde.',
    espacio: 'cobranza',
    sinonimos: ['vigilar', 'a punto de vencer', 'riesgo de atraso'],
    destino: { to: '/admin/cobranza', search: { perfil: 'vigilar' } },
    definicion: 'Quien no debe nada vencido, le vence una cuota en los próximos días y pagó tarde al menos la mitad de sus cuotas (con 2 pagadas o más). Es para avisarle antes de que venza.',
  },

  // ── Ola 4 (MORA-INICIO) ──────────────────────────────────────────────────
  {
    tipo: 'cifra',
    id: 'impago-segunda-cuota-de-quien-pago-la-primera',
    titulo: 'Cuota 2 sin pagar de quien pagó la 1',
    descripcion: 'De quien ya había pagado la cuota 1, qué parte no paga la 2: quien empieza pagando y se cae.',
    espacio: 'metricas',
    sinonimos: [
      'de quien pagó la cuota 1',
      'pagó la 1 y no la 2',
      'pagó la primera y no la segunda',
      'deja de pagar',
      'se cae en la cuota 2',
      'impago condicionado',
      'cuota 2 tras pagar la 1',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'cobros', sub: 'impago-por-cuota', cuota: '2' } },
    que: 'De las cuotas 2 ya maduras de quien había pagado la cuota 1 del mismo financiamiento el día en que se juzga la 2 (al acabar su gracia), qué parte seguía sin pagar. Separa a quien empieza pagando y se cae de quien nunca pagó, que el impago de la cuota 2 cuenta junto. Va sobre cuotas y se parte por semana, mes, clínica, nivel o primer financiamiento. Los montos son financiamiento, sin la Comisión Helios.',
    rpc: 'admin_first_payment_default',
  },
] as const satisfies ReadonlyArray<Entrada>

type IdCifraDeCobranza = Extract<(typeof metricasCobranza)[number], { tipo: 'cifra' }>['id']

/**
 * El `que` de una cifra de esta pestaña, para su `InfoDot`: la pantalla y la
 * búsqueda la explican con las mismas palabras.
 */
export function queEsLaCifraDeCobranza(id: IdCifraDeCobranza): string {
  for (const e of metricasCobranza) if (e.tipo === 'cifra' && e.id === id) return e.que
  return ''
}
