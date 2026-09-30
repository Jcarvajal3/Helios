/**
 * Pruebas de lo común de la Retención.
 *
 *   npx tsx src/components/admin/crecimiento/cohortes.test.ts
 *
 * Lo que se vigila: que la cohorte que abre sea la de la semana elegida (su
 * mes si se agrupa por mes), y que las palabras cambien con el local: sin él
 * la gente «se registró», con él «llegó al local».
 */
import { TEXTOS_DE_BASE, cohorteDeLaSemana, columnasDesde, periodosValidos } from './cohortes'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

igual(cohorteDeLaSemana('week', '2026-09-14'), '2026-09-14', 'por semana, el lunes elegido')
igual(cohorteDeLaSemana('month', '2026-09-14'), '2026-09-01', 'por mes, el día 1 de su mes')
igual(cohorteDeLaSemana('day', '2026-09-14'), '2026-09-14', 'por día, el lunes')
igual(columnasDesde('week', 'registro'), 'Semanas desde que se registraron', 'columnas sin clínica')
igual(columnasDesde('day', 'primera_visita'), 'Días desde que llegaron a la clínica', 'columnas con clínica')
igual(TEXTOS_DE_BASE.primera_visita.entraron, 'Llegaron a la clínica', 'el rótulo con clínica')
igual(periodosValidos('week', 12), 12, 'doce semanas valen')
igual(periodosValidos('week', 30), 8, 'treinta semanas no: la primera opción')

if (fallos > 0) {
  console.error(`\n${fallos} ${fallos === 1 ? 'prueba falló' : 'pruebas fallaron'}`)
  process.exit(1)
}
console.log('\nTodo bien.')
