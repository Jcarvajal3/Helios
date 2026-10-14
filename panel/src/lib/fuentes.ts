/**
 * LAS FUENTES DE GOOGLE — quién descarga cuál.
 *
 * El panel (y las páginas públicas con su aspecto: afiliación, soporte,
 * legales) usa Outfit y Source Sans 3. La portada y las páginas para
 * buscadores (`Guia`) usan Geist, Geist Mono e Instrument Serif. Antes las
 * del panel iban en el `__root` y la portada las bajaba sin usarlas: una hoja
 * que bloquea el primer pintado, y Google mide ese pintado (LCP).
 *
 * Cada ruta pide las suyas en su `head`; el `preconnect` sigue en el root.
 */
export const FUENTES_DEL_PANEL = {
  rel: 'stylesheet',
  href: 'https://fonts.googleapis.com/css2?family=Outfit:wght@400;500;600;700;900&family=Source+Sans+3:wght@400;500;600;700&display=swap',
}

export const FUENTES_DE_LA_PORTADA = {
  rel: 'stylesheet',
  href: 'https://fonts.googleapis.com/css2?family=Geist:wght@300..700&family=Geist+Mono:wght@400;500&family=Instrument+Serif:ital@0;1&display=swap',
}
