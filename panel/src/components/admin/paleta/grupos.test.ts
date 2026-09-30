/**
 * Pruebas de los grupos de la paleta: qué sale, en qué estado y qué dice.
 *
 *   npx tsx src/components/admin/paleta/grupos.test.ts
 *
 * Lo que no puede pasar: que un fallo se lea como «no hay nada», que una
 * acción del super admin se pueda usar sin serlo, o que un consumo enseñe un
 * monto con el service fee dentro.
 */
import { SOLO_SUPER_ADMIN } from '@/components/ui'
import type { MerchantRow } from '@/features/admin/api'
import type { ChargeRow } from '@/features/admin/ops'
import type { UserRow } from '@/features/admin/users'
import { interpretar } from './consulta'
import type { PagoEncontrado } from './fuentes'
import { anuncioDe, construirGrupos, noHayNada, resumir } from './grupos'
import type { DatosDePaleta, Fuente, Grupo } from './grupos'
import { opcionDeConsumo, opcionDeEntrada, opcionDePersona } from './opciones'
import { CATALOGO } from '@/features/admin/catalogo'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const UUID = '0b6f6c1e-3d7a-4f3e-9d2a-1c2b3a4d5e6f'

function persona(cambios: Partial<UserRow> = {}): UserRow {
  return {
    userId: UUID,
    fullName: 'Ana Rivas',
    phone: '584141234567',
    document: 'V12345678',
    status: 'active',
    level: 1,
    levelLimitUsd: 100,
    isBlacklisted: false,
    isTest: false,
    createdAt: '2026-09-01T00:00:00Z',
    openDebtUsd: 24.64,
    overdueUsd: 0,
    daysOverdue: 0,
    chargeCount: 1,
    lastChargeAt: null,
    availableUsd: 80,
    availableNowUsd: 80,
    sinDisponible: null,
    lastMerchantName: null,
    onTimePaid: 0,
    onTimeTotal: 0,
    ...cambios,
  }
}

function consumo(cambios: Partial<ChargeRow> = {}): ChargeRow {
  return {
    chargeId: UUID,
    orderNumber: 1043,
    amountUsd: 12.32,
    financedUsd: 10,
    status: 'confirmed',
    businessDate: '2026-09-20',
    createdAt: '2026-09-21T02:00:00Z',
    confirmedAt: '2026-09-21T02:01:00Z',
    voidReason: null,
    userId: UUID,
    fullName: 'Ana Rivas',
    phone: '584141234567',
    userStatus: 'active',
    merchantId: UUID,
    merchantName: 'La Quinta Bar',
    branchName: 'Principal',
    isTest: false,
    installmentsPaid: 0,
    installmentsTotal: 2,
    ...cambios,
  }
}

const listo = <T,>(filas: T[]): Fuente<T> => ({ estado: 'listo', filas })
const cargando: Fuente<never> = { estado: 'cargando', filas: [] }
const fallo: Fuente<never> = { estado: 'error', filas: [] }

function datos(texto: string, cambios: Partial<DatosDePaleta> = {}): DatosDePaleta {
  return {
    consulta: interpretar(texto),
    esSuperAdmin: true,
    recientes: [],
    personas: listo<UserRow>([]),
    locales: listo<MerchantRow>([]),
    consumos: listo<ChargeRow>([]),
    pagos: listo<PagoEncontrado>([]),
    ...cambios,
  }
}

const ids = (grupos: Grupo[]) => grupos.map((g) => `${g.id}:${g.estado}:${g.opciones.length}`)

console.log('── Estados de un grupo ───────────────────────────────────────')
{
  const g = construirGrupos(datos('0414-1234567', { personas: fallo }))
  igual(ids(g), ['personas:error:1'], 'un fallo es un grupo en error con una sola línea')
  igual(g[0]?.opciones[0]?.titulo, 'No se pudo buscar en pacientes', 'y la línea dice qué falló')
  igual(g[0]?.opciones[0]?.efecto.tipo, 'reintentar', 'y elegirla reintenta')
  const r = resumir(g)
  igual(noHayNada(interpretar('0414-1234567'), r), false, 'con un fallo NO se dice «Nada con…»')
  igual(anuncioDe(interpretar('0414-1234567'), r), '0 resultados. No se pudo buscar en pacientes.', 'el lector de pantalla oye el fallo')
}
{
  const g = construirGrupos(datos('0414-1234567', { personas: cargando }))
  igual(ids(g), ['personas:cargando:0'], 'esperando: el grupo sale, sin filas')
  igual(noHayNada(interpretar('0414-1234567'), resumir(g)), false, 'esperando tampoco es «Nada con…»')
}
{
  const c = interpretar('0414-1234567')
  const g = construirGrupos(datos('0414-1234567'))
  igual(ids(g), [], 'listo y vacío: el grupo no sale')
  igual(noHayNada(c, resumir(g)), true, 'y entonces sí es «Nada con…»')
  igual(anuncioDe(c, resumir(g)), 'Nada con «0414-1234567».', 'y así se anuncia')
}
{
  const g = construirGrupos(datos('pagos reportados', { pagos: fallo }))
  igual(g.some((x) => x.id === 'pagos'), false, 'una fuente que no toca a esta forma no pinta su fallo')
}

