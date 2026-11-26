/**
 * Pruebas de la operación de Helios Lab.
 *
 *   npx tsx src/features/lab/operacion.test.ts
 *
 * Lo que se vigila: quién entra a qué (el driver, solo a la ruta), que las
 * respuestas de las RPC se lean aunque falte una columna, y el orden de las
 * paradas al subirlas o bajarlas.
 */
import {
  accesoDeLab,
  leerKits,
  leerLogistica,
  leerRuta,
  ordenAlMover,
  ordenarInventario,
  paradaActual,
  progresoDeRuta,
  leerInventarioDeMedicos,
  rutaPermitidaAlDriver,
} from './operacionLogica'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok || !detalle ? '' : ` — ${detalle}`}`)
}

console.log('── Quién entra ───────────────────────────────────────────────')
comprueba(accesoDeLab('super_admin') === 'completo', 'el super admin entra a todo')
comprueba(accesoDeLab('operador') === 'completo', 'el operador entra a todo')
comprueba(accesoDeLab('driver') === 'solo_ruta', 'el driver, solo a la ruta')
for (const rol of ['agenda', 'capacitador', 'cobranza', null, undefined]) {
  comprueba(accesoDeLab(rol) === 'ninguno', `${String(rol)} no entra`)
}
comprueba(rutaPermitidaAlDriver('/lab/ruta') && rutaPermitidaAlDriver('/lab/ruta/'), '/lab/ruta es del driver')
comprueba(!rutaPermitidaAlDriver('/lab') && !rutaPermitidaAlDriver('/lab/muestras') && !rutaPermitidaAlDriver('/lab/rutas'), 'lo demás, no')

console.log('── Kits e inventario ─────────────────────────────────────────')
const kits = leerKits([
  { tipo: 'sangre', nombre: 'Kit de sangre', stock_helios: 4, en_medicos: 10, minimo_helios: 10, minimo_por_medico: 2, reponer: true },
  { tipo: 'raro', stock_helios: 1 },
])
comprueba(kits.length === 1 && kits[0].reponer && kits[0].stockHelios === 4, 'lee un kit y descarta el tipo desconocido')
const inv = ordenarInventario(
  leerInventarioDeMedicos([
    { merchant_id: 'a', medico: 'Dra. Zulay', sangre: 3, bajo_minimo: false },
    { merchant_id: 'b', medico: 'Dr. Pérez', sangre: 0, bajo_minimo: true },
  ]),
)
comprueba(inv[0].merchantId === 'b', 'los de bajo el mínimo van primero')

console.log('── Logística ─────────────────────────────────────────────────')
const log = leerLogistica({
  por_retirar: [{ merchant_id: 'm1', medico: 'Dra. Ana', muestras: [{ codigo: 'LAB-1' }, { codigo: 'LAB-2' }] }],
  pedidos: [{ merchant_id: 'm2', medico: 'Dr. Luis', kit_tipo: 'orina', cantidad: 3 }],
  bajo_minimo: [{ merchant_id: 'm3', medico: 'Dr. Paz', sangre: 1 }],
})
comprueba(log.porRetirar[0].muestras === 2 && log.porRetirar[0].codigos[1] === 'LAB-2', 'cuenta las muestras de un consultorio')
comprueba(log.pedidos[0].kit === 'orina' && log.pedidos[0].cantidad === 3, 'lee un pedido')
comprueba(log.bajoMinimo[0].kits.sangre === 1 && log.bajoMinimo[0].kits.orina === null, 'lo que la base no dice queda en null')
comprueba(leerLogistica(null).porRetirar.length === 0, 'una respuesta vacía no revienta')

console.log('── La ruta ───────────────────────────────────────────────────')
const ruta = leerRuta({
  ruta: { id: 'r1', estado: 'en_curso' },
  paradas: [
    { id: 'p2', orden: 2, tipo: 'laboratorio', estado: 'pendiente', nombre: 'Lab Central', kits_a_dejar: [] },
    { id: 'p1', orden: 1, tipo: 'consultorio', estado: 'completada', nombre: 'Dra. Ana', kits_a_dejar: { sangre: 2, orina: 0 }, muestras: [{ codigo: 'LAB-1', examen: 'Hemograma', kit_tipo: 'sangre' }] },
  ],
})
comprueba(ruta.paradas[0].id === 'p1', 'las paradas salen en orden')
comprueba(ruta.paradas[0].kitsADejar.length === 1 && ruta.paradas[0].kitsADejar[0].cantidad === 2, 'kits a dejar como objeto')
comprueba(leerRuta({ paradas: [{ id: 'x', orden: 1, kits_a_dejar: [{ kit_tipo: 'biopsia', cantidad: 1 }] }] }).paradas[0].kitsADejar[0].kit === 'biopsia', 'kits a dejar como lista')
const prog = progresoDeRuta(ruta.paradas)
comprueba(prog.hechas === 1 && prog.total === 2, 'progreso «1 de 2»')
comprueba(paradaActual(ruta.paradas)?.id === 'p2', 'la actual es la primera pendiente')
comprueba(leerRuta(null).estado === null && leerRuta(null).paradas.length === 0, 'sin ruta no hay estado ni paradas')

const ps = [{ id: 'a', orden: 1 }, { id: 'b', orden: 2 }, { id: 'c', orden: 3 }]
comprueba(ordenAlMover(ps, 'b', 'arriba') === 1, 'subir b va a la posición de a')
comprueba(ordenAlMover(ps, 'b', 'abajo') === 3, 'bajar b va a la posición de c')
comprueba(ordenAlMover(ps, 'a', 'arriba') === null && ordenAlMover(ps, 'c', 'abajo') === null, 'en el borde no se mueve')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
