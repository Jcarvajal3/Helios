import { comoDia } from '@/lib/busqueda'
import { booleano, comoFila, filaONula, filas, numero, numeroONulo, texto, textoONulo } from '@/lib/json'
import { leerSemanaUsada } from '@/features/admin/metricas/lectura'
import type { Anterior, CifrasDelTramo, NocheDeLocal, RespuestaResumen, SemanaDeLaChispa } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// De la respuesta de `admin_metricas_semana_resumen` (snake_case, `unknown`)
// a los tipos de `tipos.ts`. Aquí no se calcula nada: solo se traducen
// nombres.
//
// Lo que la base manda siempre (una suma con `coalesce`, un recuento) llega
// como número; lo que puede faltar de verdad (el ticket sin consumos) llega
// como `null`. Si falta lo que da sentido a todo —la semana, sus cifras, la
// anterior—, es un fallo del contrato y se lanza: mejor «No se pudo leer»
// que una pantalla de ceros.
//
// Puro: se prueba en `lectura.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** El fee que falta, deducido de su definición y en céntimos (sin el ruido de la coma flotante). */
function feeDeducido(payableUsd: number, financedUsd: number): number {
  return Math.round((payableUsd - financedUsd) * 100) / 100
}

/** Las cifras de un tramo. `null` si no vienen. */
function tramo(v: unknown): CifrasDelTramo | null {
  const f = filaONula(v)
  if (!f) return null
  const financedUsd = numero(f.financed_usd)
  const payableUsd = numero(f.payable_usd)
  return {
    financedUsd,
    // Si la base no lo manda, se deduce: es su definición (payable − financed).
    feeUsd: numeroONulo(f.fee_usd) ?? feeDeducido(payableUsd, financedUsd),
    payableUsd,
    servicioUsd: numero(f.servicio_usd),
    ivaUsd: numero(f.iva_usd),
    consumos: numero(f.consumos),
    ticketMedioUsd: numeroONulo(f.ticket_medio_usd),
    personas: numero(f.personas),
    nuevas: numero(f.nuevas),
  }
}

function semanaDeLaChispa(f: Record<string, unknown>): SemanaDeLaChispa | null {
  const desde = comoDia(f.desde)
  const hasta = comoDia(f.hasta)
  const cifras = tramo(f)
  if (!desde || !hasta || !cifras) return null
  return {
    ...cifras,
    desde,
    hasta,
    hastaDato: comoDia(f.hasta_dato) ?? hasta,
    dias: numero(f.dias),
    enCurso: booleano(f.en_curso),
  }
}

function noche(f: Record<string, unknown>): NocheDeLocal | null {
  const dia = comoDia(f.business_date)
  const merchantId = texto(f.merchant_id)
  if (!dia || merchantId === '') return null
  const financedUsd = numero(f.financed_usd)
  const payableUsd = numero(f.payable_usd)
  return {
    dia,
    merchantId,
    nombre: texto(f.nombre, 'Clínica sin nombre'),
    consumos: numero(f.consumos),
    personas: numero(f.personas),
    nuevas: numero(f.nuevas),
    financedUsd,
    feeUsd: numeroONulo(f.fee_usd) ?? feeDeducido(payableUsd, financedUsd),
    payableUsd,
    ticketMedioUsd: numeroONulo(f.ticket_medio_usd),
  }
}

function anterior(v: unknown): Anterior | null {
  const f = filaONula(v)
  if (!f) return null
  const desde = comoDia(f.desde)
  const hasta = comoDia(f.hasta)
  if (!desde || !hasta) return null
  return {
    desde,
    hasta,
    dias: numero(f.dias),
    mismaAltura: booleano(f.misma_altura),
    corte: textoONulo(f.corte),
  }
}

/** La respuesta entera. Lanza si falta la semana, sus cifras o la anterior. */
export function leerResumen(crudo: unknown): RespuestaResumen {
  const r = comoFila(crudo)
  const semana = leerSemanaUsada(r.semana)
  const cifras = tramo(r.cifras)
  const comparacion = tramo(r.comparacion)
  const ant = anterior(r.anterior)
  if (!semana || !cifras || !comparacion || !ant) {
    throw new Error('La respuesta del resumen de la semana no trae la semana, sus cifras o la semana anterior.')
  }

  return {
    hoy: comoDia(r.hoy) ?? semana.hasta,
    local: texto(r.local) || null,
    semana,
    hasta: comoDia(r.hasta) ?? semana.hasta,
    dias: numero(r.dias),
    anterior: ant,
    cifras,
    comparacion,
    semanas: filas(r.semanas)
      .map(semanaDeLaChispa)
      .filter((s): s is SemanaDeLaChispa => s !== null),
    noches: filas(r.noches)
      .map(noche)
      .filter((n): n is NocheDeLocal => n !== null),
  }
}
