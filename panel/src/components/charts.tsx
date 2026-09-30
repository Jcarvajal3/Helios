/* ═══════════════════════════════════════════════════════════════════════════
   LOS GRÁFICOS DEL PANEL.

   Sin librería de gráficas: una librería trae su propio vocabulario visual
   —sus tipografías, sus radios, sus grises— y lo que hace que el panel se
   lea como un producto es que todo sale de los mismos tokens.

   Las reglas, en orden de importancia:

   1. **Se puede leer sin tocar nada.** Eje con marcas redondas, rejilla de un
      pelo, la cifra que importa escrita en el gráfico y la tabla entera a un
      clic en la cabecera (`ChartCard`). El globo del ratón ayuda; nunca es la
      única manera de leer un número.
   2. **Un cero es un dato.** Un día sin ventas deja una marca en la base, y un
      anillo al 0 % un punto a las 12: sin marca no se distinguen de un día
      que no existe o de una cifra sin leer.
   3. **Dos series no compiten, se comparan.** La de contexto va en gris y
      detrás; la protagonista, en el tono del área y delante (o dentro).
   4. **El color tiene un trabajo.** La serie principal lleva el tono del área
      (`var(--area)`), nunca el lima, que es de la acción principal. El
      estado —verde, ámbar, rojo— solo cuando algo ESTÁ bien o mal.

   Cada gráfico vive en charts/<archivo>.tsx y se importa desde aquí.
   ═══════════════════════════════════════════════════════════════════════════ */

// Lo común: la forma de los datos y la escala.
export { escalaBonita, escalaConSigno, parteDelTotal } from '@/components/charts/comun'
export type { ChartPoint, ChartSeries, LinePoint } from '@/components/charts/comun'
export { acumular } from '@/components/charts/geometria'

// Los colores.
export { SERIE, colorDeTono, rampaApilada, rampaOrdinal, tonoDeSerie } from '@/components/charts/tonos'
export type { TonoDeMarca } from '@/components/charts/tonos'

// El globo: lo que se lee al señalar un punto, una barra, una celda o una
// marca suelta. `Globo` va dentro del lienzo de un gráfico entero;
// `GloboFlotante`, `useGloboDeMarca`, `MarcaConGlobo` y
// `useRecorridoDeMarcas` son para todo lo demás (ver charts/lectura.tsx).
export {
  Globo,
  GloboFlotante,
  MarcaConGlobo,
  Muestra,
  lecturaDelPunto,
  useGloboDeMarca,
  useRecorridoDeMarcas,
  useSenalado,
} from '@/components/charts/lectura'
export type {
  ContenidoDelGlobo,
  DisparadorDelGlobo,
  FilaDelGlobo,
  FormaDeMuestra,
} from '@/components/charts/lectura'

// El marco común de un gráfico.
export { ChartCard } from '@/components/charts/tarjeta'
export type { ChartCardProps, EntradaDeLeyenda } from '@/components/charts/tarjeta'

// Barras, columnas apiladas y líneas en una tarjeta entera.
export { BarChart } from '@/components/charts/barras'
export type { BarChartProps } from '@/components/charts/barras'
export { LineChart } from '@/components/charts/lineas'
export type { LineChartProps } from '@/components/charts/lineas'
export { ColumnasApiladas } from '@/components/charts/columnasApiladas'
export type {
  ColumnaApilada,
  ColumnasApiladasProps,
  MarcadorDeColumnas,
  SerieApilada,
} from '@/components/charts/columnasApiladas'

// Lo que cabe dentro de una cifra.
export { Ring } from '@/components/charts/anillo'
export type { RingProps } from '@/components/charts/anillo'
export { MiniBarras, StackedBar } from '@/components/charts/compactos'
export type {
  MiniBarrasProps,
  PuntoDeMiniBarras,
  SegmentoApilado,
  StackedBarProps,
} from '@/components/charts/compactos'
export { Sparkline } from '@/components/charts/sparkline'
export type { SparklineProps } from '@/components/charts/sparkline'

// Repartos, embudos y cohortes.
export { ShareBars } from '@/components/charts/reparto'
export type { ShareBarsProps, ShareRow } from '@/components/charts/reparto'
export { FunnelSteps } from '@/components/charts/embudo'
export type { FunnelStep } from '@/components/charts/embudo'
export { CohortGrid, tinteCohorte } from '@/components/charts/cohortes'
export type { CohortCell, CohortGridRow } from '@/components/charts/cohortes'
