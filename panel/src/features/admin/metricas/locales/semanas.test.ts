/**
 * Pruebas de cómo se nombran las semanas en la pestaña Locales.
 *
 *   npx tsx src/features/admin/metricas/locales/semanas.test.ts
 *
 * Lo que se vigila: el mes se escribe una vez si no cambia, los dos si cambia
 * y el año solo si cambia; y que la aritmética no se corra un día por la zona
 * horaria (el lunes 21 de septiembre sigue siendo lunes).
 */
import { diaConNumero, diaCorto, semanaCorta, semanaEnFrase } from './semanas'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const ok = dio === esperado
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${String(dio)}, se esperaba ${String(esperado)}`}`)
}

igual(semanaCorta('2026-08-03'), '3–9 ago', 'una semana dentro de un mes')
igual(semanaCorta('2026-08-31'), '31 ago–6 sep', 'una semana que cambia de mes')
igual(semanaCorta('2025-12-29'), '29 dic 2025–4 ene 2026', 'una semana que cambia de año')
igual(semanaEnFrase('2026-09-14'), 'del 14 al 20 sep', 'dentro de una frase')
igual(semanaEnFrase('2026-08-31'), 'del 31 ago al 6 sep', 'dentro de una frase, cambiando de mes')
igual(diaConNumero('2026-09-28'), 'lunes 28', 'el día del cierre')
igual(diaConNumero('2026-09-21'), 'lunes 21', 'un lunes no se corre al domingo')
igual(diaCorto('2026-08-28'), '28 ago', 'un día suelto')

if (fallos > 0) {
  console.error(`\n${fallos} prueba(s) fallaron`)
  process.exit(1)
}
console.log('\nTodo bien.')
