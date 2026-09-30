import type { Entrada } from '../tipos'

/**
 * Las cifras de la pestaña Cohortes de Métricas, para la búsqueda (Ctrl K) y
 * el asistente. La pantalla de la pestaña ya está en `pantallas.ts`, y el
 * término «Cohorte» en el glosario.
 *
 * Cohortes habla en lo que hay que COBRAR (Javier, 27-09): el total a cobrar
 * de una semana es la cuota 1 + la cuota 2, con el service fee dentro y
 * siempre con su desglose (consumo sin fee + service fee). Los nombres viejos
 * («del consumo ya volvió», «la cuota 1, semana a semana») quedan como
 * sinónimos para que la búsqueda los siga encontrando.
 *
 * `impago-por-cosecha` y `curvas-de-cosecha` (en `catalogo/riesgo.ts`) ya
 * apuntan a «Comparar todas»: no se duplican aquí.
 */
export const metricasCohortes = [
  {
    tipo: 'cifra',
    id: 'total-a-cobrar-de-una-semana',
    titulo: 'Total a cobrar de una semana',
    descripcion:
      'De lo financiado una semana, lo que hay que cobrar: la cuota 1 más la cuota 2, con el financiamiento (sin fee) y el service fee por separado.',
    espacio: 'metricas',
    sinonimos: [
      'total a cobrar',
      'cuánto hay que cobrar de la semana',
      'financiamiento más fee',
      'financiamiento + fee',
      'financiamiento, sin servicio',
      'por cobrar de una semana',
      'lo que falta por cobrar de la semana',
      'vencido de la semana',
      'por vencer de la semana',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'cobros' } },
    que: 'Para los financiamientos de una semana (de lunes a domingo, por día operativo), lo que hay que cobrar de ellos: la cuota 1 más la cuota 2, cada una con su service fee (IVA incluido), siempre con sus dos partes a la vista (el financiamiento, sin fee, y el service fee). Debajo, cuánto se cobró, cuánto está vencido y cuánto por vencer, cada importe con su desglose.',
    rpc: 'admin_metricas_cohorte',
  },
  {
    tipo: 'cifra',
    id: 'cuotas-de-una-semana',
    titulo: 'Cuota 1 y cuota 2 de una semana',
    descripcion:
      'De lo financiado una semana, lo que se cobra en cada cuota y cuánto se cobró a tiempo, tarde, sigue vencido o por vencer.',
    espacio: 'metricas',
    sinonimos: [
      'cohorte de una semana',
      'cuánto hemos cobrado de la semana',
      'cobrado de la cuota 1',
      'cobrado de la cuota 2',
      'seguir una semana',
      'cuotas por semana de financiamiento',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'cobros' } },
    que: 'Para los financiamientos de una semana (de lunes a domingo, por día operativo), cada cuota en su tarjeta: lo que se cobra en ella con su financiamiento (sin fee) y su service fee (IVA incluido), y cuánto está cobrado a tiempo, cobrado tarde, vencido sin pagar, por vencer o dado por perdido, con los pacientes de cada estado. Las dos cuotas suman el total a cobrar de la semana.',
    rpc: 'admin_metricas_cohorte',
  },
  {
    tipo: 'cifra',
    id: 'volvio-del-consumo',
    titulo: 'Cobrado de una semana',
    descripcion: 'Qué parte de lo que hay que cobrar de una semana (financiamiento más service fee) ya se ha pagado.',
    espacio: 'metricas',
    sinonimos: [
      '% cobrado',
      'porcentaje cobrado',
      'del financiamiento ya volvió',
      'volvió del financiamiento',
      'recuperado',
      'repago',
      'cuánto volvió',
      'financiamiento cobrado',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'cobros' } },
    que: 'Lo pagado, a tiempo o tarde, de las dos cuotas de los financiamientos de esa semana, sobre el total a cobrar (financiamiento más service fee). El importe cobrado va con su desglose: el financiamiento, sin fee, y el service fee.',
    rpc: 'admin_metricas_cohortes',
  },
  {
    tipo: 'cifra',
    id: 'curva-de-cobro-de-la-cuota',
    titulo: 'Cobrado acumulado de la cuota por día desde el vencimiento',
    descripcion:
      'Día a día desde que vence, qué parte de la cuota 1 o la 2 de una semana estaba pagada, frente a las semanas anteriores.',
    espacio: 'metricas',
    sinonimos: ['cómo se fue cobrando la cuota', 'curva de cobro', 'ritmo de cobro', 'días desde el vencimiento', 'pagan antes de vencer'],
    destino: { to: '/admin/metricas', search: { vista: 'cobros' } },
    que: 'Para cada día desde el vencimiento de cada cuota (antes y después), la parte de lo que se cobra en ella (financiamiento más service fee) que ya estaba pagada, contando el día en que el paciente reportó el pago. Se compara con la media de las cuatro semanas anteriores, solo en los días que todas ya cerraron. El día en que acaba la gracia es lo cobrado a tiempo.',
    rpc: 'admin_metricas_cohorte',
  },
  {
    tipo: 'cifra',
    id: 'cohorte-por-local',
    titulo: 'Una semana de financiamiento por clínica',
    descripcion: 'Lo que hay que cobrar de una semana en cada clínica: cuánto se cobró, lo vencido y lo por vencer.',
    espacio: 'metricas',
    sinonimos: ['cobro por clínica', 'vencido por clínica', 'qué clínica cobra peor', 'cuotas por clínica', 'total a cobrar por clínica'],
    destino: { to: '/admin/metricas', search: { vista: 'cobros' } },
    que: 'La cohorte de la semana partida por la clínica donde se financió: lo que hay que cobrar (la cuota 1 más la 2, con su financiamiento sin fee y su service fee), qué parte se cobró, lo vencido y lo por vencer, cada importe con su desglose, y cómo va cada cuota. Las clínicas suman el total de la semana.',
    rpc: 'admin_metricas_cohorte',
  },
  {
    tipo: 'cifra',
    id: 'cuota-1-semana-a-semana',
    titulo: 'Total a cobrar por semana de financiamiento, por estado',
    descripcion: 'Cada semana de financiamiento con su total a cobrar, partido en cobrado, vencido, por vencer y perdido.',
    espacio: 'metricas',
    sinonimos: [
      'lo que hay que cobrar, semana a semana',
      'la cuota 1, semana a semana',
      'primera cuota por semana',
      'cobro a tiempo por semana',
      'comparar semanas',
      'comparar cohortes',
      'qué semana debe más',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'cobros' } },
    que: 'Las últimas doce semanas de financiamiento, cada una con su total a cobrar (la cuota 1 más la 2, con su service fee) partido por estado: cobrado a tiempo, cobrado tarde, vencido, por vencer y dado por perdido. El desglose de cada total (financiamiento sin fee y service fee) está en el globo y en la tabla.',
    rpc: 'admin_metricas_cohortes',
  },
] as const satisfies ReadonlyArray<Entrada>
