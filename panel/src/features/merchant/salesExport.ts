import { construirCsv, descargarCsv } from '@/lib/csv'
import { comoLista } from '@/lib/json'
import { supabase } from '@/lib/supabase'

import { COLUMNAS_VENTAS, leerFilaDeVentas } from './ventas'
import type { FilaDeVentas } from './ventas'

export { QUE_LLEVA } from './ventas'

// ═══════════════════════════════════════════════════════════════════════════
// Descargar el libro de financiamientos de la clínica. Lo que lleva cada
// fila, y por qué, está en `ventas.ts`; aquí solo la llamada y el archivo.
// ═══════════════════════════════════════════════════════════════════════════

export async function fetchSalesExport(params: { from: string; to: string }): Promise<FilaDeVentas[]> {
  const { data, error } = await supabase.rpc('merchant_sales_export', {
    p_from: params.from,
    p_to: params.to,
  })
  if (error) throw error
  return comoLista(data).map(leerFilaDeVentas)
}

/**
 * Arma el archivo y lo descarga. Devuelve cuántas filas llevaba.
 *
 * El nombre lleva el rango dentro: en la carpeta del contador van a acabar
 * doce de estos, y «ventas.csv (3)» no le dice a nadie de qué mes es.
 */
export async function descargarVentas(params: {
  from: string
  to: string
  merchantName: string
}): Promise<number> {
  const rango = params.from === params.to ? params.from : `${params.from}_a_${params.to}`
  const clinica = params.merchantName
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-zA-Z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .toLowerCase()

  const filas = await fetchSalesExport(params)
  descargarCsv(`helios_${clinica}_financiamientos_${rango}`, construirCsv(COLUMNAS_VENTAS, filas))
  return filas.length
}
