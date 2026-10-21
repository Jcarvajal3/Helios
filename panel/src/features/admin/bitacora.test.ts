/**
 * Pruebas de la traducción de la bitácora y de a qué apunta cada línea.
 *
 *   npx tsx src/features/admin/bitacora.test.ts
 *
 * Sin framework, como `csv.test.ts`: es un módulo puro.
 *
 * Lo que se vigila aquí es una clase de fallo que ya pasó y que no avisa. El
 * filtro de pagos mandaba `payment.reconcile` y la base guarda
 * `payment.reconciled`. Cero filas, y la pantalla decía «Nada con estos
 * filtros» encima de once pagos aprobados. Un código mal escrito no rompe
 * nada: enseña una tabla vacía, que parece una respuesta.
 */
import {
  ACCION_VERBO,
  FILTROS_BITACORA,
  TEMAS_BITACORA,
  accionesDelTema,
  describirEvento,
  destinoDe,
  rotuloDeDestino,
} from './bitacora'
import type { AuditEntry } from './ops'

let fallos = 0

function check(ok: boolean, label: string, detalle: string) {
  if (!ok) fallos++
  console.log(`${ok ? 'OK  ' : 'FALLA'} ${label.padEnd(44)} ${detalle}`)
}

const PERSONA = '839bba23-640e-4f57-9280-c814013233bc'
const OTRO = '0bea770c-1111-4222-8333-944455556666'

function entrada(
  action: string,
  detail: Record<string, unknown>,
  targetId: string | null = null,
): AuditEntry {
  return {
    id: 1,
    actor: '00000000-0000-0000-0000-000000000000',
    actorName: 'Javier',
    action,
    targetId,
    detail,
    createdAt: '2026-09-18T23:45:09.096Z',
  }
}

function datosDe(l: ReturnType<typeof describirEvento>): string {
  return l.datos.map((d) => `${d.label} ${d.valor}`).join(' · ')
}

// ── Un pago aprobado, con el `detail` tal y como lo guarda la base ─────────
// Copiado de una fila real: `admin_reconcile_payment` guarda el motivo y mete
// lo que devolvió la función dentro de `result`.
const aprobado = describirEvento(
  entrada(
    'payment.reconciled',
    {
      note: 'prueba de segundo pago',
      result: {
        ok: true,
        status: 'reconciled',
        amount_usd: 13.86,
        installments: 5,
        late_fee_usd: 0,
        late_fee_count: 0,
      },
    },
    OTRO,
  ),
)

check(aprobado.frase === 'Javier aprobó un pago reportado', 'pago aprobado: la frase', aprobado.frase)

const etiquetas = aprobado.datos.map((d) => d.label)
check(
  etiquetas.includes('monto') && etiquetas.includes('cuotas saldadas'),
  'pago aprobado: los datos',
  datosDe(aprobado),
)
check(
  !etiquetas.includes('ok') && !etiquetas.includes('estado'),
  'pago aprobado: sin ruido',
  `ni «ok» ni el estado, que es el verbo otra vez: ${etiquetas.join(', ')}`,
)
check(
  !etiquetas.includes('cargo por atraso cobrado'),
  'pago aprobado: cargo por atraso en cero',
  'un pago sin cargo no dice «0,00 $»',
)
check(aprobado.motivo === 'prueba de segundo pago', 'pago aprobado: el motivo aparte', String(aprobado.motivo))
check(
  aprobado.destino?.que === 'pago' && 'id' in aprobado.destino && aprobado.destino.id === OTRO,
  'pago aprobado: enlaza al pago',
  JSON.stringify(aprobado.destino),
)

// ── Un pago rechazado ──────────────────────────────────────────────────────
const rechazado = describirEvento(
  entrada('payment.rejected', {
    note: 'La referencia no existe en el extracto.',
    result: { ok: true, status: 'rejected' },
  }),
)
check(rechazado.frase === 'Javier rechazó un pago reportado', 'pago rechazado: la frase', rechazado.frase)
check(rechazado.datos.length === 0, 'pago rechazado: sin datos sueltos', `${rechazado.datos.length}`)
check(rechazado.destino === null, 'pago rechazado sin target: sin enlace', JSON.stringify(rechazado.destino))

// ── Una gestión de cobranza, con su resultado (20260925100000) ─────────────
const gestion = describirEvento(
  entrada(
    'collection.contact',
    {
      full_name: 'JAVIER CARVAJAL',
      channel: 'llamada',
      template: null,
      promise_date: '2026-09-26',
      outcome: 'promesa',
      next_action_on: null,
      note: 'Dice que paga el viernes',
    },
    PERSONA,
  ),
)
check(
  gestion.frase === 'Javier anotó una gestión de cobranza',
  'gestión: la frase',
  gestion.frase,
)
check(
  gestion.datos.some((d) => d.label === 'resultado' && d.valor === 'Prometió pagar'),
  'gestión: el resultado con nombre',
  datosDe(gestion),
)
check(
  gestion.datos.some((d) => d.label === 'canal' && d.valor === 'Llamada') &&
    gestion.datos.some((d) => d.label === 'fecha prometida' && d.valor === '26/09/26'),
  'gestión: canal y fecha prometida',
  datosDe(gestion),
)
check(
  gestion.destino?.que === 'persona' && rotuloDeDestino(gestion.destino) === 'JAVIER CARVAJAL',
  'gestión: el nombre enlaza al paciente',
  JSON.stringify(gestion.destino),
)
check(
  !gestion.datos.some((d) => d.valor === 'JAVIER CARVAJAL'),
  'gestión: el nombre no se repite en los datos',
  datosDe(gestion),
)

