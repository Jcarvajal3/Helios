// ═══════════════════════════════════════════════════════════════════════════
// El kit de Métricas: las piezas que repiten las ocho pestañas.
//
// Encima del kit del panel (`@/components/ui`, `@/components/charts`), no en
// su lugar: `CifraConTendencia` es un `Stat`, `BarraSegmentada` es una
// `StackedBar`. Lo que aquí se añade es lo que Métricas pide y el panel no
// tenía: la chispa de N semanas, el aviso de «no se parte por local», la
// frase con cifras y la tabla plegada de cada gráfico.
// ═══════════════════════════════════════════════════════════════════════════

export { BarraSegmentada } from './BarraSegmentada'
export type { SegmentoDeBarra } from './BarraSegmentada'
export { Chispa } from './Chispa'
export type { ChispaProps } from './Chispa'
export { CifraConTendencia } from './CifraConTendencia'
export type { CifraConTendenciaProps } from './CifraConTendencia'
export { FraseConCifras } from './FraseConCifras'
export type { ParteDeFrase } from './FraseConCifras'
export { NoSeParte } from './NoSeParte'
export { NumerosEnDetalles } from './NumerosEnDetalles'
export { SeccionMetricas } from './SeccionMetricas'
