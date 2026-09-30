/**
 * Pruebas de la búsqueda de locales y del uso del cupo.
 *
 *   npx tsx src/features/admin/directorio/locales.test.ts
 */
import { usoDelCupo } from './cupo'
import { casaConLaBusqueda, filtrarLocales, normalizarTexto } from './locales'
import type { EstadoLocal } from '@/features/admin/estados'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const kabal = {
  name: 'Kábal Club',
  legalName: 'Inversiones Nocturnas C.A.',
  taxId: 'J-12345678-9',
  status: 'active' as EstadoLocal,
}
const cerrado = { name: 'La Quinta', legalName: null, taxId: null, status: 'paused' as EstadoLocal }

console.log('── Búsqueda ─────────────────────────────────────────────────')
comprueba(normalizarTexto('  Kábal ') === 'kabal', 'sin tildes ni mayúsculas')
comprueba(casaConLaBusqueda(kabal, 'kabal'), 'el nombre sin tilde encuentra el que la lleva')
comprueba(casaConLaBusqueda(kabal, 'nocturnas'), 'por razón social')
comprueba(casaConLaBusqueda(kabal, 'j123456789'), 'el RIF sin guiones')
comprueba(casaConLaBusqueda(kabal, 'J-1234'), 'el RIF con guiones')
comprueba(!casaConLaBusqueda(kabal, 'quinta'), 'otro nombre no casa')
comprueba(!casaConLaBusqueda(cerrado, '123'), 'sin RIF no casa por número')
comprueba(casaConLaBusqueda(cerrado, '   '), 'una búsqueda vacía casa con todo')
comprueba(!casaConLaBusqueda(cerrado, '---'), 'solo guiones no casa con una clínica sin RIF')

console.log('\n── Filtro ───────────────────────────────────────────────────')
comprueba(filtrarLocales([kabal, cerrado], {}).length === 2, 'sin filtros, todos')
comprueba(
  filtrarLocales([kabal, cerrado], { estado: 'paused' }).map((l) => l.name).join() === 'La Quinta',
  'por estado',
)
comprueba(
  filtrarLocales([kabal, cerrado], { estado: 'paused', texto: 'kabal' }).length === 0,
  'estado y texto a la vez',
)

console.log('\n── Uso del cupo ─────────────────────────────────────────────')
comprueba(usoDelCupo(0, 0) === null, 'sin cupo no hay proporción')
comprueba(usoDelCupo(50, 50)?.proporcion === 0, 'nada ocupado')
comprueba(usoDelCupo(50, 20)?.ocupadoUsd === 30, '30 ocupados de 50')
comprueba(usoDelCupo(50, 0)?.proporcion === 1, 'todo ocupado')
comprueba(usoDelCupo(50, 80)?.proporcion === 0, 'un disponible mayor que el cupo no da negativo')
comprueba(usoDelCupo(50, -5)?.proporcion === 1, 'un disponible negativo no pasa del 100 %')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} ${fallos === 1 ? 'fallo' : 'fallos'}.`)
if (fallos > 0) process.exit(1)
