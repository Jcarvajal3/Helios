/**
 * Pruebas de «Pendiente» de Inicio: qué tarjetas se pintan y en qué orden.
 *
 *   npx tsx src/components/admin/inicio/tarjetasDePendiente.test.ts
 *
 * Lo que se vigila: que los bloqueos vayan primero, que las colas vacías no
 * salgan y las fallidas sí, que la fila no pase de cuatro, que solo una
 * tarjeta lleve el botón en lima y que «Todo al día» no salga mientras algo
 * se está leyendo.
 */
import type { Bloqueo } from './bloqueos'
import type { Lectura, Plazo } from './colas'
import { TARJETAS_EN_LA_FILA, pendienteDeHoy } from './tarjetasDePendiente'
import type { Pendiente } from './tarjetasDePendiente'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

type ColaDePrueba = { id: string; lectura: Lectura }

function conTrabajo(id: string, cantidad: number, plazo: Plazo): ColaDePrueba {
  return { id, lectura: { estado: 'listo', resumen: { cantidad, alTope: false, detalle: null, plazo, ids: [] } } }
}
const vacia = (id: string) => conTrabajo(id, 0, 'hoy')
const fallida = (id: string): ColaDePrueba => ({ id, lectura: { estado: 'error', reintentar: () => undefined } })
const leyendo = (id: string): ColaDePrueba => ({ id, lectura: { estado: 'cargando' } })

function bloqueo(id: Bloqueo['id']): Bloqueo {
  return { id, texto: id, detalle: id, arreglo: { rotulo: 'Arreglar', destino: { to: '/admin/ajustes' } } }
}

const SIN_BLOQUEOS = { bloqueos: [], sinComprobar: [], comprobando: false }

/** Las claves de las tarjetas, o el estado si no hay tarjetas. */
function claves(p: Pendiente<ColaDePrueba>): string {
  return p.estado === 'con-trabajo' ? p.tarjetas.map((t) => t.clave).join(' ') : p.estado
}

console.log('── Sin tarjetas ─────────────────────────────────────────────')
{
  const p = pendienteDeHoy({ ...SIN_BLOQUEOS, colas: [leyendo('a'), leyendo('b')] })
  comprueba(p.estado === 'cargando', 'todo leyéndose: esqueletos, no «Todo al día»')

  const q = pendienteDeHoy({ ...SIN_BLOQUEOS, colas: [vacia('a'), vacia('b')] })
  comprueba(q.estado === 'al-dia', 'todo leído y vacío: «Todo al día»')

  const r = pendienteDeHoy({ ...SIN_BLOQUEOS, comprobando: true, colas: [vacia('a')] })
  comprueba(r.estado === 'cargando', 'con un bloqueo por comprobar todavía no se dice «al día»')

  const s = pendienteDeHoy({ ...SIN_BLOQUEOS, colas: [vacia('a'), leyendo('b')] })
  comprueba(s.estado === 'cargando', 'con una cola leyéndose, tampoco')
}

console.log('\n── El orden ─────────────────────────────────────────────────')
{
  const colas = [
    conTrabajo('hoy', 2, 'hoy'),
    conTrabajo('espera', 5, 'puede_esperar'),
    vacia('vacia'),
    conTrabajo('pasado', 1, 'pasado'),
    fallida('rota'),
  ]
  const p = pendienteDeHoy({ ...SIN_BLOQUEOS, colas }, 10)
  comprueba(
    claves(p) === 'cola-pasado cola-hoy cola-rota cola-espera',
    'lo pasado, lo de hoy, lo que no se pudo leer y lo que puede esperar; la vacía no sale',
    claves(p),
  )

  const q = pendienteDeHoy(
    {
      bloqueos: [bloqueo('cuenta'), bloqueo('extracto')],
      sinComprobar: [{ que: 'La tasa BCV', reintentar: () => undefined }],
      comprobando: false,
      colas,
    },
    10,
  )
  comprueba(
    claves(q) ===
      'bloqueo-cuenta bloqueo-extracto sin-comprobar-La tasa BCV cola-pasado cola-hoy cola-rota cola-espera',
    'los bloqueos primero y las comprobaciones fallidas antes que las colas',
    claves(q),
  )

  const r = pendienteDeHoy({ ...SIN_BLOQUEOS, colas: [leyendo('lenta'), conTrabajo('hoy', 1, 'hoy')] })
  comprueba(claves(r) === 'cola-hoy', 'una cola que todavía se lee no deja un hueco', claves(r))
}

console.log('\n── La fila ──────────────────────────────────────────────────')
{
  const colas = ['a', 'b', 'c', 'd', 'e', 'f'].map((id) => conTrabajo(id, 1, 'hoy'))
  const p = pendienteDeHoy({ ...SIN_BLOQUEOS, bloqueos: [bloqueo('tasa')], colas })
  comprueba(p.estado === 'con-trabajo' && p.tarjetas.length === TARJETAS_EN_LA_FILA, 'no pasa de las que caben en la fila')
  comprueba(p.estado === 'con-trabajo' && p.total === 7, 'pero sabe cuántas hay en total')
  comprueba(p.estado === 'con-trabajo' && p.pendientes === 7, 'bloqueos y colas con trabajo son pendientes')
}

console.log('\n── El botón en lima ─────────────────────────────────────────')
{
  const p = pendienteDeHoy({ ...SIN_BLOQUEOS, bloqueos: [bloqueo('cuenta')], colas: [conTrabajo('a', 1, 'pasado')] })
  comprueba(p.estado === 'con-trabajo' && p.principal === 'bloqueo-cuenta', 'el primer bloqueo se lleva el lima')

  const q = pendienteDeHoy({
    bloqueos: [],
    sinComprobar: [{ que: 'La tasa BCV', reintentar: () => undefined }],
    comprobando: false,
    colas: [fallida('rota'), conTrabajo('a', 3, 'hoy')],
  })
  comprueba(
    q.estado === 'con-trabajo' && q.principal === 'cola-a',
    'una tarjeta sin botón no se lo lleva: pasa a la primera con trabajo',
    q.estado === 'con-trabajo' ? String(q.principal) : q.estado,
  )

  const r = pendienteDeHoy({ ...SIN_BLOQUEOS, colas: [fallida('rota')] })
  comprueba(r.estado === 'con-trabajo' && r.principal === null, 'solo fallos: ningún botón en lima')
  comprueba(r.estado === 'con-trabajo' && r.pendientes === 0, 'y una cola sin leer no cuenta como pendiente')
}

console.log('\n── La urgencia ──────────────────────────────────────────────')
{
  const urgencia = (colas: ColaDePrueba[], bloqueos: Bloqueo[] = []) => {
    const p = pendienteDeHoy({ ...SIN_BLOQUEOS, bloqueos, colas })
    return p.estado === 'con-trabajo' ? p.urgencia : p.estado
  }
  comprueba(urgencia([conTrabajo('a', 1, 'puede_esperar')]) === 'neutral', 'lo que puede esperar no avisa')
  comprueba(urgencia([conTrabajo('a', 1, 'puede_esperar'), conTrabajo('b', 1, 'hoy')]) === 'warning', 'lo de hoy, en ámbar')
  comprueba(urgencia([conTrabajo('a', 1, 'hoy'), conTrabajo('b', 1, 'pasado')]) === 'error', 'lo pasado, en rojo')
  comprueba(urgencia([conTrabajo('a', 1, 'puede_esperar')], [bloqueo('tasa')]) === 'error', 'un bloqueo, en rojo')
}

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
