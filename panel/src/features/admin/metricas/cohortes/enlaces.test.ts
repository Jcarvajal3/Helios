/**
 * Pruebas de adónde llevan los enlaces de Cohortes.
 *
 *   npx tsx src/features/admin/metricas/cohortes/enlaces.test.ts
 *
 * Lo que se vigila: que elegir una semana lleve a su detalle (Cobros ›
 * Resumen) con el mismo local y que la semana en curso no se escriba.
 */
import { busquedaDeLaSemana } from './enlaces'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

/** Sin las claves vacías, como queda en la URL. */
function limpia(o: object): Record<string, unknown> {
  return Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined))
}

const HOY = '2026-09-26'
const LOCAL = '11111111-1111-4111-8111-111111111111'

console.log('── Elegir una semana ──────────────────────────────────────────')
igual(
  limpia(busquedaDeLaSemana('2026-09-14', HOY, null, {})),
  { vista: 'cobros', semana: '2026-09-14' },
  'otra semana: se escribe su lunes; Resumen, la primera, no se escribe',
)
igual(
  limpia(busquedaDeLaSemana('2026-09-21', HOY, null, {})),
  { vista: 'cobros' },
  'la semana en curso no se escribe',
)
igual(
  limpia(busquedaDeLaSemana('2026-09-14', HOY, LOCAL, { cuota: '2' })),
  { cuota: '2', vista: 'cobros', semana: '2026-09-14', local: LOCAL },
  'con el misma clínica y las claves de la pestaña',
)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallos.`)
if (fallos > 0) process.exit(1)
