import { metricasCaja } from './caja'
import { metricasCobranza } from './cobranza'
import { metricasCohortes } from './cohortes'
import { metricasGeneral } from './general'
import { metricasGente } from './gente'
import { metricasLocales } from './locales'
import { pantallasDeMetricas } from './pantallas'
import { metricasSemana } from './semana'

/**
 * Métricas en el catálogo: la pantalla, sus pestañas y sus sub-pestañas
 * (`pantallas.ts`), y lo de cada una, en el archivo de la carpeta que la
 * pinta y de su dueño. En el orden de las pestañas: Semana, Cobros (Cohortes),
 * Mora (Cobranza), Caja, Locales, Gente y Global (General). Los avisos se
 * mudaron el 29-09 a Notificaciones › Rendimiento (`catalogo/avisos.ts`).
 */
export const metricas = [
  ...pantallasDeMetricas,
  ...metricasSemana,
  ...metricasCohortes,
  ...metricasCobranza,
  ...metricasCaja,
  ...metricasLocales,
  ...metricasGente,
  ...metricasGeneral,
] as const
