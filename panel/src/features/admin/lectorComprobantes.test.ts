/**
 * Pruebas de lo que el panel entiende del lector de comprobantes (docs/03).
 *
 *   npx tsx src/features/admin/lectorComprobantes.test.ts
 */
import { leerLectura, leerRevisionLector, motivoDeLaLectura, paraElFormulario } from './lectorComprobantes'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const fila = {
  id: 'l1',
  kind: 'captura',
  mode: 'activo',
  status: 'para_el_equipo',
  reason: 'monto_no_cuadra',
  user_id: 'u1',
  user_name: 'Lia Lectora',
  phone: '+584140009501',
  receipt_path: 'bot/u1/l1.jpg',
  method: 'pago_movil',
  bank: 'Banesco',
  reference: '1158795645',
  amount_ves: 10624.18,
  paid_on: '2026-10-21',
  payer_phone: null,
  report_id: null,
  model: 'claude-sonnet-5-5',
  error: null,
  created_at: '2026-10-21T19:07:00Z',
  decided_at: '2026-10-21T19:07:05Z',
}

console.log('Una lectura')
const l = leerLectura(fila)
comprueba(l.estado === 'para_el_equipo' && l.tipo === 'captura' && l.metodo === 'pago_movil', 'estado, tipo y método')
comprueba(l.montoVes === 10624.18 && l.rutaCaptura === 'bot/u1/l1.jpg', 'monto y captura')
comprueba(leerLectura({ ...fila, status: 'raro', method: 'zelle' }).estado === 'pendiente', 'un estado desconocido no rompe')
comprueba(leerLectura({ ...fila, method: 'zelle' }).metodo === null, 'un método que no es en bolívares → null')

console.log('El motivo')
comprueba(motivoDeLaLectura('monto_no_cuadra') === 'El monto no salda cuotas completas', 'con su texto')
comprueba(motivoDeLaLectura('algo_nuevo') === 'algo_nuevo' && motivoDeLaLectura(null) === null, 'sin texto, tal cual')

console.log('Para el formulario')
const f = paraElFormulario(l)
comprueba(f.banco === 'Banesco' && f.metodo === 'pago_movil' && f.referencia === '1158795645', 'banco, método y referencia')
comprueba(f.montoBs === '10624,18' && f.fecha === '2026-10-21', 'el monto como se escribe a mano', f.montoBs)
comprueba(paraElFormulario({ ...l, banco: 'Banco Raro' }).banco === null, 'un banco fuera de la lista no se rellena')
comprueba(paraElFormulario({ ...l, montoVes: null }).montoBs === '', 'sin monto, vacío')

console.log('La revisión')
const r = leerRevisionLector({ mode: 'sombra', daily_cap: 10, para_revisar: 2, reads: [fila] })
comprueba(r.modo === 'sombra' && r.paraRevisar === 2 && r.lecturas.length === 1, 'modo, pendientes y lecturas')
comprueba(leerRevisionLector({}).modo === 'apagado', 'sin modo, apagado')

if (fallos > 0) {
  console.log(`\n${fallos} fallo(s)`)
  process.exit(1)
}
console.log('\nTodo bien')
