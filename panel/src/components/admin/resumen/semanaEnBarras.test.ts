/**
 * Pruebas de las barras de la semana del Resumen.
 *
 *   npx tsx src/components/admin/resumen/semanaEnBarras.test.ts
 *
 * Lo que se vigila: siete barras de lunes a domingo, los días que no han
 * llegado como futuro, hoy destacado, y ninguna barra si la serie no cubre la
 * semana (antes que siete barras con huecos que parecerían noches a cero).
 */
import { diasDeLaSemana } from './semanaEnBarras'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

/** Catorce días que acaban el jueves 24 de septiembre de 2026. */
const serie = Array.from({ length: 14 }, (_, i) => {
  const d = new Date(Date.UTC(2026, 8, 11 + i))
  return { businessDate: d.toISOString().slice(0, 10), financedUsd: i === 12 ? 20 : 0 }
})

console.log('── La semana en curso ────────────────────────────────────────')
{
  const p = diasDeLaSemana('2026-09-21', '2026-09-24', serie)
  comprueba(p?.length === 7, 'siete barras, de lunes a domingo', JSON.stringify(p))
  comprueba(p?.[0].rotulo === 'L' && p[6].rotulo === 'D', 'con la inicial del día')
  comprueba(p?.[2].valor === 20, 'el miércoles lleva lo suyo', JSON.stringify(p?.[2]))
  comprueba(p?.[0].valor === 0, 'un día sin financiamiento es un cero, no un hueco')
  comprueba(p?.[3].destacado === true && p[2].destacado === false, 'hoy va destacado')
  comprueba(p?.[4].valor === null && p[6].valor === null, 'lo que no ha llegado es futuro')
}

console.log('── Una semana que la serie no cubre ──────────────────────────')
comprueba(diasDeLaSemana('2026-09-07', '2026-09-24', serie) === null, 'sin barras si falta un día pasado')
comprueba(diasDeLaSemana('2026-09-14', '2026-09-24', serie)?.length === 7, 'la semana anterior sí se cubre')
comprueba(diasDeLaSemana('2026-09-21', '2026-09-24', undefined) === null, 'sin serie, sin barras')

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} ${fallos === 1 ? 'fallo' : 'fallos'}.`)
if (fallos > 0) process.exit(1)
