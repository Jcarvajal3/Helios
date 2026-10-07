// ═══════════════════════════════════════════════════════════════════════════
// Las cuentas pequeñas de Ajustes que se prueban solas: la variación de la
// tasa, la cuenta de cobro de relleno y el efecto de una versión mínima.
// ═══════════════════════════════════════════════════════════════════════════

import type { Moneda } from '@/components/ui'

/**
 * La tasa con cuatro decimales y su unidad completa: '36,5244 Bs./$'.
 *
 * El BCV publica varias tasas el mismo día, y Helios usa dos: la del dólar y
 * la del euro. Sin el «/$» o el «/€» al lado no se ve de un vistazo si la que
 * entró es la que tenía que entrar.
 */
export function formatTasa(tasa: number, moneda: Moneda = 'USD'): string {
  return `${tasa.toLocaleString('es-VE', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 4,
  })} Bs./${moneda === 'EUR' ? '€' : '$'}`
}

/**
 * Cuánto cambia `nueva` frente a `vigente`, en porcentaje. `null` si no hay
 * con qué comparar: sin tasa vigente, «+∞ %» no le dice nada a nadie.
 */
export function variacionPct(vigente: number | null, nueva: number): number | null {
  if (vigente === null || !Number.isFinite(vigente) || vigente <= 0) return null
  return ((nueva - vigente) / vigente) * 100
}

/** '+2,35 %' / '−0,40 %' / '0,00 %'. El signo va siempre: es lo primero que se lee. */
export function formatVariacion(pct: number | null): string {
  if (pct === null) return '—'
  const cifra = Math.abs(pct).toLocaleString('es-VE', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })
  if (cifra === '0,00') return '0,00 %'
  return `${pct > 0 ? '+' : '−'}${cifra} %`
}

/** 'a', 'a y b', 'a, b y c': una lista dicha como en una frase. */
export function enumerar(partes: ReadonlyArray<string>): string {
  if (partes.length <= 1) return partes.join('')
  return `${partes.slice(0, -1).join(', ')} y ${partes[partes.length - 1]}`
}

/**
 * La cuenta de relleno con la que se sembró la tabla: un RIF de ceros.
 *
 * No es una cuenta, es un hueco con forma de cuenta. La app la enseña igual y
 * la persona transfiere a un sitio donde no hay nada que aprobar. Se miran
 * solo los dígitos: «J-000000000» y «000000000» son la misma.
 */
export function esCuentaDeRelleno(rif: string): boolean {
  const digitos = rif.replace(/\D/g, '')
  return digitos !== '' && /^0+$/.test(digitos)
}