console.log('\n── Pacientes ──────────────────────────────────────────────────')
{
  const g = construirGrupos(
    datos('V-12345678', {
      personas: listo([
        persona({ userId: 'a', document: 'V912345678' }),
        persona({ userId: 'b', document: 'V12345678' }),
      ]),
    }),
  )
  igual(g[0]?.opciones.map((o) => o.clave), ['personas:b', 'personas:a'], 'ordenadas por parecido, la exacta primero')
}
{
  const o = opcionDePersona(persona({ overdueUsd: 12.32 }))
  igual(o.detalle, '0414-1234567 · V-12.345.678 · Deuda vencida $12,32', 'teléfono, cédula y lo vencido, rotulado como deuda')
  igual(
    o.efecto.tipo === 'abrir' ? o.efecto.reciente : null,
    { tipo: 'persona', id: UUID, titulo: 'Ana Rivas', detalle: '0414-1234567 · V-12.345.678' },
    'en Recientes se guarda sin la deuda, que cambia cada día',
  )
  igual(opcionDePersona(persona({ isTest: true })).insignias.map((i) => i.texto), ['Activo', 'Prueba'], 'una cuenta de prueba lo dice')
}

console.log('\n── Financiamientos ──────────────────────────────────────────────────')
{
  const o = opcionDeConsumo(consumo())
  igual(o.titulo, 'Orden #1043', 'se nombra por su número de orden')
  igual(o.detalle?.includes('$10,00'), true, 'con el financiamiento sin el fee')
  igual(o.detalle?.includes('$12,32'), false, 'y nunca con amount_usd, que lleva el fee dentro')
  const g = construirGrupos(
    datos('1043', { consumos: listo([consumo({ chargeId: 'x', orderNumber: 10430 }), consumo()]) }),
  )
  igual(g[0]?.opciones.map((op) => op.clave), [`consumos:${UUID}`], 'solo el de ese número')
}

console.log('\n── Acciones y permisos ───────────────────────────────────────')
{
  const soloSuper = CATALOGO.find((e) => e.tipo === 'accion' && e.soloSuperAdmin === true)
  if (soloSuper) {
    const operador = opcionDeEntrada(soloSuper, 'acciones', false)
    igual(operador.efecto, { tipo: 'apagada', motivo: SOLO_SUPER_ADMIN }, 'al operador le sale apagada, con el motivo escrito')
    igual(opcionDeEntrada(soloSuper, 'acciones', true).efecto.tipo, 'abrir', 'al super admin le abre su pantalla')
  } else {
    igual(true, false, 'el catálogo tiene alguna acción solo para el super admin')
  }
  const termino = CATALOGO.find((e) => e.tipo === 'termino')
  if (termino) {
    igual(opcionDeEntrada(termino, 'terminos', true).efecto.tipo, 'desplegar', 'un término se despliega, no navega')
  }
  const cifra = CATALOGO.find((e) => e.tipo === 'cifra')
  if (cifra?.tipo === 'cifra') {
    const o = opcionDeEntrada(cifra, 'cifras', true)
    igual(o.nota, cifra.que, 'una cifra enseña su «que»')
    igual(o.efecto.tipo, 'abrir', 'y abre la pantalla donde vive')
  }
}

console.log('\n── Sin texto ─────────────────────────────────────────────────')
{
  const g = construirGrupos(datos('', { recientes: [{ tipo: 'catalogo', id: 'no-existe' }] }))
  igual(g.map((x) => x.id), ['atajos'], 'un reciente que ya no existe se cae; los atajos salen')
  const conReciente = construirGrupos(
    datos('', {
      recientes: [
        { tipo: 'catalogo', id: 'cartera-vencida' },
        { tipo: 'persona', id: UUID, titulo: 'Ana Rivas', detalle: '' },
      ],
    }),
  )
  igual(conReciente.map((x) => x.id), ['recientes', 'atajos'], 'Recientes primero, luego los atajos')
  igual(
    conReciente[1]?.opciones.some((o) => o.clave === 'atajos:cartera-vencida'),
    false,
    'lo que ya está en Recientes no se repite en los atajos',
  )
  igual(noHayNada(interpretar(''), resumir(g)), false, 'sin texto nunca es «Nada con…»')
}

console.log('\n── Claves únicas ─────────────────────────────────────────────')
{
  const g = construirGrupos(datos('pago'))
  const claves = g.flatMap((x) => x.opciones.map((o) => o.clave))
  igual(new Set(claves).size, claves.length, 'ninguna clave se repite en la lista')
}

console.log('\n── Preguntarle al asistente ──────────────────────────────────')
{
  const g = construirGrupos(datos('cartera', { preguntar: true }))
  igual(g.at(-1)?.id, 'asistente', 'con texto, la opción del asistente va al final')
  igual(g.at(-1)?.opciones[0]?.efecto, { tipo: 'preguntar', texto: 'cartera' }, 'y lleva lo tecleado')
  const q = construirGrupos(datos('¿cuánto se recuperó esta semana?', { preguntar: true }))
  igual(q[0]?.id, 'asistente', 'si parece una pregunta, va la primera')
  igual(construirGrupos(datos('', { preguntar: true })).some((x) => x.id === 'asistente'), false, 'sin texto no se ofrece')
  igual(construirGrupos(datos('cartera')).some((x) => x.id === 'asistente'), false, 'sin asistente no se ofrece')
  const nada = construirGrupos(datos('zzzzqqq', { preguntar: true }))
  igual(ids(nada), ['asistente:listo:1'], 'sin resultados, queda solo la opción del asistente')
  igual(noHayNada(interpretar('zzzzqqq'), resumir(nada)), true, 'y se sigue diciendo «Nada con…»')
}

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
