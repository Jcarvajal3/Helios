import { primeroDelMes, sumarDias } from '@/components/ui'
import type { Rango } from '@/components/ui'
import { domingoDe, lunesDe } from '@/features/admin/semana'
import type { BusquedaJuanPablo } from './busqueda'

// ═══════════════════════════════════════════════════════════════════════════
// El periodo de Métricas › Juan Pablo: un día, una semana, un mes o un rango
// propio. Por defecto, hoy.
//
// No mira la semana de arriba: lleva su propio selector (`Periodo`, el de
// todo el panel) en el hueco de la semana. En la URL van `desde` y `hasta`;
// hoy no se escribe, para que quien entra sin elegir nada tenga una URL limpia
// y un enlace sin fechas abra siempre el día de hoy.
//
// Puro: se prueba en `periodo.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** El periodo que se mira: el de la URL o, sin él, hoy. Nunca pasa de hoy. */
export function rangoElegido(busqueda: BusquedaJuanPablo, hoy: string): Rango {
  const to = busqueda.hasta && busqueda.hasta < hoy ? busqueda.hasta : hoy
  const from = busqueda.desde && busqueda.desde <= to ? busqueda.desde : to
  return { from, to }
}

/** Lo que se escribe en la URL para un periodo: nada si es hoy. */
export function busquedaDelRango(rango: Rango, hoy: string): BusquedaJuanPablo {
  if (rango.from === hoy && rango.to === hoy) return { desde: undefined, hasta: undefined }
  return { desde: rango.from, hasta: rango.to }
}

/**
 * Los atajos del selector, del más corto al más largo. Los que acaban en
 * hoy (esta semana, este mes, este año) van a medias: lo dice su rango.
 */
export function atajosDeJuanPablo(hoy: string): Array<{ label: string; rango: Rango }> {
  const ayer = sumarDias(hoy, -1)
  const lunes = lunesDe(hoy)
  const mesPasado = sumarDias(primeroDelMes(hoy), -1)
  return [
    { label: 'Hoy', rango: { from: hoy, to: hoy } },
    { label: 'Ayer', rango: { from: ayer, to: ayer } },
    { label: 'Esta semana', rango: { from: lunes, to: hoy } },
    { label: 'Semana pasada', rango: { from: sumarDias(lunes, -7), to: domingoDe(sumarDias(lunes, -7)) } },
    { label: 'Últimos 30 días', rango: { from: sumarDias(hoy, -29), to: hoy } },
    { label: 'Este mes', rango: { from: primeroDelMes(hoy), to: hoy } },
    { label: 'Mes pasado', rango: { from: primeroDelMes(mesPasado), to: mesPasado } },
    { label: 'Este año', rango: { from: `${hoy.slice(0, 4)}-01-01`, to: hoy } },
  ]
}