// ── Una alerta de riesgo revisada (20260925113000) ─────────────────────────
const alerta = describirEvento(
  entrada(
    'risk_alert.reviewed',
    { alert_key: `noche:${PERSONA}:2026-09-24`, kind: 'noche', note: 'Cumpleaños, grupo grande' },
    PERSONA,
  ),
)
check(alerta.frase === 'Javier revisó una alerta de riesgo', 'alerta: la frase', alerta.frase)
check(
  alerta.datos.some((d) => d.label === 'tipo' && d.valor === 'Varios financiamientos en un día') &&
    !alerta.datos.some((d) => d.valor.includes('noche:')),
  'alerta: el tipo con nombre y sin la clave',
  datosDe(alerta),
)
check(alerta.destino?.que === 'persona', 'alerta: enlaza al paciente', JSON.stringify(alerta.destino))

// ── Un parámetro, con el rótulo y la unidad del catálogo ───────────────────
const parametro = describirEvento(
  entrada('parameter.set', {
    key: 'late_fee_usd',
    from_value: 2,
    to_value: 2.5,
    effective_from: '2026-10-01',
    note: 'Acuerdo',
  }),
  { parametros: [{ key: 'late_fee_usd', label: 'Cargo por atraso', unit: '$' }] },
)
check(
  parametro.datos.some((d) => d.label === 'parámetro' && d.valor === 'Cargo por atraso'),
  'parámetro: con su rótulo',
  datosDe(parametro),
)
check(
  parametro.cambio?.antes === '$2,00' && parametro.cambio.despues === '$2,50',
  'parámetro: antes y después con su unidad',
  JSON.stringify(parametro.cambio),
)
check(
  parametro.destino?.que === 'ajustes' && parametro.destino.tab === 'parametros',
  'parámetro: enlaza a Ajustes › Parámetros',
  JSON.stringify(parametro.destino),
)

// ── Antes y después como valores sueltos y como objetos ────────────────────
const estado = describirEvento(
  entrada('user.set_status', { before: 'active', after: 'frozen', note: 'x' }, PERSONA),
)
check(
  estado.cambio?.antes === 'Activo' && estado.cambio.despues === 'Congelado',
  'estado de cuenta: antes y después con nombre',
  JSON.stringify(estado.cambio),
)

const mantenimiento = describirEvento(
  entrada('maintenance.on', {
    before: { is_active: false, blocks_balance: true },
    after: { is_active: true, blocks_balance: true },
  }),
)
check(
  mantenimiento.cambio?.antes === 'no' && mantenimiento.cambio.despues === 'sí' &&
    mantenimiento.cambio.campo === 'encendido' &&
    !mantenimiento.datos.some((d) => d.label === 'saldo apagado'),
  'mantenimiento: solo lo que cambió, con su nombre',
  `${JSON.stringify(mantenimiento.cambio)} · ${datosDe(mantenimiento)}`,
)
check(
  estado.cambio?.campo === null,
  'estado de cuenta: el valor de la acción no se nombra',
  JSON.stringify(estado.cambio),
)

const tasa = describirEvento(
  entrada('fx_rate.manual', { rate: 960.5, previous: 954.0244, effective_date: '2026-09-25', note: 'n' }),
)
check(
  tasa.cambio?.antes === '954,0244' && tasa.cambio.despues === '960,5',
  'tasa a mano: la anterior y la nueva',
  JSON.stringify(tasa.cambio),
)

// ── Un consumo revertido se lee sin el fee ─────────────────────────────────
const revertido = describirEvento(
  entrada(
    'charge.reverted',
    { user_id: PERSONA, full_name: 'Ana', amount_usd: 12, financed_usd: 10, payable_usd: 12 },
    OTRO,
  ),
)
check(
  revertido.datos.some((d) => d.label === 'financiamiento (sin comisión)' && d.valor === '$10,00') &&
    !revertido.datos.some((d) => d.valor === '$12,00'),
  'financiamiento revertido: financed, nunca con la comisión',
  datosDe(revertido),
)
check(
  revertido.destino?.que === 'consumo' && revertido.datos.some((d) => d.valor === 'Ana'),
  'financiamiento revertido: enlaza al financiamiento y nombra al paciente',
  `${JSON.stringify(revertido.destino)} · ${datosDe(revertido)}`,
)

