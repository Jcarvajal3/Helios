/**
 * Pruebas de las tablas de estados.
 *
 *   npx tsx src/features/admin/estados.test.ts
 *
 * Lo que se comprueba no se ve mirando una pantalla: que cada lista de
 * valores cubre su tabla entera (si falta uno, el filtro no lo ofrece) y que
 * un estado desconocido sale con su nombre crudo y no en blanco.
 */
import {
  ESTADOS_CONSUMO,
  ESTADOS_LOCAL,
  ESTADOS_PAGO_REPORTADO,
  ESTADOS_PERSONA,
  ESTADOS_PROMESA,
  VALORES_ESTADO_CONSUMO,
  VALORES_ESTADO_LOCAL,
  VALORES_ESTADO_PAGO,
  VALORES_ESTADO_PERSONA,
  VALORES_ESTADO_PROMESA,
  estadoDe,
  estadoDeConsumo,
  estadoDePagoReportado,
  estadoDePersona,
  opcionesDeEstado,
} from './estados'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle: string) {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function cubre(nombre: string, valores: ReadonlyArray<string>, tabla: Record<string, unknown>) {
  const claves = Object.keys(tabla).sort()
  const lista = [...valores].sort()
  comprueba(
    JSON.stringify(claves) === JSON.stringify(lista) && new Set(valores).size === valores.length,
    `${nombre}: la lista cubre la tabla, sin repetidos`,
    `tabla ${claves.join(',')} · lista ${lista.join(',')}`,
  )
}

console.log('── Cada lista cubre su tabla ─────────────────────────────────')
cubre('consumo', VALORES_ESTADO_CONSUMO, ESTADOS_CONSUMO)
cubre('pago reportado', VALORES_ESTADO_PAGO, ESTADOS_PAGO_REPORTADO)
// Los estados de alta de Ronda (sin verificar, sin PIN) tienen nombre pero no
// se ofrecen en el filtro: un paciente de Helios nace activo.
cubre('persona', [...VALORES_ESTADO_PERSONA, 'pending_kyc', 'pending_pin'], ESTADOS_PERSONA)
cubre('local', VALORES_ESTADO_LOCAL, ESTADOS_LOCAL)
cubre('promesa', VALORES_ESTADO_PROMESA, ESTADOS_PROMESA)

console.log('\n── Los que motivaron el módulo ───────────────────────────────')
comprueba(estadoDeConsumo('reverted').label === 'Revertido', '«reverted» es «Revertido»', estadoDeConsumo('reverted').label)
comprueba(estadoDePagoReportado('reconciled').label === 'Aprobado', '«reconciled» es «Aprobado», no «Conciliado»', estadoDePagoReportado('reconciled').label)
comprueba(
  estadoDePersona('suspended').label === 'Suspendido',
  '«suspended» es «Suspendido»: «Bloqueado» es el bloqueo manual',
  estadoDePersona('suspended').label,
)
comprueba(estadoDe('local', 'terminated').tone === 'error', 'una clínica terminada va en rojo', estadoDe('local', 'terminated').tone)
comprueba(estadoDe('promesa', 'vence_hoy').label === 'Vence hoy', 'la promesa se lee con estadoDe', estadoDe('promesa', 'vence_hoy').label)
comprueba(VALORES_ESTADO_PROMESA[0] === 'vence_hoy', 'el filtro de promesas empieza por las de hoy', String(VALORES_ESTADO_PROMESA[0]))
comprueba(estadoDePersona('expelled').tone === 'error', 'expulsado va en rojo', estadoDePersona('expelled').tone)
comprueba(
  VALORES_ESTADO_CONSUMO.every((v) => ESTADOS_CONSUMO[v].que.length > 0),
  'todo estado de financiamiento tiene su definición (va al InfoDot)',
  'alguno sin «que»',
)

console.log('\n── Un estado desconocido sale crudo y en gris ────────────────')
{
  const e = estadoDe('consumo', 'refunded')
  comprueba(e.label === 'refunded' && e.tone === 'neutral', 'financiamiento desconocido', JSON.stringify(e))
  const p = estadoDe('persona', '')
  comprueba(p.label === '' && p.tone === 'neutral', 'vacío no revienta', JSON.stringify(p))
  const proto = estadoDe('pago', 'toString')
  comprueba(proto.label === 'toString', 'un nombre del prototipo no se cuela', JSON.stringify(proto))
}

console.log('\n── opcionesDeEstado ──────────────────────────────────────────')
{
  const o = opcionesDeEstado(VALORES_ESTADO_CONSUMO, ESTADOS_CONSUMO)
  comprueba(o[0]?.value === '' && o[0]?.label === 'Todos', '«Todos» delante, con valor vacío', JSON.stringify(o[0]))
  comprueba(o.length === VALORES_ESTADO_CONSUMO.length + 1, 'una opción por estado', `${o.length}`)
  comprueba(o[1]?.label === 'Confirmados', 'en plural y en el orden de la lista', JSON.stringify(o[1]))
}

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
