/**
 * Pruebas del tono de cada ruta.
 *
 *   npx tsx src/features/admin/areas.test.ts
 *
 * Lo que se vigila: que cada pantalla del menú caiga en su espacio, que una
 * ficha herede el de su lista, que Inicio no se trague las rutas de los
 * demás, y que lo que no es del super admin no tenga ámbito.
 */
import { ambitoDeRuta, tonoDeAmbito, tonoDeRuta } from './areas'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function espera(ruta: string, ambito: ReturnType<typeof ambitoDeRuta>) {
  const sale = ambitoDeRuta(ruta)
  comprueba(sale === ambito, `${ruta} → ${String(ambito)}`, String(sale))
}

console.log('── Pantallas del menú ────────────────────────────────────────')
espera('/admin', 'inicio')
espera('/admin/', 'inicio')
espera('/admin/cobranza', 'cobranza')
espera('/admin/cobros', 'cobranza')
espera('/admin/pagos-clinicas', 'caja')
espera('/admin/alertas', 'riesgo')
espera('/admin/metricas', 'metricas')
espera('/admin/pacientes', 'directorio')
espera('/admin/ajustes', 'ajustes')

console.log('── Las rutas viejas de análisis: solo redirigen ──────────────')
// Ya no son pantallas del catálogo: por un instante, antes de redirigir a
// Métricas, caen en Inicio como cualquier ruta sin pantalla.
espera('/admin/resumen', 'inicio')
espera('/admin/riesgo', 'inicio')
espera('/admin/dinero', 'inicio')

console.log('── Fichas: heredan el de su lista ────────────────────────────')
espera('/admin/pacientes/cb5272f3', 'directorio')
espera('/admin/cobros/abc', 'cobranza')
espera('/admin/pagos-clinicas/pago/xyz', 'caja')

console.log('── Bordes ────────────────────────────────────────────────────')
espera('/admin/una-ruta-sin-catalogo', 'inicio')
espera('/admin-falso', null)
espera('/registrar', null)
comprueba(tonoDeAmbito('directorio') === 'neutro', 'Directorio va en neutro')
comprueba(tonoDeAmbito('riesgo') === 'riesgo', 'Riesgo lleva su tono')
comprueba(tonoDeAmbito('metricas') === 'neutro', 'Métricas va en neutro: el tono lo pone cada pestaña')
comprueba(tonoDeRuta('/registrar') === 'neutro', 'fuera del super admin, neutro')
comprueba(tonoDeRuta('/admin/cobranza') === 'cobranza', 'Por cobrar es de Cobranza')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
