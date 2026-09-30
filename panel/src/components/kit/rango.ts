// ═══════════════════════════════════════════════════════════════════════════
// El rango de fechas, en funciones puras.
//
// Vivían en ui.tsx y se mudaron aquí cuando `Periodo` las necesitó: un archivo
// de `kit/` no puede importar valores de ui.tsx sin cerrar un ciclo. ui.tsx
// las reexporta, así que quien ya las usaba sigue importándolas de allí.
// ═══════════════════════════════════════════════════════════════════════════

export type Rango = {
  /** Día operativo inicial, 'YYYY-MM-DD'. */
  from: string
  /** Día operativo final, incluido. */
  to: string
}

export const MESES_LARGOS = [
  'enero',
  'febrero',
  'marzo',
  'abril',
  'mayo',
  'junio',
  'julio',
  'agosto',
  'septiembre',
  'octubre',
  'noviembre',
  'diciembre',
]

export const MESES_CORTOS = [
  'ene',
  'feb',
  'mar',
  'abr',
  'may',
  'jun',
  'jul',
  'ago',
  'sep',
  'oct',
  'nov',
  'dic',
]

/**
 * Suma días a un día suelto sin pasar por la zona horaria.
 *
 * `new Date('2026-09-15')` es medianoche UTC, que en Caracas es el 14 por la
 * tarde: sumar y volver a formatear con la fecha local devuelve el día
 * anterior. Con `Date.UTC` los dos extremos están en el mismo huso y la
 * aritmética es la de un calendario.
 */
export function sumarDias(dia: string, dias: number): string {
  const [y = 0, m = 1, d = 1] = dia.slice(0, 10).split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d) + dias * 86_400_000).toISOString().slice(0, 10)
}

/** El primer día del mes al que pertenece `dia`. */
export function primeroDelMes(dia: string): string {
  return `${dia.slice(0, 7)}-01`
}

/** Cuántos días abarca el rango, contando los dos extremos. */
export function diasDelRango(r: Rango): number {
  const [ay = 0, am = 1, ad = 1] = r.from.slice(0, 10).split('-').map(Number)
  const [by = 0, bm = 1, bd = 1] = r.to.slice(0, 10).split('-').map(Number)
  const ms = Date.UTC(by, bm - 1, bd) - Date.UTC(ay, am - 1, ad)
  return Math.round(ms / 86_400_000) + 1
}

/** Los atajos de siempre, calculados contra el día operativo de hoy. */
export function atajosDeRango(hoy: string): Array<{ label: string; rango: Rango }> {
  const mesPasado = sumarDias(primeroDelMes(hoy), -1)

  return [
    { label: '7 días', rango: { from: sumarDias(hoy, -6), to: hoy } },
    { label: '30 días', rango: { from: sumarDias(hoy, -29), to: hoy } },
    { label: '90 días', rango: { from: sumarDias(hoy, -89), to: hoy } },
    { label: 'Este mes', rango: { from: primeroDelMes(hoy), to: hoy } },
    { label: 'Mes pasado', rango: { from: primeroDelMes(mesPasado), to: mesPasado } },
  ]
}

/**
 * El rango dicho como lo diría una persona.
 *
 *   un solo día        'el 19 de septiembre'
 *   dentro de un mes   'del 1 al 19 de septiembre'
 *   dos meses          'del 28 de agosto al 19 de septiembre'
 *   dos años           'del 28 de agosto de 2025 al 19 de septiembre de 2026'
 *
 * Se repite en cada pestaña de Crecimiento, y con dos fechas sueltas
 * —'2026-09-01 → 2026-09-19'— hay que traducirlas en la cabeza cada vez.
 */
export function describirRango(r: Rango): string {
  const [ay = '', am = '', ad = ''] = r.from.slice(0, 10).split('-')
  const [by = '', bm = '', bd = ''] = r.to.slice(0, 10).split('-')

  const mesA = MESES_LARGOS[Number(am) - 1] ?? am
  const mesB = MESES_LARGOS[Number(bm) - 1] ?? bm

  if (r.from === r.to) return `el ${Number(ad)} de ${mesA} de ${ay}`
  if (ay !== by) {
    return `del ${Number(ad)} de ${mesA} de ${ay} al ${Number(bd)} de ${mesB} de ${by}`
  }
  if (am === bm) return `del ${Number(ad)} al ${Number(bd)} de ${mesA} de ${ay}`
  return `del ${Number(ad)} de ${mesA} al ${Number(bd)} de ${mesB} de ${by}`
}

/** '27 ago', y con el año si se pide: '27 ago 2025'. */
function diaCorto(dia: string, conAnio: boolean): string {
  const [y = '', m = '', d = ''] = dia.slice(0, 10).split('-')
  const mes = MESES_CORTOS[Number(m) - 1] ?? m
  return conAnio ? `${Number(d)} ${mes} ${y}` : `${Number(d)} ${mes}`
}

