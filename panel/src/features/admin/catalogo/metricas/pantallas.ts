import {
  CalendarDays,
  CalendarRange,
  ChartColumn,
  ChartLine,
  Gauge,
  HandCoins,
  Layers,
  LayoutDashboard,
  Percent,
  ReceiptText,
  Repeat,
  Scale,
  ShieldAlert,
  ShoppingBag,
  Sprout,
  Store,
  TrendingUp,
  Wallet,
} from 'lucide-react'

import type { Entrada } from '../tipos'

/**
 * Métricas: la pantalla, sus siete pestañas y cada sub-pestaña
 * (`features/admin/metricas/pestanas.ts`), con el mismo nombre que en la
 * pantalla: «Métricas › Cobros › Calendario».
 *
 * Solo `metricas` sale en el menú; el resto está aquí para que la búsqueda
 * encuentre cada sitio por su nombre y por el de lo que sustituye: las
 * pantallas viejas («resumen», «crecimiento», «riesgo de crédito»,
 * «dinero») y las pestañas de antes de la reorganización del 27-09
 * («cohortes», «cobranza y riesgo», «general», «comparar todas»…). Los
 * avisos se mudaron el 29-09 a Notificaciones › Rendimiento, con su entrada
 * en `cobranza.ts`. Una prueba (`metricas/destinos.test.ts`) exige que cada pestaña
 * y cada sub-pestaña del registro tenga aquí la suya, con su nombre y su
 * destino en forma canónica: sin `sub` en la primera, que es la de por
 * defecto.
 *
 * Los ids son `metricas-<pestaña>` y `metricas-<pestaña>-<sub>`. Las cifras
 * de cada pestaña las escribe su dueño en `metricas/<carpeta>.ts`.
 */
