/**
 * Pruebas de las reglas del buscador que vive en la URL.
 *
 *   npx tsx src/components/FiltrosDeLista.test.ts
 *
 * Lo que se vigila: que la URL no guarde espacios ni un `?q=` vacío, y que el
 * campo no se coma el espacio que se acaba de escribir cuando la URL vuelve
 * con el texto recortado.
 */
import { campoSigueALaUrl, rangoDelFiltro, rotuloSinRango, textoParaUrl } from './FiltrosDeLista'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

console.log('── Lo que se escribe en la URL ───────────────────────────────')
comprueba(textoParaUrl('  maría  ') === 'maría', 'se recorta', String(textoParaUrl('  maría  ')))
comprueba(textoParaUrl('') === undefined, 'vacío es «sin búsqueda»')
comprueba(textoParaUrl('   ') === undefined, 'solo espacios también')

console.log('\n── Cuándo manda la URL ───────────────────────────────────────')
comprueba(!campoSigueALaUrl('maría', 'maría '), 'la URL recortada no borra el espacio que se está escribiendo')
comprueba(campoSigueALaUrl(undefined, 'maría'), '«Quitar los filtros» vacía el campo')
comprueba(campoSigueALaUrl('josé', 'maría'), 'atrás o un enlace ponen su texto')
comprueba(!campoSigueALaUrl(undefined, ''), 'sin búsqueda y campo vacío: nada que hacer')

console.log('\n── El rango del filtro de fechas ─────────────────────────────')
const HOY = '2026-09-25'
const igual = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b)
{
  const dos = rangoDelFiltro('2026-09-01', '2026-09-10', HOY)
  comprueba(igual(dos, { from: '2026-09-01', to: '2026-09-10' }), 'con las dos fechas, esas', JSON.stringify(dos))
  const desde = rangoDelFiltro('2026-09-01', undefined, HOY)
  comprueba(igual(desde, { from: '2026-09-01', to: HOY }), 'solo «desde»: hasta hoy (enlaces viejos)', JSON.stringify(desde))
  const futuro = rangoDelFiltro('2026-10-01', undefined, HOY)
  comprueba(igual(futuro, { from: '2026-10-01', to: '2026-10-01' }), 'un «desde» futuro no da un rango al revés', JSON.stringify(futuro))
  comprueba(rangoDelFiltro(undefined, '2026-09-10', HOY) === null, 'solo «hasta»: no se inventa el principio')
  comprueba(rangoDelFiltro(undefined, undefined, HOY) === null, 'sin fechas no hay rango')
  comprueba(rotuloSinRango(undefined) === 'Cualquier fecha', 'sin fechas dice «Cualquier fecha»', rotuloSinRango(undefined))
  comprueba(rotuloSinRango('2026-09-10') === 'Hasta el 10 sep', 'solo «hasta» lo dice', rotuloSinRango('2026-09-10'))
}

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
