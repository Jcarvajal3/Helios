import { ShieldAlert } from 'lucide-react'

import type { Entrada } from './tipos'

/**
 * Riesgo: a quién se le da crédito, cuánto, y si lo que se prestó vuelve.
 *
 * En el menú va dentro de «Cobranza y riesgo»: Verificaciones y Alertas son
 * trabajo de cada día. Riesgo de crédito pasó a Métricas (Mora, y las
 * cosechas a Cobros › Calendario) y Niveles y cupos a Ajustes; sus cifras
 * siguen aquí, con el destino en su sitio nuevo. Las de volumen de la ventana
 * (financiado, ticket y personas de `admin_overview`) se quitaron el 27-09:
 * ninguna pantalla las enseña ya, y las de la semana están en Semana › Resumen.
 */
export const riesgo = [
  // ── Pantallas ────────────────────────────────────────────────────────────
  {
    tipo: 'pantalla',
    id: 'alertas',
    titulo: 'Alertas',
    descripcion: 'Las señales de riesgo que piden que alguien mire una cuenta.',
    espacio: 'riesgo',
    sinonimos: ['alertas de riesgo', 'fraude', 'señales', 'cuentas relacionadas', 'duplicados', 'vpn'],
    destino: { to: '/admin/alertas' },
    icono: ShieldAlert,
  },

  // ── Acciones ─────────────────────────────────────────────────────────────
  {
    tipo: 'accion',
    id: 'revisar-alerta',
    titulo: 'Revisar una alerta de riesgo',
    descripcion: 'Mirar la cuenta que disparó una alerta y marcarla como revisada, con una nota.',
    espacio: 'riesgo',
    sinonimos: ['marcar alerta', 'alerta revisada', 'fraude', 'cuenta duplicada'],
    destino: { to: '/admin/alertas' },
  },

  // ── Cifras ───────────────────────────────────────────────────────────────
  {
    tipo: 'cifra',
    id: 'tasa-de-mora',
    titulo: 'Mora (%)',
    descripcion: 'Qué parte de las cuotas sin pagar ya venció.',
    espacio: 'riesgo',
    sinonimos: ['mora', 'morosidad', 'vencido', 'tasa de mora'],
    destino: { to: '/admin/metricas', search: { vista: 'mora' } },
    que: 'Vencido ÷ (vencido + por vencer), en financiamiento + fee y sin lo dado por perdido.',
    rpc: 'admin_overview',
  },
  {
    tipo: 'cifra',
    id: 'tasa-de-impago',
    titulo: 'Impago sobre lo financiado (%)',
    descripcion: 'Qué parte de todo lo financiado, sin el service fee, acabó dándose por perdida.',
    espacio: 'riesgo',
    sinonimos: ['impago', 'pérdida', 'default', 'incobrable', 'tasa de impago', 'impago sobre lo financiado'],
    destino: { to: '/admin/metricas', search: { vista: 'mora' } },
    que: 'Sin el service fee: lo dado por perdido y sin pagar ÷ todo lo financiado desde el primer día, que solo es definitivo en las semanas de financiamiento que ya terminaron su ciclo de cobro.',
    rpc: 'admin_overview',
  },
  {
    tipo: 'cifra',
    id: 'punto-de-empate',
    titulo: 'Punto de empate del impago (%)',
    descripcion: 'El impago con el que Helios ni gana ni pierde dinero.',
    espacio: 'riesgo',
    sinonimos: ['punto de empate', 'break even', 'umbral de pérdida', 'rentabilidad del crédito', 'impago al que helios deja de ganar'],
    destino: { to: '/admin/metricas', search: { vista: 'mora' } },
    que: 'El impago a partir del cual el service fee que pagan los que cumplen deja de cubrir lo que se pierde con los que no pagan: el financiamiento ya transferido a la clínica más el fee que nunca se cobra.',
    rpc: 'admin_overview',
  },
  {
    tipo: 'cifra',
    id: 'cuotas-a-tiempo',
    titulo: 'Cobrado a tiempo (%)',
    descripcion: 'De las cuotas cuyo plazo terminó, la parte pagada dentro de él, por cuota 1 y cuota 2.',
    espacio: 'riesgo',
    sinonimos: ['cobro a tiempo', 'puntualidad', 'on time', 'cuotas pagadas a tiempo'],
    destino: { to: '/admin/metricas', search: { vista: 'mora' } },
    que: 'De las cuotas cuyo plazo ya terminó (vencimiento + días de gracia), la parte pagada dentro de él, en número de cuotas y por el día en que el paciente reportó el pago; lo dado por perdido cuenta como no pagado.',
    rpc: 'admin_on_time_collection',
  },
  {
    tipo: 'cifra',
    id: 'mora-por-tramo',
    titulo: 'Mora por tramo',
    descripcion: 'Lo vencido al corte de la semana elegida, repartido por los tramos de atraso.',
    espacio: 'riesgo',
    sinonimos: ['antigüedad de la mora', 'aging', 'tramos', 'buckets'],
    destino: { to: '/admin/metricas', search: { vista: 'mora' } },
    que: 'Lo vencido sin pagar (financiamiento + fee, sin lo dado por perdido) al corte de la semana elegida (ahora, si es la semana en curso), partido por el tramo de atraso de la cuota más antigua de cada paciente, con los cortes de los parámetros.',
    rpc: 'admin_metricas_cobranza',
  },
  {
    tipo: 'cifra',
    id: 'paso-entre-tramos',
    titulo: 'Paso entre tramos',
    descripcion: 'De un lunes al siguiente, cuántos pacientes mejoran, empeoran o se ponen al día.',
    espacio: 'riesgo',
    sinonimos: ['flujo de mora', 'roll rate', 'matriz de transición', 'cura', 'se pusieron al día'],
    destino: { to: '/admin/metricas', search: { vista: 'mora' } },
    que: 'El tramo de atraso de cada paciente al empezar y al acabar la semana (del lunes al lunes siguiente, o del lunes a ahora en la semana en curso): cuántos pasaron a un tramo peor, a uno mejor o se pusieron al día.',
    rpc: 'admin_collection_flow',
  },
  {
    tipo: 'cifra',
    id: 'vencia-frente-a-cobrado',
    titulo: 'Vencía frente a cobrado, por día (financiamiento + fee)',
    descripcion: 'Por día, las cuotas que vencían y lo que se cobró de ellas.',
    espacio: 'riesgo',
    sinonimos: ['vencido contra cobrado', 'cobranza diaria', 'lo que vencía frente a lo que entró'],
    destino: { to: '/admin/metricas', search: { vista: 'mora' } },
    que: 'Por día, lo que vencía en cuotas (financiamiento + fee) y la parte de eso mismo que ya se cobró; la diferencia es lo que falta por cobrar de ese día.',
    rpc: 'admin_due_vs_collected',
  },
  {
    tipo: 'cifra',
    id: 'impago-primera-cuota',
    titulo: 'Impago de la cuota 1 (%)',
    descripcion: 'Qué parte de las cuotas 1 seguía sin pagar al terminar los días de gracia.',
    espacio: 'riesgo',
    sinonimos: ['fpd', 'first payment default', 'primera cuota', 'impago temprano', 'impago por cuota', 'cuota 1 sin pagar', 'impago de la primera cuota'],
    destino: { to: '/admin/metricas', search: { vista: 'cobros', sub: 'impago-por-cuota' } },
    que: 'De las cuotas 1 que ya pasaron sus días de gracia, la parte que seguía sin pagar el último día de la gracia, en número de cuotas y partida por semana, mes, clínica, nivel, pacientes en el financiamiento o primer financiamiento.',
    rpc: 'admin_first_payment_default',
  },
  {
    tipo: 'cifra',
    id: 'impago-por-cosecha',
    titulo: 'Cómo acabó lo financiado cada semana',
    descripcion: 'De lo financiado cada semana, cuánto de su cuota 1 y de su cuota 2 se cobró, sigue vencido o se dio por perdido.',
    espacio: 'riesgo',
    sinonimos: ['cosechas', 'vintage', 'impago por cosecha', 'impago por semana', 'cohortes comparadas'],
    destino: { to: '/admin/metricas', search: { vista: 'cobros' } },
    que: 'De lo financiado cada semana, cuánto de su cuota 1 y de su cuota 2 se cobró a tiempo, tarde, sigue vencido o se dio por perdido, cada cuota por separado y con su desglose. Las semanas recientes todavía no han tenido tiempo de enseñar su impago.',
    rpc: 'admin_metricas_cohortes',
  },
  {
    tipo: 'cifra',
    id: 'uso-del-cupo',
    titulo: 'Uso del cupo',
    descripcion: 'Qué parte del cupo de cada nivel está ocupada hoy, y cuánto falta por volver (sin fee).',
    espacio: 'riesgo',
    sinonimos: ['cupo ocupado', 'utilización', 'exposición', 'cupo disponible', 'disponible hoy', 'cupo libre', 'límite'],
    destino: { to: '/admin/metricas', search: { vista: 'mora', sub: 'cupos' } },
    que: 'Sin el service fee, que no ocupa cupo: lo financiado que todavía ocupa cupo ÷ el cupo de todos los pacientes del nivel, con la exposición (el financiamiento que falta por volver); es la misma cuenta que frena una compra.',
    rpc: 'admin_credit_utilization',
  },
  {
    tipo: 'cifra',
    id: 'locales-por-volumen',
    titulo: 'Clínicas por volumen',
    descripcion: 'Las clínicas que concentran el financiamiento, con su mora.',
    espacio: 'riesgo',
    sinonimos: ['clínicas por volumen', 'concentración', 'riesgo por clínica'],
    destino: { to: '/admin/metricas', search: { vista: 'locales' } },
    que: 'Las clínicas de la semana elegida ordenados por financiado (sin fee): cuántos pacientes se financiaron (por sus cuotas), qué parte del financiado total representan y cuánto tienen vencido sus pacientes.',
    rpc: 'admin_metricas_locales',
  },
  {
    tipo: 'cifra',
    id: 'alertas-sin-revisar',
    titulo: 'Alertas sin revisar',
    descripcion: 'Las alertas de riesgo que nadie ha mirado todavía, por tipo y gravedad.',
    espacio: 'riesgo',
    sinonimos: ['alertas pendientes', 'fraude', 'señales de riesgo'],
    destino: { to: '/admin/alertas' },
    que: 'Las señales de riesgo que la base deduce de los datos (cuentas relacionadas, redes o teléfonos sospechosos al verificarse, y financiamientos por encima del cupo, que nunca deberían ocurrir) y que nadie ha marcado como revisadas.',
    rpc: 'admin_risk_alerts',
  },
] as const satisfies ReadonlyArray<Entrada>

/** El id de una cifra de Riesgo. Uno mal escrito no compila. */
export type IdCifraRiesgo = Extract<(typeof riesgo)[number], { tipo: 'cifra' }>['id']

/**
 * Qué es una cifra de Riesgo, en la frase del catálogo. Es lo que dice su
 * `InfoDot`: así la pantalla y la búsqueda explican la cifra con las mismas
 * palabras.
 */
export function queEsLaCifra(id: IdCifraRiesgo): string {
  for (const e of riesgo) if (e.tipo === 'cifra' && e.id === id) return e.que
  return ''
}
