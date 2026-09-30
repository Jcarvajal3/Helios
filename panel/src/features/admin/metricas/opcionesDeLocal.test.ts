/**
 * Pruebas de los locales que ofrece el selector de Métricas.
 *
 *   npx tsx src/features/admin/metricas/opcionesDeLocal.test.ts
 */
import { nombreDelLocal, opcionesDeLocal } from './opcionesDeLocal'
import type { LocalElegible } from './opcionesDeLocal'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const L = (id: string, name: string, status: LocalElegible['status'] = 'active', isTest = false): LocalElegible => ({
  id,
  name,
  status,
  isTest,
})

const locales = [
  L('q', 'La Quinta Bar'),
  L('p', 'Clínica de pruebas', 'active', true),
  L('m', 'El Marchante'),
  L('v', 'Viejo Bar', 'terminated'),
  L('a', 'Ávila Club', 'paused'),
]

const { activos, otros } = opcionesDeLocal(locales)
igual(activos.map((l) => l.id), ['m', 'q'], 'los activos, por nombre')
igual(otros.map((l) => l.id), ['a', 'v'], 'después los pausados y terminados, por nombre (la tilde no descoloca)')
igual([...activos, ...otros].some((l) => l.isTest), false, 'los de prueba no salen')

igual(nombreDelLocal(locales, 'q'), 'La Quinta Bar', 'el nombre del elegido')
igual(nombreDelLocal(locales, null), null, 'sin clínica, sin nombre')
igual(nombreDelLocal(locales, 'x'), null, 'una clínica que no está en la lista, sin nombre')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
