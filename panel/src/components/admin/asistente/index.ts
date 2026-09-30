/*
 * El asistente de solo lectura del super admin. Lo que se usa desde fuera:
 *
 *   AsistenteProvider        la conversación y el atajo Ctrl J, para todo el panel.
 *   useAsistentePanel        abrir, cerrar, preguntar o empezar de nuevo desde cualquier sitio.
 *   useAnfitrionDeCharla     una pantalla (Inicio) se ofrece como sitio de la charla.
 *   ConversacionAsistente    la conversación, en el cajón o en una página.
 *   CampoPregunta            el campo de la pregunta, en sus dos formas.
 *   SugerenciasDelAsistente  las preguntas de ejemplo, en píldora.
 *   PanelAsistente           el contenido del cajón de la derecha.
 *   BotonAsistente           el botón de la barra de arriba.
 *   siNoHayNadaDelAsistente  lo que la paleta dice cuando no encuentra nada.
 */
export {
  AsistenteProvider,
  useAnfitrionDeCharla,
  useAsistentePanel,
  useConversacionDelAsistente,
} from './contexto'
export type { AnfitrionDeCharla, ContextoAsistente, ConversacionDelAsistente } from './contexto'
export { COLUMNA_DE_LA_CHARLA, ConversacionAsistente } from './ConversacionAsistente'
export type { VarianteDeConversacion } from './ConversacionAsistente'
export { CampoPregunta } from './CampoPregunta'
export type { VarianteDelCampo } from './CampoPregunta'
export { SUGERENCIAS, SugerenciasDelAsistente } from './Sugerencias'
export { PanelAsistente } from './PanelAsistente'
export { BotonAsistente } from './BotonAsistente'
export { siNoHayNadaDelAsistente } from './enLaPaleta'
