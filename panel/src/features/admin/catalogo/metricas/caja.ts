import type { Entrada } from '../tipos'

/**
 * Las cifras NUEVAS de Métricas › Caja, para la búsqueda (Ctrl K) y el
 * asistente: lo que se movió en la semana. Las de Dinero (caja, por cobrar,
 * por pagar, service fee, perdido, proyección, banco) y el capital comprometido
 * ya están en `caja.ts` y `gerencia.ts`, con su destino aquí: no se duplican.
 */
export const metricasCaja = [
  {
    tipo: 'cifra',
    id: 'entro-de-cuotas',
    titulo: 'Cobrado en cuotas en la semana (financiamiento + fee)',
    descripcion: 'Lo que pagaron los pacientes por sus cuotas en una semana: el financiamiento más el service fee, con las dos partes.',
    espacio: 'metricas',
    sinonimos: [
      'entró de cuotas',
      'entró de cuotas en la semana',
      'cobrado en la semana',
      'cobros de la semana',
      'ingresos de caja',
      'entradas de caja',
      'recaudado',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'caja' } },
    que: 'Calculado de las cuotas cuyo pago se aprobó en la semana elegida (no del libro contable): lo que se cobra (el financiamiento más el service fee, IVA incluido), siempre con sus dos partes. Los cargos por atraso van aparte. Con una clínica, las de sus financiamientos.',
    rpc: 'admin_metricas_caja',
  },
  {
    tipo: 'cifra',
    id: 'salio-a-los-locales',
    titulo: 'Transferido a clínicas en la semana',
    descripcion: 'Lo transferido a las clínicas en una semana.',
    espacio: 'metricas',
    sinonimos: ['salió a las clínicas', 'transferido en la semana', 'pagado a clínicas', 'salidas de caja', 'liquidado'],
    destino: { to: '/admin/metricas', search: { vista: 'caja' } },
    que: 'Calculado de las transferencias registradas en Pagos a clínicas en la semana elegida, por el día operativo de su asiento: su neto, sin el service fee. Con una clínica, lo que se le transfirió a ella.',
    rpc: 'admin_metricas_caja',
  },
  {
    tipo: 'cifra',
    id: 'servicio-ganado-y-cobrado',
    titulo: 'Service fee ganado y cobrado en la semana',
    descripcion: 'El service fee, sin IVA, que se ganó con los financiamientos de la semana y el que se cobró dentro de las cuotas.',
    espacio: 'metricas',
    // Los nombres viejos, para que quien los teclee lo siga encontrando.
    sinonimos: [
      'ingreso de helios',
      'fee ganado',
      'fee cobrado',
      'comisión de la semana',
      'devengado y cobrado',
      'servicio',
      'servicio de helios',
      'comisión',
      'servicio ganado',
      'servicio cobrado',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'caja' } },
    que: 'Calculados de los financiamientos y de las cuotas, no del libro contable. Ganado: el service fee sin IVA de los financiamientos de la semana. Cobrado: la parte del service fee, sin IVA, que iba dentro de las cuotas cobradas esa semana, que son de financiamientos anteriores. Ninguno se suma al financiado.',
    rpc: 'admin_metricas_caja',
  },
  {
    tipo: 'cifra',
    id: 'cargos-por-atraso-cobrados',
    titulo: 'Cargos por atraso cobrados en la semana',
    descripcion: 'Los cargos por atraso que los pacientes pagaron en una semana.',
    espacio: 'metricas',
    sinonimos: ['mora cobrada', 'multas cobradas', 'penalizaciones cobradas'],
    destino: { to: '/admin/metricas', search: { vista: 'caja' } },
    que: 'Los cargos por atraso pagados en la semana elegida. Son ingreso de Helios y van aparte de lo cobrado de cuotas.',
    rpc: 'admin_metricas_caja',
  },
  {
    tipo: 'cifra',
    id: 'caja-al-cierre-de-la-semana',
    titulo: 'Dinero en caja al cierre de la semana',
    descripcion: 'La caja del libro el domingo de una semana, frente a la de la semana anterior.',
    espacio: 'metricas',
    sinonimos: ['caja semanal', 'saldo al cierre', 'caja del domingo'],
    destino: { to: '/admin/metricas', search: { vista: 'caja' } },
    que: 'Del libro contable: lo cobrado menos lo transferido a las clínicas y los ajustes, al cierre del domingo de la semana elegida (o hoy, si va a medias). Es de todo Helios: no se parte por clínica.',
    rpc: 'admin_metricas_caja',
  },
] as const satisfies ReadonlyArray<Entrada>
