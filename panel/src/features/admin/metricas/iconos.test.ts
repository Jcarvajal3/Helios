/**
 * Pruebas de los iconos de Métricas.
 *
 *   npx tsx src/features/admin/metricas/iconos.test.ts
 *
 * Lo que se vigila: que toda pestaña y sub-pestaña tenga icono, y que dentro
 * de una misma banda no se repita (dos píldoras con el mismo dibujo no se
 * distinguen de un vistazo).
 */
import { iconoDeMetricas } from './iconos'
import { IDS_PESTANA, idsDeSubpestanas } from './pestanas'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

console.log('── Toda pestaña y sub-pestaña tiene icono ────────────────────')
igual(
  IDS_PESTANA.filter((id) => iconoDeMetricas(id) === undefined),
  [],
  'las pestañas',
)
igual(
  IDS_PESTANA.flatMap((id) => idsDeSubpestanas(id).filter((s) => iconoDeMetricas(id, s) === undefined).map((s) => `${id}/${s}`)),
  [],
  'las sub-pestañas',
)

console.log('\n── Sin repetir dentro de una banda ───────────────────────────')
igual(
  new Set(IDS_PESTANA.map((id) => iconoDeMetricas(id))).size,
  IDS_PESTANA.length,
  'las ocho pestañas, cada una con el suyo',
)
igual(
  IDS_PESTANA.filter((id) => {
    const iconos = idsDeSubpestanas(id).map((s) => iconoDeMetricas(id, s))
    return new Set(iconos).size !== iconos.length
  }),
  [],
  'las sub-pestañas de cada pestaña, cada una con el suyo',
)
igual(iconoDeMetricas('locales', 'no-existe'), undefined, 'un sitio que no existe no tiene icono')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
