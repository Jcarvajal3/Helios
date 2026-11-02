/**
 * Pruebas de la foto de la cédula en la ficha del paciente (docs/00 §15.11).
 *
 *   npx tsx src/features/admin/pacientes/cedula.test.ts
 *
 * Lo que se vigila: que sin ninguna foto no se invente una, que una revisión
 * desconocida no rompa la ficha y que cada revisión diga lo suyo.
 */
import { insigniaDeLaRevision, leerFotoDeCedula } from './cedula'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const nunca = leerFotoDeCedula({ has_photo: false, needs_photo: true })
comprueba(!nunca.tieneFoto && nunca.ultima === null, 'sin ninguna foto, nada que enseñar')

const leida = leerFotoDeCedula({
  has_photo: true,
  photo_id: 'f1',
  received_at: '2026-11-02T15:00:00Z',
  stored: true,
  mime: 'image/jpeg',
  status: 'no_coincide',
  reason: 'numero',
  read_number: 'V-9.999.999',
  read_name: 'JOSE PEREZ',
  order_number: 41,
})
comprueba(
  leida.tieneFoto && leida.ultima?.guardada === true && leida.ultima.revision === 'no_coincide' &&
    leida.ultima.motivo === 'numero' && leida.ultima.orden === 41 && leida.ultima.numeroLeido === 'V-9.999.999',
  'una foto leída, con lo que se leyó',
  JSON.stringify(leida),
)

const rara = leerFotoDeCedula({ has_photo: false, photo_id: 'f2', status: 'otra_cosa' })
comprueba(rara.ultima?.revision === 'pendiente' && rara.ultima.guardada === false, 'una revisión desconocida no rompe')

comprueba(insigniaDeLaRevision('coincide', null).tono === 'success', 'coincide, en verde')
comprueba(insigniaDeLaRevision('no_coincide', 'nombre').texto === 'El nombre no coincide', 'el nombre')
comprueba(
  insigniaDeLaRevision('no_coincide', 'numero_y_nombre').texto === 'El número y el nombre no coinciden',
  'los dos, en plural',
)
comprueba(insigniaDeLaRevision('no_es_cedula', null).tono === 'error', 'lo que no es una cédula, en rojo')
comprueba(insigniaDeLaRevision('leyendo', null).texto === 'Revisando…', 'mientras se lee')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
