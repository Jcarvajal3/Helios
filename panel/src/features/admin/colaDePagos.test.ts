/**
 * Pruebas de la lista de Pagos reportados.
 *
 *   npx tsx src/features/admin/colaDePagos.test.ts
 *
 * La búsqueda es lo delicado: cada lado escribe el teléfono y la cédula a su
 * manera, y un pago que no aparece al buscarlo se lee como un pago que no
 * existe.
 */
import type { QueueItem, StatementMatch } from './api'
import {
  bancosParaElFiltro,
  clasificarCotejo,
  enElExtracto,
  coincideBusqueda,
  colaDe,
  extractoViejo,
  filtrarPagos,
  leerFiltrosPagos,
} from './colaDePagos'
import type { FiltrosPagos } from './colaDePagos'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function pago(parcial: Partial<QueueItem>): QueueItem {
  return {
    reportId: 'r1',
    status: 'reported',
    createdAt: '2026-09-20T15:00:00+00:00',
    method: 'pago_movil',
    bank: 'Banco de Venezuela',
    reference: '004512',
    payerDocument: 'V30496254',
    payerPhone: '584141112233',
    note: null,
    reviewedAt: null,
    reviewedByName: null,
    amountUsd: 12,
    amountVes: 11_700,
    fxRate: 975,
    installmentCount: 1,
    installmentsUsd: 12,
    lateFeeUsd: 0,
    userId: 'u1',
    fullName: 'María José Pérez',
    phone: '584241875770',
    userDocument: '26484675',
    userStatus: 'active',
    userLevel: 1,
    referenceCollisions: 0,
    statementMatches: 0,
    statementMatchesAvailable: 0,
    statementLine: null,
    purchases: [],
    lateFees: [],
    ...parcial,
  }
}

function movimiento(id: string, parcial: Partial<StatementMatch> = {}): StatementMatch {
  return {
    id,
    bank: 'BNC',
    movedOn: '2026-09-20',
    reference: '99004512',
    amountVes: 11_700,
    description: null,
    differenceVes: 0,
    disponible: true,
    ligado: false,
    descartado: false,
    usadoPor: null,
    ...parcial,
  }
}

console.log('── La URL ───────────────────────────────────────────────────')
{
  const f = leerFiltrosPagos({ tab: 'aprobados', q: '  0424 ', banco: 'BNC', desde: '2026-02-30', hasta: '2026-09-01' })
  comprueba(f.tab === 'aprobados', 'lee el estado')
  comprueba(f.q === '0424', 'recorta la búsqueda', String(f.q))
  comprueba(f.desde === undefined, 'un día imposible no pasa', String(f.desde))
  comprueba(f.hasta === '2026-09-01', 'un día bueno sí')
  comprueba(leerFiltrosPagos({ tab: 'sin-dueno' }).tab === undefined, 'una pestaña vieja no es un estado')
  comprueba(colaDe(undefined) === 'pendientes' && colaDe('rechazados') === 'rechazados', 'sin estado, los pendientes')
}

console.log('\n── La búsqueda ──────────────────────────────────────────────')
{
  const p = pago({})
  comprueba(coincideBusqueda(p, 'perez'), 'el nombre sin tilde')
  comprueba(coincideBusqueda(p, 'MARÍA'), 'el nombre en mayúsculas')
  comprueba(coincideBusqueda(p, '0424-1875770'), 'el teléfono como se dicta')
  comprueba(coincideBusqueda(p, '26.484.675'), 'la cédula con puntos')
  comprueba(coincideBusqueda(p, 'V-30496254'), 'la cédula del pagador')
  comprueba(coincideBusqueda(p, '0414 1112233'), 'el teléfono del pagador')
  comprueba(coincideBusqueda(p, '4512'), 'el final de la referencia')
  comprueba(!coincideBusqueda(p, '999'), 'tres cifras no buscan por cifra')
  comprueba(!coincideBusqueda(p, 'gonzalez'), 'otro nombre no')
  comprueba(coincideBusqueda(p, '   '), 'una búsqueda vacía no filtra')
}