// ── destinoDe: lo que va en el detalle y los casos sin enlace ──────────────
const condonado = destinoDe(entrada('late_fee.waived', { user_id: PERSONA, full_name: 'Ana' }, OTRO))
check(
  condonado?.que === 'persona' && 'id' in condonado && condonado.id === PERSONA,
  'cargo condonado: el paciente sale del detalle',
  JSON.stringify(condonado),
)

const eliminada = destinoDe(entrada('account_deletion.completed', { user_id: PERSONA }, OTRO))
check(
  eliminada?.que === 'persona' && 'id' in eliminada && eliminada.id === PERSONA,
  'eliminación: el paciente sale del detalle',
  JSON.stringify(eliminada),
)

const transferencia = destinoDe(entrada('merchant.payout', { payout_id: PERSONA }, OTRO))
check(
  transferencia?.que === 'transferencia',
  'transferencia: se prefiere la del detalle',
  JSON.stringify(transferencia),
)
const pagosLocal = destinoDe(entrada('merchant.paid', {}, OTRO))
check(pagosLocal?.que === 'pagos-del-local', 'pago viejo a clínica: los pagos de la clínica', JSON.stringify(pagosLocal))

const pruebaLocal = destinoDe(entrada('account.set_test', { kind: 'merchant', name: 'Kabal' }, OTRO))
check(
  pruebaLocal?.que === 'local' && rotuloDeDestino(pruebaLocal) === 'Kabal',
  'marca de prueba de una clínica: enlaza a la clínica',
  JSON.stringify(pruebaLocal),
)

check(
  destinoDe(entrada('user.set_status', {}, 'no-es-un-uuid')) === null,
  'un target que no es uuid no se sigue',
  'null',
)
check(destinoDe(entrada('cosa.nueva', {}, OTRO)) === null, 'un código desconocido: sin enlace', 'null')

// ── Los temas y los códigos, uno contra otro ───────────────────────────────
const enTemas = new Set(FILTROS_BITACORA.flatMap((f) => f.acciones ?? []))

const sinVerbo = [...enTemas].filter((a) => ACCION_VERBO[a] === undefined)
check(
  sinVerbo.length === 0,
  'todo código de un tema se lee',
  sinVerbo.length === 0 ? `${enTemas.size} códigos` : `en crudo: ${sinVerbo.join(', ')}`,
)

const sinTema = Object.keys(ACCION_VERBO).filter((a) => !enTemas.has(a))
check(
  sinTema.length === 0,
  'todo código se alcanza por tema',
  sinTema.length === 0 ? `${Object.keys(ACCION_VERBO).length} códigos` : `sueltos: ${sinTema.join(', ')}`,
)

check(
  ['risk_alert.reviewed', 'collection.contact'].every((a) => enTemas.has(a)),
  'las acciones nuevas tienen tema',
  'risk_alert.reviewed, collection.contact',
)

// Vocabulario del super admin: «local», nunca «comercio»; «aprobar», nunca
// «conciliar»; «extracto», no «estado de cuenta».
const prohibidas = Object.values(ACCION_VERBO).filter((v) =>
  /comercio|concili|estado de cuenta|motor/i.test(v ?? ''),
)
check(prohibidas.length === 0, 'los verbos usan el vocabulario del panel', prohibidas.join(' | '))

const rotulos = FILTROS_BITACORA.map((f) => f.label)
check(new Set(rotulos).size === rotulos.length, 'ningún tema repite rótulo', rotulos.join(' · '))

const valores = FILTROS_BITACORA.map((f) => f.value)
check(new Set(valores).size === valores.length, 'ningún tema repite valor', valores.join(' · '))
check(!TEMAS_BITACORA.includes(''), '«Todo» no se escribe en la URL', TEMAS_BITACORA.join(', '))

// ── El tema, resuelto ──────────────────────────────────────────────────────
check(accionesDelTema('') === null, 'el tema «Todo» no filtra', 'null')
check(accionesDelTema(undefined) === null, 'sin tema no filtra', 'null')
check(accionesDelTema('no-existe') === null, 'un tema desconocido no filtra', 'null')
check(
  (accionesDelTema('pagos-reportados') ?? []).includes('payment.reconciled'),
  'el tema de pagos lleva el aprobado',
  (accionesDelTema('pagos-reportados') ?? []).join(', '),
)

// ── Un código que no conocemos no desaparece ───────────────────────────────
const desconocido = describirEvento(entrada('cosa.nueva', {}))
check(desconocido.frase === 'Javier cosa nueva', 'un código nuevo se lee en crudo', desconocido.frase)

const sinActor = describirEvento({ ...entrada('fx_rate.sync', {}), actor: null, actorName: null })
check(sinActor.frase.startsWith('El sistema'), 'sin actor: lo hizo el sistema', sinActor.frase)

console.log(fallos === 0 ? '\n=== TODO OK ===' : `\n=== ${fallos} FALLAN ===`)
process.exit(fallos === 0 ? 0 : 1)
