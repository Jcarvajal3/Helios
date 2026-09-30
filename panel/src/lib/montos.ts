// ═══════════════════════════════════════════════════════════════════════════
// Leer un monto que alguien escribió a mano.
//
// Lo que había en cada formulario era `Number(x.replace(',', '.'))`, y eso
// solo sirve para «1250,5». Con lo que de verdad se escribe en Venezuela
// falla de dos maneras, y las dos son peores que un error:
//
//   · «1.250.400,00» → `replace` cambia solo la primera coma, queda
//     «1.250.400.00» y `Number` da NaN. El botón se apaga sin decir por qué.
//   · «10.000» → `Number` lo lee como diez. Un techo de diez mil euros se
//     guardaba como diez, y eso no lo avisa nadie.
//
// Las reglas, en orden:
//
//   1. Fuera los símbolos de moneda (€, Bs, Bs., $, USD, EUR, VES) y los
//      espacios. Un signo menos (o más) delante se respeta.
//   2. Si hay punto y coma a la vez, el que va más a la derecha es el decimal
//      y el otro es de miles.
//   3. Si solo hay comas, la coma es el decimal. Dos comas no son un número.
//   4. Si hay varios puntos, son de miles.
//   5. Un solo punto es decimal, salvo que le sigan exactamente tres dígitos y
//      lo de delante sea un grupo de miles válido: «1.250» es mil doscientos
//      cincuenta, «1250.50» y «0.125» son decimales.
//
// Los separadores de miles tienen que agrupar de tres en tres. «1.25,00» no se
// adivina: se devuelve null y el formulario lo marca, que en dinero es mejor
// que acertar la mitad de las veces.
// ═══════════════════════════════════════════════════════════════════════════

/** Los símbolos que se toleran pegados o separados de la cifra. */
const SIMBOLOS = /bs\.?|usd|eur|ves|€|\$/gi

/**
 * Un monto escrito a mano, a número. `null` si está vacío o no se entiende.
 *
 * leerMonto('1.250.400,00') → 1250400
 * leerMonto('€ 12,50')      → 12.5
 * leerMonto('1.250')        → 1250
 * leerMonto('1250.50')      → 1250.5
 * leerMonto('-3,5 Bs')      → -3.5
 * leerMonto('doce')         → null
 */
export function leerMonto(texto: string): number | null {
  const limpio = texto.replace(SIMBOLOS, '').replace(/\s/g, '')
  if (limpio === '') return null

  const partes = /^([+-]?)([\d.,]+)$/.exec(limpio)
  if (!partes) return null

  const signo = partes[1] === '-' ? -1 : 1
  const cifra = partes[2]
  if (!/\d/.test(cifra)) return null

  const normal = normalizar(cifra)
  if (normal === null) return null

  const valor = Number(normal)
  if (!Number.isFinite(valor)) return null

  // `-0` se lee igual que 0 en pantalla, pero `Object.is` y algunos
  // comparadores lo distinguen. Un cero es un cero.
  return valor === 0 ? 0 : signo * valor
}

/**
 * La cifra sin signo, a la forma que entiende `Number` («1250400.5»).
 * `null` si los separadores no cuadran.
 */
function normalizar(cifra: string): string | null {
  const ultimaComa = cifra.lastIndexOf(',')
  const ultimoPunto = cifra.lastIndexOf('.')

  // Sin separadores: un entero.
  if (ultimaComa === -1 && ultimoPunto === -1) return cifra

  // Los dos: manda el de la derecha.
  if (ultimaComa !== -1 && ultimoPunto !== -1) {
    const decimal = ultimaComa > ultimoPunto ? ',' : '.'
    const miles = decimal === ',' ? '.' : ','
    return conDecimal(cifra, decimal, miles)
  }

  // Solo comas: la coma es decimal, y tiene que ser una.
  if (ultimaComa !== -1) return conDecimal(cifra, ',', null)

  // Solo puntos.
  const puntos = cifra.split('.').length - 1
  if (puntos > 1) return enteroConMiles(cifra, '.')

  // Lo de delante tiene que poder ser el primer grupo de miles: de uno a tres
  // dígitos y sin un cero delante. «1234.567» y «0.125» son decimales.
  const [entera, fraccion] = cifra.split('.')
  if (fraccion.length === 3 && /^[1-9]\d{0,2}$/.test(entera)) return entera + fraccion

  return conDecimal(cifra, '.', null)
}

/**
 * Parte entera (con o sin separador de miles) y decimales.
 * El separador decimal aparece una sola vez.
 */
function conDecimal(cifra: string, decimal: ',' | '.', miles: ',' | '.' | null): string | null {
  const trozos = cifra.split(decimal)
  if (trozos.length !== 2) return null

  const [entera, fraccion] = trozos
  if (!/^\d*$/.test(fraccion)) return null

  const enteraLimpia = miles === null ? entera : enteroConMiles(entera, miles)
  if (enteraLimpia === null || !/^\d*$/.test(enteraLimpia)) return null
  if (enteraLimpia === '' && fraccion === '') return null

  // «,5» es 0,5 y «12,» es 12: se escriben así a medio teclear.
  return `${enteraLimpia || '0'}.${fraccion || '0'}`
}

/** «1.250.400» → «1250400», comprobando que agrupa de tres en tres. */
function enteroConMiles(entera: string, miles: ',' | '.'): string | null {
  if (!entera.includes(miles)) return entera

  const grupos = entera.split(miles)
  const [primero, ...resto] = grupos
  if (!/^\d{1,3}$/.test(primero)) return null
  if (!resto.every((g) => /^\d{3}$/.test(g))) return null

  return grupos.join('')
}

/**
 * Un número, listo para rellenar un campo que después lee `leerMonto`.
 *
 * Con coma decimal y sin separador de miles, que es lo más fácil de editar,
 * y con TODOS los decimales que tenga: un porcentaje de 2,125 que se
 * rellenara como «2,13» cambiaría de valor al guardar sin que nadie lo
 * tocara. No se usa `String(n)` a secas porque «1.125» volvería de
 * `leerMonto` como mil ciento veinticinco.
 *
 * formatoMontoEditable(1250400.5) → '1250400,5'
 * formatoMontoEditable(12)        → '12'
 * formatoMontoEditable(null)      → ''
 */
export function formatoMontoEditable(n: number | null | undefined): string {
  if (n === null || n === undefined || !Number.isFinite(n)) return ''
  // Seis decimales de tope: 0.1 + 0.2 no tiene que salir como
  // «0,30000000000000004» en un campo de dinero.
  const redondo = Number(n.toFixed(6))
  return String(redondo === 0 ? 0 : redondo).replace('.', ',')
}
