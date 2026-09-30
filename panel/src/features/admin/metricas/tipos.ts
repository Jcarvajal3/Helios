// ═══════════════════════════════════════════════════════════════════════════
// Lo que el marco de Métricas le da a cada pestaña.
//
// Una pestaña es un componente `Pestana<Id>(props: PropsPestana<Busqueda<Id>>)`
// que no lee la URL ni el reloj por su cuenta: la semana, el local y sus
// propias claves le llegan ya validados, y las cambia con `cambiarBusqueda`.
// Así se puede montar en otra pantalla —o en una prueba— sin el router.
//
// Las sub-pestañas las pinta el marco (`pestanas.ts` dice cuáles hay): un
// componente que pinta varias recibe la elegida en `sub`
// (`PropsSubpestana`) y NUNCA pinta su propio selector de sub-vista.
// ═══════════════════════════════════════════════════════════════════════════

/** Cómo se escribe un cambio de la búsqueda en el historial. */
export type OpcionesDeCambio = {
  /**
   * `true` reescribe la entrada del historial en vez de añadir una: para un
   * filtro que se toquetea (un Segmented, una ventana). Cambiar de sub-vista
   * añade una, que es lo que espera «atrás». Por defecto, añade.
   */
  reemplazar?: boolean
}

/**
 * Lo que recibe una pestaña. `TBusqueda` es su `Busqueda<Id>` (el contrato lo
 * escribe `PropsPestana<B>`; el nombre largo lo pide la regla de ESLint de
 * los parámetros de tipo).
 */
export type PropsPestana<TBusqueda> = {
  /** El lunes de la semana elegida, 'YYYY-MM-DD' (día operativo). */
  semana: string
  /** El domingo que la cierra. */
  domingo: string
  /** La semana elegida es la que está en curso: sus cifras van a medias. */
  enCurso: boolean
  /** El día operativo de hoy (de medianoche a medianoche en Caracas), según el navegador. */
  hoy: string
  /** El uuid del local elegido, o `null`: todos los locales. */
  local: string | null
  /**
   * Su nombre, para escribirlo en una frase. `null` sin local, o mientras la
   * lista de locales no ha llegado (o si falló).
   */
  nombreLocal: string | null
  /** Las claves propias de la pestaña, ya validadas por su `validar<Id>`. */
  busqueda: TBusqueda
  /**
   * Cambia solo lo que se le pasa y deja lo demás como estaba: la semana, el
   * local y las otras claves de la pestaña. `undefined` quita una clave de la
   * URL (vuelve a su valor por defecto).
   */
  cambiarBusqueda: (parcial: Partial<TBusqueda>, opciones?: OpcionesDeCambio) => void
}

/**
 * Lo que recibe un componente que pinta varias sub-pestañas de una pestaña
 * (Mora, Caja, Gente, las de Cohortes en Cobros): lo de siempre y la
 * sub-pestaña que eligió el marco. `TSub` es `IdSubpestana<'mora'>`, o las
 * que pinte ese componente.
 */
export type PropsSubpestana<TBusqueda, TSub extends string> = PropsPestana<TBusqueda> & {
  /** La sub-pestaña que se mira, ya elegida y validada por el marco. */
  sub: TSub
}