export const pantallasDeMetricas = [
  {
    tipo: 'pantalla',
    id: 'metricas',
    titulo: 'Métricas',
    descripcion:
      'Todas las cifras del negocio en una pantalla, por semana y por clínica: la semana, los cobros, la mora, la caja, las clínicas, la gente y lo global.',
    espacio: 'metricas',
    sinonimos: [
      'estadísticas',
      'analítica',
      'tablero',
      'dashboard',
      'kpi',
      'indicadores',
      'cifras',
      'números',
      'informes',
      'reportes',
    ],
    destino: { to: '/admin/metricas' },
    icono: ChartColumn,
  },

  // ── Semana ───────────────────────────────────────────────────────────────
  {
    tipo: 'pantalla',
    id: 'metricas-semana',
    titulo: 'Métricas › Semana',
    descripcion:
      'Lo financiado en una semana (sin fee), su service fee y el total a cobrar, y cómo va frente a las anteriores. Es una pestaña de Métricas.',
    espacio: 'metricas',
    sinonimos: ['esta semana', 'financiamientos de la semana', 'semana', 'resumen del negocio'],
    destino: { to: '/admin/metricas', search: { vista: 'semana' } },
    icono: LayoutDashboard,
  },
  {
    tipo: 'pantalla',
    id: 'metricas-semana-resumen',
    titulo: 'Métricas › Semana › Resumen',
    descripcion:
      'Lo financiado en las clínicas (sin fee), su service fee + IVA y el total a cobrar, los financiamientos y la gente, y la tabla de financiamientos por día y clínica.',
    espacio: 'metricas',
    sinonimos: [
      'resumen',
      'resumen de la semana',
      'total financiado',
      'financiado',
      'service fee + iva',
      'total a cobrar',
      'financiamientos por día',
      'financiamientos por clínica',
      'días',
      'pacientes que se financiaron',
      'gmv',
      'volumen',
      'servicio',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'semana' } },
    icono: ReceiptText,
  },
  {
    tipo: 'pantalla',
    id: 'metricas-semana-rendimiento',
    titulo: 'Métricas › Semana › Rendimiento',
    descripcion:
      'Las cifras que mandan, semana a semana, frente a la anterior y a sus metas: financiamiento (sin fee), service fee, cobro, riesgo, gente y caja.',
    espacio: 'metricas',
    sinonimos: [
      'semana a semana',
      'tabla semanal',
      'metas',
      'objetivos',
      'tendencia',
      'evolución semanal',
      'comparar semanas',
      'week over week',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'semana', sub: 'rendimiento' } },
    icono: TrendingUp,
  },

  // ── Cobros ───────────────────────────────────────────────────────────────
  {
    tipo: 'pantalla',
    id: 'metricas-cobros',
    titulo: 'Métricas › Cobros',
    descripcion:
      'Lo que hay que cobrar de los financiamientos de cada semana (financiamiento + fee), cuánto se cobró, cuánto falta y el impago de cada cuota. Es una pestaña de Métricas.',
    espacio: 'metricas',
    sinonimos: [
      'cohortes',
      'cohorte de financiamiento',
      'cosechas',
      'vintage',
      'cuota 1',
      'cuota 2',
      'impago',
      'total a cobrar',
      'lo que hay que cobrar',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'cobros' } },
    icono: CalendarRange,
  },
  {
    tipo: 'pantalla',
    id: 'metricas-cobros-calendario',
    titulo: 'Métricas › Cobros › Semanas',
    descripcion:
      'Todas las semanas de financiamiento comparados: lo que hay que cobrar de cada una (financiamiento + fee) y cómo va, y la curva de cobro y el reparto por clínica de la elegida.',
    espacio: 'metricas',
    sinonimos: [
      'comparar todas',
      'comparar semanas',
      'todas las semanas',
      'cohortes',
      'cosechas',
      'vintage',
      'impago por semana',
      'lo que hay que cobrar semana a semana',
      'curva de cobro',
      'calendario',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'cobros' } },
    icono: CalendarDays,
  },
  {
    tipo: 'pantalla',
    id: 'metricas-cobros-impago-por-cuota',
    titulo: 'Métricas › Cobros › Impago por cuota',
    descripcion:
      'Qué parte de la cuota 1 y de la cuota 2 sigue sin pagar al terminar la gracia, por semana, clínica o nivel.',
    espacio: 'metricas',
    sinonimos: [
      'primera cuota',
      'impago de la primera cuota',
      'fpd',
      'cuota 1 sin pagar',
      'cuota 2 sin pagar',
      'impago de la segunda cuota',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'cobros', sub: 'impago-por-cuota' } },
    icono: Percent,
  },

  // ── Riesgo (id `mora`) ───────────────────────────────────────────────────
  {
    tipo: 'pantalla',
    id: 'metricas-mora',
    titulo: 'Métricas › Riesgo',
    descripcion:
      'Cuánto está vencido y en qué tramo, el cupo ocupado por nivel y lo que recupera la cobranza. Es una pestaña de Métricas.',
    espacio: 'metricas',
    sinonimos: [
      'cobranza y riesgo',
      'riesgo de crédito',
      'riesgo',
      'cartera',
      'mora',
      'tramos',
      'cupos',
      'exposición',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'mora' } },
    icono: ShieldAlert,
  },
  {
    tipo: 'pantalla',
    id: 'metricas-mora-resumen',
    titulo: 'Métricas › Riesgo › Resumen',
    descripcion:
      'Lo vencido al cierre de la semana (financiamiento + fee) y en qué tramo, lo que vencía frente a lo que entró y el paso entre tramos.',
    espacio: 'metricas',
    sinonimos: ['cobranza y riesgo', 'tasa de mora', 'vencido', 'mora por tramo', 'paso entre tramos'],
    destino: { to: '/admin/metricas', search: { vista: 'mora' } },
    icono: HandCoins,
  },
  {
    tipo: 'pantalla',
    id: 'metricas-mora-cupos',
    titulo: 'Métricas › Riesgo › Cupos',
    descripcion: 'Cuánto de su cupo usa hoy la gente de cada nivel.',
    espacio: 'metricas',
    sinonimos: ['cupos', 'uso del cupo', 'uso del cupo por nivel', 'cupo por nivel', 'límite de crédito'],
    destino: { to: '/admin/metricas', search: { vista: 'mora', sub: 'cupos' } },
    icono: Layers,
  },
  {
    tipo: 'pantalla',
    id: 'metricas-mora-rendimiento',
    titulo: 'Métricas › Riesgo › Rendimiento',
    descripcion:
      'Lo que consiguió la cobranza en la semana: lo recuperado, las gestiones, las promesas y la cura por tramo.',
    espacio: 'metricas',
    sinonimos: [
      'rendimiento de la cobranza',
      'por cobrar rendimiento',
      'recuperado',
      'cura por tramo',
      'gestiones',
      'promesas cumplidas',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'mora', sub: 'rendimiento' } },
    icono: TrendingUp,
  },

  // ── Caja ─────────────────────────────────────────────────────────────────
  {
    tipo: 'pantalla',
    id: 'metricas-caja',
    titulo: 'Métricas › Caja',
    descripcion:
      'Cuánto dinero hay, lo que entró y salió en la semana, la proyección, el banco y el capital comprometido. Es una pestaña de Métricas.',
    espacio: 'metricas',
    sinonimos: [
      'dinero',
      'balance',
      'caja',
      'proyección de caja',
      'saldo del banco',
      'capital comprometido',
      'flujo de caja',
      'service fee ganado',
      'service fee cobrado',
      'servicio ganado',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'caja' } },
    icono: Wallet,
  },
  {
    tipo: 'pantalla',
    id: 'metricas-caja-balance',
    titulo: 'Métricas › Caja › Balance',
    descripcion:
      'Lo que entró y salió de la caja en la semana, el balance de hoy según el libro y el capital comprometido.',
    espacio: 'metricas',
    sinonimos: ['balance', 'dinero', 'en caja', 'movimientos de la semana', 'capital comprometido', 'servicio ganado'],
    destino: { to: '/admin/metricas', search: { vista: 'caja' } },
    icono: Scale,
  },
  {
    tipo: 'pantalla',
    id: 'metricas-caja-proyeccion',
    titulo: 'Métricas › Caja › Proyección y banco',
    descripcion:
      'Lo que entrará y saldrá desde hoy, lo proyectado frente a lo que pasó y el saldo del banco.',
    espacio: 'metricas',
    sinonimos: ['proyección', 'proyección de caja', 'saldo del banco', 'banco', 'proyectado frente a real', 'flujo de caja'],
    destino: { to: '/admin/metricas', search: { vista: 'caja', sub: 'proyeccion' } },
    icono: ChartLine,
  },

  // ── Locales ──────────────────────────────────────────────────────────────
  {
    tipo: 'pantalla',
    id: 'metricas-locales',
    titulo: 'Métricas › Clínicas',
    descripcion:
      'Dónde se financia y cómo paga la gente de cada clínica, semana a semana. Es una pestaña de Métricas.',
    espacio: 'metricas',
    sinonimos: [
      'rendimiento de las clínicas',
      'financiamientos por clínica',
      'ranking de clínicas',
      'quién vendió más',
      'mejor clínica',
      'clínicas',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'locales' } },
    icono: Store,
  },

  // ── Gente ────────────────────────────────────────────────────────────────
  {
    tipo: 'pantalla',
    id: 'metricas-gente',
    titulo: 'Métricas › Gente',
    descripcion:
      'Quién llega, quién se financia y quién vuelve: quién pidió el código, registros, uso, grupos, retención y el perfil de la gente. Es una pestaña de Métricas.',
    espacio: 'metricas',
    sinonimos: [
      'crecimiento',
      'pacientes',
      'registros',
      'solicitaron el código',
      'embudo',
      'retención',
      'cohortes de registro',
      'grupos',
      'perfil de la gente',
      'user paciente',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'gente' } },
    icono: Sprout,
  },
  {
    tipo: 'pantalla',
    id: 'metricas-gente-resumen',
    titulo: 'Métricas › Gente › Resumen',
    descripcion:
      'Cuánta gente pidió el código, se registró y se financió en la ventana, y hasta qué escalón llegó.',
    espacio: 'metricas',
    sinonimos: ['crecimiento', 'embudo de registro', 'registros', 'solicitaron el código', 'listos para financiarse'],
    destino: { to: '/admin/metricas', search: { vista: 'gente' } },
    icono: Sprout,
  },
  {
    tipo: 'pantalla',
    id: 'metricas-gente-uso',
    titulo: 'Métricas › Gente › Uso',
    descripcion: 'Cuánto se financia cada paciente (sin fee) y de cuánta gente depende el total.',
    espacio: 'metricas',
    sinonimos: ['uso', 'financiamiento por paciente', 'quién sostiene el financiamiento', 'concentración', 'frecuencia'],
    destino: { to: '/admin/metricas', search: { vista: 'gente', sub: 'uso' } },
    icono: ShoppingBag,
  },
  {
    tipo: 'pantalla',
    id: 'metricas-gente-retencion',
    titulo: 'Métricas › Gente › Retención',
    descripcion: 'La gente que se registró junta: cuánta sigue financiándose en las semanas siguientes.',
    espacio: 'metricas',
    sinonimos: ['retención', 'cohortes de registro', 'vuelven', 'se quedan', 'recurrencia'],
    destino: { to: '/admin/metricas', search: { vista: 'gente', sub: 'retencion' } },
    icono: Repeat,
  },

  // ── Global ───────────────────────────────────────────────────────────────
  {
    tipo: 'pantalla',
    id: 'metricas-global',
    titulo: 'Métricas › Global',
    descripcion:
      'Lo global del negocio desde el primer día: la gente, el financiamiento (sin fee), lo que se debe, lo cobrado y el riesgo. Es una pestaña de Métricas.',
    espacio: 'metricas',
    sinonimos: [
      'general',
      'desde el inicio',
      'histórico',
      'acumulado',
      'total del negocio',
      'global',
      'por cada cien',
      'punto de empate',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'global' } },
    icono: Gauge,
  },
] as const satisfies ReadonlyArray<Entrada>
