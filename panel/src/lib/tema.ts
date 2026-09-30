/**
 * El tema del panel: claro (el de por defecto), oscuro o el del sistema.
 *
 * Una recepción trabaja con luz de día y por eso Helios abre en claro; quien
 * prefiera el oscuro lo elige en el pie del menú y se recuerda en este
 * navegador. El CSS (tokens.gen.css y styles.css) lee `data-theme` en <html>:
 * `dark` fuerza el oscuro, `auto` sigue al sistema y cualquier otra cosa es
 * claro.
 */
export type Tema = 'claro' | 'oscuro' | 'sistema'

export const TEMAS: ReadonlyArray<Tema> = ['claro', 'oscuro', 'sistema']

export const CLAVE_TEMA = 'helios-panel:tema'

/** El valor de `data-theme` de cada tema. */
export const ATRIBUTO_DEL_TEMA: Record<Tema, string> = {
  claro: 'light',
  oscuro: 'dark',
  sistema: 'auto',
}

/** Lo guardado, o claro si no hay nada que se entienda. */
export function leerTema(valor: unknown): Tema {
  return TEMAS.find((t) => t === valor) ?? 'claro'
}

/** El siguiente en el ciclo del botón: claro → oscuro → sistema → claro. */
export function siguienteTema(tema: Tema): Tema {
  return TEMAS[(TEMAS.indexOf(tema) + 1) % TEMAS.length] ?? 'claro'
}

export function temaGuardado(): Tema {
  try {
    return leerTema(window.localStorage.getItem(CLAVE_TEMA))
  } catch {
    return 'claro'
  }
}

export function aplicarTema(tema: Tema): void {
  document.documentElement.dataset.theme = ATRIBUTO_DEL_TEMA[tema]
  try {
    window.localStorage.setItem(CLAVE_TEMA, tema)
  } catch {
    // Modo privado: el tema dura lo que dure la pestaña.
  }
}

/**
 * El script que va en <head>, antes de pintar nada: pone el tema guardado en
 * <html> para que el oscuro no parpadee en claro al cargar. Es texto y no una
 * función porque corre antes de que exista el bulto de la aplicación.
 */
export const SCRIPT_DEL_TEMA = `(function(){try{var t=localStorage.getItem('${CLAVE_TEMA}');var a={claro:'light',oscuro:'dark',sistema:'auto'}[t]||'light';document.documentElement.dataset.theme=a}catch(e){}})()`