console.log('\n── Filtrar y ordenar ────────────────────────────────────────')
{
  const viejo = pago({ reportId: 'viejo', createdAt: '2026-09-01T12:00:00+00:00' })
  const noche = pago({ reportId: 'noche', createdAt: '2026-09-11T03:30:00+00:00', bank: 'Mercantil' })
  const nuevo = pago({ reportId: 'nuevo', createdAt: '2026-09-20T12:00:00+00:00' })
  const todos = [nuevo, viejo, noche]

  const pendientes = filtrarPagos(todos, {}, 'pendientes').map((p) => p.reportId)
  comprueba(pendientes.join() === 'viejo,noche,nuevo', 'pendientes: del más viejo al más nuevo', pendientes.join())

  const aprobados = filtrarPagos(todos, {}, 'aprobados').map((p) => p.reportId)
  comprueba(aprobados.join() === 'nuevo,noche,viejo', 'resueltos: lo último arriba', aprobados.join())

  // Las fechas las aplica la base (`p_from`, `p_to`); aquí ya no se miran.
  const filtrosConFechas: FiltrosPagos = { desde: '2026-09-10', hasta: '2026-09-10' }
  const conFechas = filtrarPagos(todos, filtrosConFechas, 'aprobados')
  comprueba(conFechas.length === 3, 'el paciente no vuelve a filtrar por fecha')

  const mercantil = filtrarPagos(todos, { banco: 'Mercantil' }, 'pendientes')
  comprueba(mercantil.length === 1, 'el banco filtra')

  const bancos = bancosParaElFiltro(['Banco de Venezuela'], [pago({ bank: 'Banco Raro' }), pago({ bank: null })])
  comprueba(bancos.join() === 'Banco de Venezuela,Banco Raro', 'se ofrece el banco que no está en la lista', bancos.join())
}

console.log('\n── El extracto ──────────────────────────────────────────────')
{
  comprueba(extractoViejo(null), 'nunca importado es viejo')
  comprueba(extractoViejo(3) && !extractoViejo(2), 'a los tres días avisa, a los dos no')

  comprueba(clasificarCotejo(1, [movimiento('a')], []).tipo === 'encontrado', 'uno que encaja: encontrado')
  const varios = clasificarCotejo(2, [movimiento('a'), movimiento('b')], [])
  comprueba(varios.tipo === 'varios' && varios.movimientos.length === 2, 'varios: trae los candidatos')
  const distinto = clasificarCotejo(0, [], [movimiento('c')])
  comprueba(distinto.tipo === 'monto_distinto' && distinto.movimientos[0]?.id === 'c', 'la referencia por otra cifra')
  comprueba(clasificarCotejo(0, [], []).tipo === 'no_encontrado', 'nada: no encontrado')

  // Un movimiento que ya respalda otro pago no respalda este.
  const usado = movimiento('u', {
    disponible: false,
    usadoPor: { reportId: 'r9', userId: 'u9', fullName: 'Ana Pérez' },
  })
  const unoLibre = clasificarCotejo(2, [usado, movimiento('a')], [])
  comprueba(
    unoLibre.tipo === 'encontrado' && unoLibre.libre.id === 'a' && unoLibre.movimientos.length === 2,
    'dos que encajan y uno ya usado: encontrado, con el libre',
  )
  comprueba(clasificarCotejo(1, [usado], []).tipo === 'ya_usado', 'el único que encaja ya respalda otro pago')
  const dosLibres = clasificarCotejo(3, [usado, movimiento('a'), movimiento('b')], [])
  comprueba(dosLibres.tipo === 'varios', 'dos libres: hay que elegir')
  comprueba(clasificarCotejo(1, [], []).tipo === 'no_encontrado', 'la cola cuenta uno pero la lista llega vacía: no se inventa')

  const lista = (total: number, libres: number) =>
    enElExtracto({ statementMatches: total, statementMatchesAvailable: libres, statementLine: null })
  comprueba(
    [lista(1, 1), lista(3, 2), lista(1, 0), lista(0, 0)].join(' | ') === 'Encontrado | 2 coinciden | Ya usado | No aparece',
    'la lista cuenta solo los libres',
    [lista(1, 1), lista(3, 2), lista(1, 0), lista(0, 0)].join(' | '),
  )
  const ligado = enElExtracto({
    statementMatches: 0,
    statementMatchesAvailable: 0,
    statementLine: { ...movimiento('l'), reference: '1119488724' },
  })
  comprueba(ligado === 'Encontrado', 'ligado a mano con otra referencia: encontrado', ligado)
}

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