/**
 * '27 ago – 25 sep': el rango en lo que cabe en un botón.
 *
 * El año solo sale cuando el rango cruza de uno a otro; dentro del mismo año
 * no dice nada que no se sepa. Un solo día es solo ese día.
 */
export function rangoCorto(r: Rango): string {
  if (r.from === r.to) return diaCorto(r.from, false)
  const cruzaAnio = r.from.slice(0, 4) !== r.to.slice(0, 4)
  return `${diaCorto(r.from, cruzaAnio)} – ${diaCorto(r.to, cruzaAnio)}`
}

/** '2026-08-27' → '27/08/2026': como se escribe una fecha aquí. */
export function escribirFecha(dia: string): string {
  const [y = '', m = '', d = ''] = dia.slice(0, 10).split('-')
  return `${d}/${m}/${y}`
}

/**
 * Lo que alguien escribió en un campo de fecha, como 'YYYY-MM-DD', o `null`
 * si no es un día que exista.
 *
 * Acepta el día primero —'27/8/2026', '27-08-26'— y también la forma ISO. El
 * año de dos cifras es de este siglo. Un 31 de febrero no se corrige a marzo:
 * se rechaza, porque quien lo escribió se equivocó en algo.
 */
export function leerFecha(texto: string): string | null {
  const limpio = texto.trim()
  const iso = limpio.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/)
  const nuestra = limpio.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2}|\d{4})$/)

  let y: number
  let m: number
  let d: number
  if (iso) {
    y = Number(iso[1])
    m = Number(iso[2])
    d = Number(iso[3])
  } else if (nuestra) {
    d = Number(nuestra[1])
    m = Number(nuestra[2])
    const anio = nuestra[3]
    y = anio.length === 2 ? 2000 + Number(anio) : Number(anio)
  } else {
    return null
  }

  const fecha = new Date(Date.UTC(y, m - 1, d))
  if (fecha.getUTCFullYear() !== y || fecha.getUTCMonth() !== m - 1 || fecha.getUTCDate() !== d) {
    return null
  }
  return fecha.toISOString().slice(0, 10)
}

/**
 * Las dos fechas de «Rango propio», ya leídas y comprobadas, o por qué no
 * valen. El orden de las comprobaciones es el de los campos: primero que se
 * entiendan, luego que vayan en orden y luego que haya datos.
 */
export function leerRangoPropio(
  desde: string,
  hasta: string,
  maximo: string,
): { rango: Rango } | { error: string } {
  const from = leerFecha(desde)
  const to = leerFecha(hasta)
  if (from === null || to === null) {
    return { error: 'Escribe las dos fechas con el día primero, como 27/08/2026.' }
  }
  if (from > to) return { error: 'La fecha de inicio va después de la final.' }
  if (to > maximo) return { error: `Solo hay datos hasta el ${escribirFecha(maximo)}.` }
  return { rango: { from, to } }
}

/** El último día del mes al que pertenece `dia`. */
function ultimoDelMes(dia: string): string {
  return sumarDias(primeroDelMes(sumarDias(primeroDelMes(dia), 31)), -1)
}

/**
 * El rango de al lado, para las flechas del selector de fechas.
 *
 * Un rango que empieza el día 1 y acaba a fin de mes (o hoy, si es el mes en
 * curso) se mueve de mes en mes: la flecha desde «Este mes» lleva al mes
 * pasado ENTERO, no a los mismos 25 días corridos. Cualquier otro se mueve su
 * propio largo: desde «30 días», los 30 anteriores. Hacia delante nunca pasa
 * de `maximo`: si no cabe entero, acaba en `maximo` con el mismo largo.
 */
export function rangoDeAlLado(r: Rango, sentido: 1 | -1, maximo: string): Rango {
  const empiezaEnUno = r.from === primeroDelMes(r.from)
  const mismoMes = r.from.slice(0, 7) === r.to.slice(0, 7)
  const acabaElMes = r.to === ultimoDelMes(r.to) || r.to === maximo
  if (empiezaEnUno && mismoMes && acabaElMes) {
    const primero = sentido < 0 ? primeroDelMes(sumarDias(r.from, -1)) : sumarDias(ultimoDelMes(r.from), 1)
    const ultimo = ultimoDelMes(primero)
    return { from: primero, to: ultimo < maximo ? ultimo : maximo }
  }

  const n = diasDelRango(r)
  const to = sumarDias(r.to, n * sentido)
  if (to <= maximo) return { from: sumarDias(r.from, n * sentido), to }
  return { from: sumarDias(maximo, -(n - 1)), to: maximo }
}
