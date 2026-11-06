// Cómo se escriben los precios y las fechas en la página del paciente. Sin
// `Intl`: el estilo venezolano sale igual en cualquier navegador.

function conMiles(entero: string): string {
  return entero.replace(/\B(?=(\d{3})+(?!\d))/g, '.')
}

/** «Bs 55.432,10», «$12,50», «$100». */
export function textoDePrecio(moneda: 'VES' | 'USD', precio: number): string {
  if (moneda === 'VES') {
    const [entero, decimales] = precio.toFixed(2).split('.')
    return `Bs ${conMiles(entero)},${decimales}`
  }
  const [entero, decimales] = precio.toFixed(2).split('.')
  return decimales === '00' ? `$${conMiles(entero)}` : `$${conMiles(entero)},${decimales}`
}

/** El día de Caracas de una fecha: «05/11/2026». */
export function fechaDeCaracas(iso: string): string {
  const fecha = new Date(iso)
  if (Number.isNaN(fecha.getTime())) return ''
  const partes = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Caracas',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(fecha)
  const [a, m, d] = partes.split('-')
  return `${d}/${m}/${a}`
}

/** Solo se abre un enlace https. La base ya lo exige; esto es la segunda llave. */
export function enlaceSeguro(url: string): string | null {
  try {
    return new URL(url).protocol === 'https:' ? url : null
  } catch {
    return null
  }
}

/** El token de `#/medicinas/<token>`, o null si la dirección es otra. */
export function tokenDelHash(hash: string): string | null {
  const m = hash.match(/^#\/medicinas\/([0-9a-z]+)$/)
  return m ? m[1] : null
}
