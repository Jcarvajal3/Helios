/*
 * La paleta del super admin (Ctrl K). Lo que se usa desde fuera:
 *
 *   PaletaDelPanel   el atajo y la ventana; se monta una vez, en el marco.
 *   BuscadorDeLaBarra el botón de la barra de arriba que la abre.
 *   useCapturaDelAtajo  quién se queda Ctrl K en vez de la paleta (Inicio).
 *   abrirPaleta      la abre desde otro sitio, con un texto ya escrito si se
 *                    le pasa («Buscar en el panel» del asistente).
 *   SiNoHayNada      el punto de extensión de «no hay resultados».
 *   interpretar      qué parece un texto (orden, teléfono, cédula…), por si
 *                    otra búsqueda del panel quiere leerlo igual.
 */
export {
  BuscadorDeLaBarra,
  PaletaDelPanel,
  abrirPaleta,
  useAtajoDePaleta,
  useCapturaDelAtajo,
} from './PaletaDelPanel'
export type { SiNoHayNada } from './Paleta'
export { interpretar, parteNacional, soloDigitos } from './consulta'
export type { Consulta, Forma } from './consulta'
