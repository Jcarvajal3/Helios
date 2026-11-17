/**
 * LAS FUENTES DE GOOGLE — quién descarga cuál.
 *
 * Desde el rediseño del 2026-11-12 todo va en Inter Tight, con Instrument
 * Serif en cursiva para la palabra que se subraya. La portada, las páginas
 * para buscadores (`Guia`), el login y la afiliación suman Geist Mono para
 * sus rótulos. Antes
 * las del panel iban en el `__root` y la portada las bajaba sin usarlas: una
 * hoja que bloquea el primer pintado, y Google mide ese pintado (LCP).
 *
 * Cada ruta pide las suyas en su `head`; el `preconnect` sigue en el root.
 */
export const FUENTES_DEL_PANEL = {
  rel: 'stylesheet',
  href: 'https://fonts.googleapis.com/css2?family=Inter+Tight:wght@400;500;600;700&family=Instrument+Serif:ital@0;1&display=swap',
}

export const FUENTES_DE_LA_PORTADA = {
  rel: 'stylesheet',
  href: 'https://fonts.googleapis.com/css2?family=Inter+Tight:wght@300;400;500;600;700&family=Geist+Mono:wght@400;500&family=Instrument+Serif:ital@0;1&display=swap',
}
