/**
 * Pruebas del origen de las fichas: a dónde lleva «volver».
 *
 *   npx tsx src/features/navegacion/origenDeFicha.test.ts
 */
import { fichaDe, origenAlEntrar, pasosHaciaAtras } from './origenDeFicha'
import type { Origen, Paso } from './origenDeFicha'

let fallos = 0
function comprueba(ok: boolean, que: string, detalle = '') {
  if (ok) console.log(`  ok    ${que}`)
  else {
    fallos++
    console.log(` FALLA  ${que} — ${detalle}`)
  }
}

const paso = (href: string, indice: number | null = null): Paso => ({
  pathname: href.split('?')[0] ?? href,
  href,
  indice,
})
const ninguna = () => false
const todas = () => true

console.log('── Qué es una ficha ──────────────────────────────────────────')
comprueba(fichaDe('/admin/pacientes/abc')?.clase === 'pacientes', 'un paciente')
comprueba(fichaDe('/admin/pagos-clinicas/pago/xyz')?.clase === 'pagos-clinicas/pago', 'una transferencia')
comprueba(fichaDe('/admin/pagos-clinicas/m1')?.clase === 'pagos-clinicas', 'los pagos de una clínica')
comprueba(fichaDe('/admin/pacientes') === null, 'una lista no es una ficha')
comprueba(fichaDe('/admin/cobranza') === null, 'Por cobrar no es una ficha')

console.log('── Al entrar en una ficha ────────────────────────────────────')
{
  const o = origenAlEntrar(
    paso('/admin/cobranza?vista=morosos', 5),
    paso('/admin/pacientes/u1', 6),
    {},
    'Por cobrar › Morosos',
    ninguna,
  )
  comprueba(
    o?.href === '/admin/cobranza?vista=morosos' && o.titulo === 'Por cobrar › Morosos' && o.indice === 5,
    'desde Morosos, el origen es Morosos con sus filtros y su sitio en el historial',
    JSON.stringify(o),
  )
}
comprueba(
  origenAlEntrar(paso('/admin/pacientes/u1?tab=pagos'), paso('/admin/pacientes/u1?tab=cobranza'), {}, 'x', ninguna) ===
    undefined,
  'cambiar de pestaña dentro de la ficha no toca el origen',
)
comprueba(
  origenAlEntrar(paso('/admin/cobranza'), paso('/admin/pacientes'), {}, 'x', ninguna) === undefined,
  'ir a una lista no apunta nada',
)
comprueba(
  origenAlEntrar(undefined, paso('/admin/pacientes/u1'), {}, 'x', ninguna) === undefined,
  'al cargar la página directamente no hay de dónde se viene',
)

console.log('── De ficha a ficha ──────────────────────────────────────────')
{
  const morosos: Origen = { href: '/admin/cobranza?vista=morosos', titulo: 'Por cobrar › Morosos', indice: 5 }
  const origenes = { '/admin/pacientes/u1': morosos }

  const siguiente = origenAlEntrar(paso('/admin/pacientes/u1', 6), paso('/admin/pacientes/u2', 7), origenes, 'Ana', todas)
  comprueba(siguiente === morosos, 'el siguiente caso de la cola hereda Morosos', JSON.stringify(siguiente))

  const relacionada = origenAlEntrar(
    paso('/admin/pacientes/u1', 6),
    paso('/admin/pacientes/u9', 7),
    origenes,
    'Ana › Identidad',
    ninguna,
  )
  comprueba(
    relacionada?.href === '/admin/pacientes/u1' && relacionada.titulo === 'Ana › Identidad',
    'una cuenta relacionada, fuera de la cola, vuelve al paciente de la que se vino',
    JSON.stringify(relacionada),
  )

  const consumo = origenAlEntrar(paso('/admin/pacientes/u1?tab=financiamientos', 6), paso('/admin/financiamientos/c1', 7), origenes, 'Ana › Financiamientos', ninguna)
  comprueba(consumo?.href === '/admin/pacientes/u1?tab=financiamientos', 'un financiamiento abierto desde un paciente vuelve a ese paciente')

  const deVuelta = origenAlEntrar(
    paso('/admin/financiamientos/c1', 7),
    paso('/admin/pacientes/u1?tab=financiamientos', 8),
    { ...origenes, '/admin/financiamientos/c1': { href: '/admin/pacientes/u1?tab=financiamientos', titulo: 'Ana', indice: 6 } },
    'Financiamiento #1209',
    ninguna,
  )
  comprueba(deVuelta === undefined, 'al volver del financiamiento al paciente, el paciente sigue volviendo a Morosos')
}

console.log('── Volver ────────────────────────────────────────────────────')
{
  const o: Origen = { href: '/admin/cobranza?vista=morosos', titulo: 'x', indice: 5 }
  comprueba(pasosHaciaAtras(o, 6) === 1, 'justo detrás: un paso atrás')
  comprueba(pasosHaciaAtras(o, 8) === 3, 'tras cambiar de pestaña en la ficha: los pasos que hagan falta')
  comprueba(pasosHaciaAtras(o, 5) === null, 'si ya no está detrás, se navega a su dirección')
  comprueba(pasosHaciaAtras({ ...o, indice: null }, 8) === null, 'sin índice, se navega a su dirección')
}

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
if (fallos > 0) process.exit(1)
