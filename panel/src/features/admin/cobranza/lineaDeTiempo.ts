import { diaOperativo, sumarDias } from '@/components/ui'
import type { CollectionContact } from '@/features/admin/contacts'
import type { LateFee } from '@/features/admin/lateFees'
import type { UserDetail } from '@/features/admin/users'

// ═══════════════════════════════════════════════════════════════════════════
// El caso de cobranza de una persona, en orden: lo último arriba.
//
// Junta cinco cosas que vivían en cinco pestañas: las gestiones (con su
// resultado y su promesa), los pagos que reportó, las cuotas que se le
// vencieron, las que pagó y los cargos por atraso. Módulo puro: recibe lo ya
// leído y devuelve la lista ordenada.
// ═══════════════════════════════════════════════════════════════════════════

type Cuota = UserDetail['installments'][number]
type Pago = UserDetail['payments'][number]

export type Suceso =
  | { tipo: 'gestion'; id: string; cuando: string; gestion: CollectionContact }
  | { tipo: 'pago'; id: string; cuando: string; pago: Pago }
  | { tipo: 'vencio'; id: string; cuando: string; cuota: Cuota }
  | {
      tipo: 'pagada'
      id: string
      cuando: string
      cuota: Cuota
      /**
       * Cobrada con atraso según la regla canónica (`metricas.a_tiempo`: el
       * día del REPORTE pasó del vencimiento más los días de gracia). Falso
       * también si la base no manda el veredicto: sin él, no se pinta la marca.
       */
      conAtraso: boolean
    }
  | { tipo: 'cargo'; id: string; cuando: string; cargo: LateFee }

/**
 * El instante en que empieza un día operativo: la medianoche de Caracas.
 *
 * Venezuela está en UTC−4 todo el año, sin horario de verano, así que el
 * desfase se puede escribir.
 */
export function inicioDelDiaOperativo(dia: string): string {
  return new Date(`${dia.slice(0, 10)}T00:00:00-04:00`).toISOString()
}

/**
 * El día en que se pagó, a efectos de si llegó tarde: el día operativo del
 * REPORTE (`paidDay`, el de `metricas.cuotas.pagada_dia`). Lo que tarde el
 * equipo en aprobarlo no la hace llegar tarde. Si la base no lo manda, el de
 * la aprobación.
 */
function diaDelPago(c: Cuota): string | null {
  if (c.paidDay) return c.paidDay
  return c.paidAt ? diaOperativo(new Date(c.paidAt)) : null
}

/**
 * Si una cuota llegó a estar vencida: pasó su día sin que se reportara su
 * pago. Una cuota reportada dentro de su día operativo no se venció nunca.
 */
function seVencio(c: Cuota, hoy: string): boolean {
  if (c.dueDate >= hoy) return false
  const pagada = diaDelPago(c)
  if (!pagada) return true
  return pagada > c.dueDate
}

/** Para ordenar dos sucesos del mismo instante: primero lo que pasó antes. */
const ORDEN: Record<Suceso['tipo'], number> = {
  vencio: 0,
  cargo: 1,
  gestion: 2,
  pago: 3,
  pagada: 4,
}

export function lineaDeTiempo(entrada: {
  gestiones: ReadonlyArray<CollectionContact>
  pagos: ReadonlyArray<Pago>
  cuotas: ReadonlyArray<Cuota>
  cargos: ReadonlyArray<LateFee>
  /** Día operativo de hoy. */
  hoy: string
}): Suceso[] {
  const sucesos: Suceso[] = []

  for (const g of entrada.gestiones) {
    sucesos.push({ tipo: 'gestion', id: `gestion:${g.id}`, cuando: g.contactedAt, gestion: g })
  }

  for (const p of entrada.pagos) {
    sucesos.push({ tipo: 'pago', id: `pago:${p.id}`, cuando: p.createdAt, pago: p })
  }

  for (const c of entrada.cuotas) {
    // Se vence al empezar el día operativo siguiente a su vencimiento: una
    // cuota que vence el 11 aún se paga a tiempo la madrugada del 12.
    if (seVencio(c, entrada.hoy)) {
      sucesos.push({
        tipo: 'vencio',
        id: `vencio:${c.id}`,
        cuando: inicioDelDiaOperativo(sumarDias(c.dueDate, 1)),
        cuota: c,
      })
    }
    if (c.paidAt) {
      sucesos.push({
        tipo: 'pagada',
        id: `pagada:${c.id}`,
        cuando: c.paidAt,
        cuota: c,
        // El veredicto del servidor, con los días de gracia: una cuota
        // reportada el día +2 se venció, pero se cobró a tiempo.
        conAtraso: c.onTime === false,
      })
    }
  }

  // El estado automático pone el cargo al cambiar de día operativo.
  for (const f of entrada.cargos) {
    sucesos.push({
      tipo: 'cargo',
      id: `cargo:${f.id}`,
      cuando: inicioDelDiaOperativo(f.businessDate),
      cargo: f,
    })
  }

  return sucesos.sort((a, b) => {
    const t = Date.parse(b.cuando) - Date.parse(a.cuando)
    return t !== 0 ? t : ORDEN[b.tipo] - ORDEN[a.tipo]
  })
}
