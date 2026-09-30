import { construirCsv, csvDinero, csvEntero } from '@/lib/csv'
import type { CsvColumn } from '@/lib/csv'
import { momentoDeCaracas } from './etiquetas'
import { GRUPOS_DE_FILAS, cambioDeFila } from './filas'
import type { DefinicionDeFila, Formato } from './filas'
import type { RespuestaSemanas } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// «Semana a semana» en CSV: una fila por cifra (con los sumandos de lo que
// se paga en cuotas, como en pantalla) y una columna por semana, más la
// anterior con la que se compara y el cambio.
//
// Una celda vacía es «no hay dato» o «no se parte por local», nunca un cero.
// Los importes van con coma decimal y sin miles, para que Excel en español
// los sume (`@/lib/csv`).
//
// Puro: se prueba en `csv.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

type FilaCsv = { grupo: string; fila: DefinicionDeFila }

function celda(valor: number | null, formato: Formato): string {
  if (formato === 'eur') return csvDinero(valor)
  if (formato === 'pct') return csvDinero(valor)
  return csvEntero(valor)
}

function unidad(fila: DefinicionDeFila): string {
  if (fila.formato === 'pct') return '%'
  if (fila.formato === 'eur') return fila.unidad ? `$ ${fila.unidad}` : '$'
  return fila.unidad ?? ''
}

/** El texto del CSV de la tabla, con la semana elegida la última. */
export function csvDeSemanas(respuesta: RespuestaSemanas, local: string | null): string {
  const elegida = respuesta.semanas.at(-1)
  const comparacion = respuesta.comparacion
  const partida = (fila: DefinicionDeFila) => local !== null && fila.soloSinLocal === true

  const columnas: Array<CsvColumn<FilaCsv>> = [
    { header: 'Grupo', value: (f) => f.grupo },
    { header: 'Cifra', value: (f) => (f.fila.sumando ? `  de ello, ${f.fila.nombre}` : f.fila.nombre) },
    { header: 'Unidad', value: (f) => (partida(f.fila) ? 'no se parte por clínica' : unidad(f.fila)) },
    ...respuesta.semanas.map(
      (s): CsvColumn<FilaCsv> => ({
        header: `${s.desde} a ${s.hasta}${s.enCurso ? ` (en curso, hasta ${s.hastaDato})` : ''}`,
        value: (f) => (partida(f.fila) ? '' : celda(f.fila.valor(s.cifras), f.fila.formato)),
      }),
    ),
    {
      header: comparacion.mismaAltura
        ? `Anterior a la misma altura (${comparacion.desde} a ${comparacion.hasta}${
            comparacion.corte ? `, hasta el ${momentoDeCaracas(comparacion.corte) ?? comparacion.corte}` : ''
          })`
        : `Semana anterior (${comparacion.desde} a ${comparacion.hasta})`,
      value: (f) => (partida(f.fila) ? '' : celda(f.fila.valor(comparacion.cifras), f.fila.formato)),
    },
    {
      header: 'Frente a la anterior',
      value: (f) =>
        partida(f.fila) || !elegida ? '' : (cambioDeFila(f.fila, elegida.cifras, comparacion.cifras)?.texto ?? ''),
    },
  ]

  const filas: FilaCsv[] = GRUPOS_DE_FILAS.flatMap((g) => g.filas.map((fila) => ({ grupo: g.titulo, fila })))
  return construirCsv(columnas, filas)
}

/** El nombre del archivo, sin extensión: `semanas-2026-08-03-a-2026-09-27`. */
export function nombreDelCsv(respuesta: RespuestaSemanas): string {
  const primera = respuesta.semanas.at(0)
  const ultima = respuesta.semanas.at(-1)
  return `semanas-${primera?.desde ?? ''}-a-${ultima?.hasta ?? ''}`
}
