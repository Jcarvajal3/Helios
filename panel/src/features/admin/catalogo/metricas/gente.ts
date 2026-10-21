import type { Entrada } from '../tipos'

/**
 * Las cifras NUEVAS de Métricas › Pacientes, para la búsqueda (Ctrl K) y el
 * asistente. Las de Crecimiento (registros, que son los pacientes que dan de
 * alta las clínicas, primer financiamiento, se financiaron, uso y cohortes de
 * registro) ya están en `gerencia.ts` y `directorio.ts`, con su destino aquí:
 * no se duplican.
 */
export const metricasGente = [
  {
    tipo: 'cifra',
    id: 'nuevas-en-el-local',
    titulo: 'Pacientes nuevos en la clínica',
    descripcion: 'Cuántos pacientes se financiaron por primera vez en una clínica en la ventana elegida.',
    espacio: 'metricas',
    sinonimos: ['nuevos en la clínica', 'primera visita', 'primera consulta', 'pacientes nuevos de una clínica', 'estrenaron en la clínica', 'pacientes'],
    destino: { to: '/admin/metricas', search: { vista: 'gente' } },
    que: 'Con una clínica elegida arriba: los pacientes cuya primera cuota en ESA clínica cae en la ventana, se hubieran financiado antes en otra o no. Sale de las cuotas.',
    rpc: 'admin_growth_overview',
  },
] as const satisfies ReadonlyArray<Entrada>
