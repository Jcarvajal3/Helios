/**
 * Pruebas de qué se le puede hacer a una cuenta desde su ficha.
 *
 *   npx tsx src/components/admin/ficha-persona/accionesDeCuenta.test.ts
 *
 * Lo que se vigila: la escalera de estados (de la expulsión no se vuelve),
 * que las destructivas del «⋯» vayan en rojo, que sin permiso todo salga
 * apagado con su motivo, y que no se ofrezca bloquear lo que ya está
 * bloqueado ni sin saber si lo está.
 */
import { itemsDeMenu } from '@/components/admin/ficha/menu'
import type { ItemDeMenu } from '@/components/ui'
import { SOLO_SUPER_ADMIN } from '@/components/ui'
import type { ProfileStatus } from '@/features/admin/users'
import { accionesDeEstado, menuDePersona } from './accionesDeCuenta'
import type { AccionDeCuenta, EstadoDelBloqueo } from './accionesDeCuenta'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

console.log('── accionesDeEstado ──────────────────────────────────────────')
{
  const activa = accionesDeEstado('active')
  comprueba(activa.reactivar === null, 'activa: no hay nada que reactivar')
  comprueba(activa.congelar && activa.suspender && activa.expulsar, 'activa: congelar, suspender y expulsar')

  const congelada = accionesDeEstado('frozen')
  comprueba(congelada.reactivar === 'Descongelar', 'congelada: se descongela')
  comprueba(!congelada.congelar && congelada.suspender, 'congelada: no se vuelve a congelar, sí se suspende')

  const suspendida = accionesDeEstado('suspended')
  comprueba(suspendida.reactivar === 'Levantar la suspensión', 'suspendida: se levanta la suspensión')
  comprueba(!suspendida.congelar && !suspendida.suspender, 'suspendida: ni congelar ni suspender otra vez')
  comprueba(suspendida.expulsar, 'suspendida: todavía se puede expulsar')

  const expulsada = accionesDeEstado('expelled')
  comprueba(
    expulsada.reactivar === null && !expulsada.congelar && !expulsada.suspender && !expulsada.expulsar,
    'expulsada: de la expulsión no se vuelve',
  )
}

console.log('── menuDePersona ─────────────────────────────────────────────')

const abiertas: Array<AccionDeCuenta> = []
let bloqueos = 0

function menu(
  status: ProfileStatus,
  opciones: { marcada?: boolean; bloqueo?: EstadoDelBloqueo; apagado?: boolean } = {},
): Array<ItemDeMenu> {
  const lista = itemsDeMenu(
    menuDePersona({
      status,
      marcada: opciones.marcada ?? false,
      bloqueo: opciones.bloqueo ?? 'sin_bloqueo',
      apagado: opciones.apagado ?? false,
      abrir: (a) => abiertas.push(a),
      bloquear: () => bloqueos++,
    }),
  )
  return lista.filter((i): i is ItemDeMenu => i !== 'separador')
}

function rotulos(items: ReadonlyArray<ItemDeMenu>): string {
  return items.map((i) => i.label).join(' | ')
}

{
  const items = menu('active')
  comprueba(
    rotulos(items) === 'Suspender la cuenta | Poner la marca interna | Bloquear la cuenta | Expulsar',
    'activa: las cuatro destructivas',
    rotulos(items),
  )
  comprueba(items.every((i) => i.peligro), 'activa: todas en rojo')

  items.find((i) => i.label === 'Expulsar')?.onSelect()
  const ultima = abiertas.at(-1)
  comprueba(
    ultima?.tipo === 'estado' && ultima.destino === 'expelled',
    'Expulsar abre el diálogo de expulsión',
  )
  items.find((i) => i.label === 'Bloquear la cuenta')?.onSelect()
  comprueba(bloqueos === 1, 'Bloquear abre el diálogo del bloqueo')
}

{
  const items = menu('expelled', { marcada: true })
  comprueba(
    rotulos(items) === 'Quitar la marca interna | Bloquear la cuenta',
    'expulsada con marca: solo quitar la marca y bloquear',
    rotulos(items),
  )
  comprueba(
    items.find((i) => i.label === 'Quitar la marca interna')?.peligro === false,
    'quitar la marca no va en rojo',
  )
}

{
  const items = menu('suspended', { bloqueo: 'abierto' })
  comprueba(!items.some((i) => i.label === 'Bloquear la cuenta'), 'bloqueada: no se ofrece bloquear otra vez')
  comprueba(!items.some((i) => i.label === 'Suspender la cuenta'), 'suspendida: no se ofrece suspender otra vez')
}

{
  const cargando = menu('active', { bloqueo: 'cargando' }).find((i) => i.label === 'Bloquear la cuenta')
  comprueba(!!cargando?.disabled && !!cargando.motivoApagado, 'sin saber si está bloqueada: apagado con motivo')
  const error = menu('active', { bloqueo: 'error' }).find((i) => i.label === 'Bloquear la cuenta')
  comprueba(!!error?.disabled && !!error.motivoApagado, 'si no se pudo leer el bloqueo: apagado con motivo')
}

{
  const items = menu('active', { apagado: true })
  comprueba(
    items.length === 4 && items.every((i) => i.disabled && i.motivoApagado === SOLO_SUPER_ADMIN),
    'sin permiso: todo se ve, apagado y con el motivo',
  )
}

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
