// ═══════════════════════════════════════════════════════════════════════════
// El texto del asistente, en bloques que se pintan con el kit.
//
// El modelo escribe con un Markdown sencillo: párrafos, listas y alguna
// negrita. No hace falta una librería para eso, y una librería de Markdown
// traería HTML crudo a la página. Aquí se entienden solo esas tres cosas; lo
// demás se lee como texto. Se prueba en `texto.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Un trozo de una línea: texto normal o en negrita. */
export type Trozo = { texto: string; negrita: boolean }

export type Bloque =
  | { tipo: 'parrafo'; lineas: Trozo[][] }
  | { tipo: 'lista'; ordenada: boolean; elementos: Trozo[][] }
  | { tipo: 'titulo'; trozos: Trozo[] }

const VINETA = /^\s*[-*•]\s+(.*)$/
const NUMERADA = /^\s*\d+[.)]\s+(.*)$/
const TITULO = /^\s*#{1,6}\s+(.*)$/

/**
 * Los trozos de una línea. `**así**` va en negrita; un asterisco suelto se
 * queda como está. Mientras llega el texto puede haber una negrita abierta
 * sin cerrar: se pinta ya en negrita y se cierra sola al llegar el resto.
 */
export function trozosDe(linea: string): Trozo[] {
  const partes = linea.split('**')
  return partes
    .map((texto, i) => ({ texto, negrita: i % 2 === 1 }))
    .filter((t) => t.texto !== '')
}

/** El texto de la respuesta, partido en párrafos, listas y títulos. */
export function bloquesDe(texto: string): Bloque[] {
  const bloques: Bloque[] = []
  let parrafo: Trozo[][] | null = null
  let lista: { ordenada: boolean; elementos: Trozo[][] } | null = null

  const cerrar = () => {
    if (parrafo) bloques.push({ tipo: 'parrafo', lineas: parrafo })
    if (lista) bloques.push({ tipo: 'lista', ...lista })
    parrafo = null
    lista = null
  }

  for (const linea of texto.replace(/\r\n?/g, '\n').split('\n')) {
    if (linea.trim() === '') {
      cerrar()
      continue
    }

    const titulo = linea.match(TITULO)
    if (titulo) {
      cerrar()
      bloques.push({ tipo: 'titulo', trozos: trozosDe(titulo[1]) })
      continue
    }

    const vineta = linea.match(VINETA)
    const numerada = vineta ? null : linea.match(NUMERADA)
    const elemento = vineta ?? numerada
    if (elemento) {
      const ordenada = numerada !== null
      if (parrafo || (lista && lista.ordenada !== ordenada)) cerrar()
      lista ??= { ordenada, elementos: [] }
      lista.elementos.push(trozosDe(elemento[1]))
      continue
    }

    // Una línea sin marca justo debajo de un elemento de lista es su
    // continuación; en cualquier otro caso, una línea más del párrafo.
    if (lista) {
      const ultimo = lista.elementos.at(-1)
      if (ultimo) ultimo.push({ texto: ' ', negrita: false }, ...trozosDe(linea.trim()))
      continue
    }
    parrafo ??= []
    parrafo.push(trozosDe(linea))
  }

  cerrar()
  return bloques
}
