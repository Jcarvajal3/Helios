import { SERIE, rampaApilada } from '@/components/charts'
import type { EstadoDeCuota } from '@/features/admin/metricas/cohortes/tipos'

// ═══════════════════════════════════════════════════════════════════════════
// El color de cada estado, el mismo en la lista, en las tarjetas de cuota,
// en el gráfico y en las tablas. Todo son variables del panel: lo cobrado en
// el tono del área (azul en Cobranza), lo cobrado tarde un paso más claro, lo
// vencido en ámbar, lo por vencer en gris y lo perdido en rojo. El color de
// estado solo sale donde algo ESTÁ mal (vencido, perdido).
// ═══════════════════════════════════════════════════════════════════════════

/** Lo que todavía no vence: gris, detrás, sin avisar de nada. */
const POR_VENCER = 'color-mix(in oklab, var(--color-panel-muted) 55%, transparent)'

export const COLOR_DE_ESTADO: Record<EstadoDeCuota, string> = {
  a_tiempo: SERIE.principal,
  tarde: rampaApilada(2)[1] ?? SERIE.principal,
  vencida: 'var(--color-warning)',
  por_vencer: POR_VENCER,
  perdida: 'var(--color-error)',
}
