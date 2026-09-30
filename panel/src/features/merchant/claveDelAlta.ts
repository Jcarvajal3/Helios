// ═══════════════════════════════════════════════════════════════════════════
// La clave de idempotencia del alta que está en pantalla.
//
// `create_patient_charge` recibe una `p_idempotency_key` y, si ya la vio,
// devuelve el MISMO financiamiento sin crear otro (contrato §1.3). La clave
// tiene que ser estable desde que se abre el formulario hasta que el alta
// sale bien, porque los dos accidentes que evita son:
//
//   · el doble clic en «Confirmar» (o Enter dos veces), y
//   · la recarga con la respuesta perdida: el alta llegó a la base pero la
//     pantalla no se enteró, y la secretaria lo vuelve a intentar.
//
// Por eso vive en `sessionStorage` y no en el estado de React, que muere con
// la recarga. En `sessionStorage` y no en `localStorage`: es de ESTA
// pestaña. Dos pestañas con dos pacientes distintos no pueden compartir
// clave, o la segunda recibiría el financiamiento de la primera.
//
// Tras un alta buena se tira y se estrena otra: el paciente siguiente es otro
// financiamiento.
//
// Los datos del paciente NO se guardan aquí. Son datos personales, y la clave
// sola ya basta para no duplicar: si tras recargar se teclea el mismo alta,
// la base devuelve la de antes; si se teclea otra, la pantalla lo detecta
// (`coincideConLoPedido`) y ofrece empezar de cero.
// ═══════════════════════════════════════════════════════════════════════════

const CLAVE = 'helios.alta.idempotencia'

/**
 * Pasado este rato la clave se descarta. Un formulario abierto un día entero
 * no está protegiendo ningún doble clic, y una clave vieja que se colara en
 * el alta de otro paciente devolvería un financiamiento ajeno.
 */
const VIDA_MS = 12 * 60 * 60 * 1000

/** Lo mínimo de `Storage` que hace falta; en las pruebas es un objeto. */
export type Almacen = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>

type Apunte = { clave: string; creada: number }

function almacenDelNavegador(): Almacen | null {
  // En el render del servidor no hay `sessionStorage`, y el panel hace SSR.
  return typeof sessionStorage === 'undefined' ? null : sessionStorage
}

/** Un uuid v4. `crypto.randomUUID` existe en todos los navegadores del panel. */
function generarClave(): string {
  return crypto.randomUUID()
}

function leer(almacen: Almacen, ahora: number): string | null {
  try {
    const crudo = almacen.getItem(CLAVE)
    if (!crudo) return null
    const apunte = JSON.parse(crudo) as Partial<Apunte>
    if (typeof apunte.clave !== 'string' || typeof apunte.creada !== 'number') return null
    if (apunte.clave.length < 16) return null
    if (ahora - apunte.creada > VIDA_MS || apunte.creada > ahora) return null
    return apunte.clave
  } catch {
    return null
  }
}

function guardar(almacen: Almacen, clave: string, ahora: number): void {
  try {
    almacen.setItem(CLAVE, JSON.stringify({ clave, creada: ahora } satisfies Apunte))
  } catch {
    // Modo incógnito o cuota llena: se pierde la protección de la recarga,
    // no la del doble clic, que sigue en memoria.
  }
}

/**
 * La clave del alta en curso: la guardada si la hay y sigue viva, o una nueva
 * que se guarda en el acto.
 */
export function claveDelAlta(
  almacen: Almacen | null = almacenDelNavegador(),
  ahora: number = Date.now(),
  generar: () => string = generarClave,
): string {
  const guardada = almacen ? leer(almacen, ahora) : null
  if (guardada) return guardada

  const nueva = generar()
  if (almacen) guardar(almacen, nueva, ahora)
  return nueva
}

/**
 * Tira la clave y estrena otra. Tras un alta buena, o cuando la secretaria
 * decide empezar de cero con otro paciente.
 */
export function estrenarClaveDelAlta(
  almacen: Almacen | null = almacenDelNavegador(),
  ahora: number = Date.now(),
  generar: () => string = generarClave,
): string {
  const nueva = generar()
  if (almacen) guardar(almacen, nueva, ahora)
  return nueva
}
