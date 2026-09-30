/**
 * Pruebas de cómo se nombran las semanas y los vencimientos.
 *
 *   npx tsx src/features/admin/metricas/cohortes/semanas.test.ts
 *
 * Lo que se vigila: la semana que cruza de mes o de año, que el domingo salga
 * bien sin husos horarios de por medio, y los días de la curva en palabras.
 */
import { domingoDeLaSemana, nombreDeCohorte, rangoDeVencimiento, rotuloDeDia, rotuloDeSemana, semanaLarga } from './semanas'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

console.log('── Semanas ────────────────────────────────────────────────────')
igual(domingoDeLaSemana('2026-09-21'), '2026-09-27', 'el domingo de la semana')
igual(domingoDeLaSemana('2026-12-28'), '2027-01-03', 'el domingo cruza de año')
igual(rotuloDeSemana('2026-09-21'), '21–27 sep', 'en el mismo mes')
igual(rotuloDeSemana('2026-08-31'), '31 ago–6 sep', 'cruzando de mes')
igual(semanaLarga('2026-09-21'), 'del 21 al 27 de septiembre', 'larga, en el mismo mes')
igual(semanaLarga('2026-08-31'), 'del 31 de agosto al 6 de septiembre', 'larga, cruzando de mes')
igual(semanaLarga('2026-12-28'), 'del 28 de diciembre de 2026 al 3 de enero de 2027', 'larga, cruzando de año')

console.log('\n── Vencimientos ───────────────────────────────────────────────')
igual(rangoDeVencimiento('2026-09-28', '2026-10-04'), 'del 28 sep al 4 oct', 'de un mes a otro')
igual(rangoDeVencimiento('2026-09-21', '2026-09-27'), 'del 21 al 27 sep', 'en el mismo mes')
igual(rangoDeVencimiento('2026-09-26', '2026-09-26'), 'el 26 sep', 'un solo día')

console.log('\n── Los días de la curva ───────────────────────────────────────')
igual(rotuloDeDia(-6), '6 días antes', 'antes de vencer')
igual(rotuloDeDia(-1), '1 día antes', 'en singular')
igual(rotuloDeDia(0), 'vence', 'el día que vence')
igual(rotuloDeDia(1), '+1 día', 'un día después')
igual(rotuloDeDia(14), '+14 días', 'dos semanas después')

igual(nombreDeCohorte('2026-07-20', '2026-07-20'), 'A1', 'la primera semana es A1')
igual(nombreDeCohorte('2026-09-14', '2026-07-20'), 'A9', 'ocho semanas después, A9')
igual(nombreDeCohorte('2027-01-04', '2026-12-28'), 'A2', 'cruzando de año')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallos.`)
if (fallos > 0) process.exit(1)
