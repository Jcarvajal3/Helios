import type { Entrada } from '../tipos'

/**
 * Las cifras NUEVAS de Métricas › Gente, para la búsqueda (Ctrl K) y el
 * asistente. Las de Crecimiento y el Perfil (registros, que son personas
 * verificadas, primer consumo,
 * consumieron, embudo, uso, grupos, cohortes de registro, perfil de la
 * gente) ya están en `gerencia.ts` y `directorio.ts`, con su destino aquí:
 * no se duplican.
 */
export const metricasGente = [
  {
    tipo: 'cifra',
    id: 'nuevas-en-el-local',
    titulo: 'Pacientes nuevos en la clínica',
    descripcion: 'Cuántos pacientes se financiaron por primera vez en una clínica en la ventana elegida.',
    espacio: 'metricas',
    sinonimos: ['nuevas en la clínica', 'nuevos en la clínica', 'primera visita', 'pacientes nuevos de una clínica', 'estrenaron en la clínica', 'pacientes'],
    destino: { to: '/admin/metricas', search: { vista: 'gente' } },
    que: 'Con una clínica elegida arriba: los pacientes cuya primera cuota en ESA clínica cae en la ventana, se hubieran financiado antes en otro o no. Sale de las cuotas: en un financiamiento de grupo cuenta cada integrante que pagó su parte.',
    rpc: 'admin_growth_overview',
  },
  {
    tipo: 'cifra',
    id: 'retencion-de-un-local',
    titulo: 'Retención de una clínica',
    descripcion: 'La gente que llegó junta a una clínica y cuánta volvió a financiarse allí.',
    espacio: 'metricas',
    sinonimos: ['vuelven a la clínica', 'fidelidad', 'repiten en la clínica', 'cohortes de una clínica'],
    destino: { to: '/admin/metricas', search: { vista: 'gente', sub: 'retencion' } },
    que: 'Con una clínica elegida arriba, cada cohorte son los pacientes cuya primera cuota en esa clínica cayó en el mismo día, semana o mes; sus columnas dicen cuántos se financiaron allí en cada periodo siguiente y lo financiado, sin el service fee.',
    rpc: 'admin_user_cohorts',
  },
  {
    tipo: 'cifra',
    id: 'quien-sostiene-el-consumo',
    titulo: 'Concentración del financiado (sin fee)',
    descripcion: 'Qué parte del financiado mueve el 10 % de los pacientes que más gastan.',
    espacio: 'metricas',
    sinonimos: ['quién sostiene el financiamiento', 'concentración del gasto', 'top 10 %', 'dependencia de pocos', 'pareto'],
    destino: { to: '/admin/metricas', search: { vista: 'gente', sub: 'uso' } },
    que: 'Los pacientes que se financiaron en la ventana, ordenados por su financiado y partidos en tres bloques (el 10 % de arriba, el 40 % siguiente y la mitad de abajo), con el financiado de cada bloque sin el service fee.',
    rpc: 'admin_user_behavior',
  },
] as const satisfies ReadonlyArray<Entrada>
