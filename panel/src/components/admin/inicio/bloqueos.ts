import { formatWaitingHours } from '@/components/ui'
import { esCuentaDeRelleno } from '@/features/admin/ajustesReglas'
import type { Destino } from '@/features/admin/catalogo/tipos'
import { extractoViejo } from '@/features/admin/colaDePagos'
import type { FxStatus } from '@/features/admin/fx'
import type { PaymentDestination } from '@/features/admin/ops'

// ═══════════════════════════════════════════════════════════════════════════
// «Bloquea la operación»: lo que, si está mal, impide que la gente pague o
// que el equipo pueda aprobar lo que paga.
//
// Módulo puro. Cada regla recibe lo que leyó su consulta y devuelve el
// bloqueo, o `null` si no hay nada que arreglar. Cada bloqueo lleva el sitio
// donde se arregla: si algo sale en rojo, hay un botón que lo apaga.
// ═══════════════════════════════════════════════════════════════════════════

export type IdBloqueo = 'tasa' | 'tasa-eur' | 'cuenta' | 'extracto'

export type Bloqueo = {
  id: IdBloqueo
  /** Qué pasa, en una frase. */
  texto: string
  /** Por qué bloquea, en una frase. */
  detalle: string
  arreglo: { rotulo: string; destino: Destino }
}

const A_LA_TASA: Destino = { to: '/admin/ajustes', search: { tab: 'tasa' } }

/**
 * Sin tasa no se cotiza; con una de más de 48 h se cotiza mal. Vale para las
 * dos tasas: la del dólar cotiza todo, y la del euro, las órdenes en euros
 * (el paciente paga cada cuota a la tasa BCV del euro del día).
 */
export function bloqueoDeTasa(
  fx: Pick<FxStatus, 'rate' | 'isStale' | 'ageHours'>,
  moneda: 'USD' | 'EUR' = 'USD',
): Bloqueo | null {
  const id: IdBloqueo = moneda === 'USD' ? 'tasa' : 'tasa-eur'
  const cual = moneda === 'USD' ? 'La tasa BCV' : 'La tasa BCV del euro'
  if (fx.rate === null) {
    return {
      id,
      texto: moneda === 'USD' ? 'No hay ninguna tasa BCV cargada.' : 'No hay ninguna tasa BCV del euro cargada.',
      detalle:
        moneda === 'USD'
          ? 'Sin tasa no se puede cotizar un pago, y nadie puede pagar.'
          : 'Sin ella no se puede cotizar el pago de una orden en euros.',
      arreglo: { rotulo: 'Cargar la tasa', destino: A_LA_TASA },
    }
  }
  if (!fx.isStale) return null
  return {
    id,
    texto:
      fx.ageHours === null
        ? `${cual} lleva más de dos días sin actualizarse.`
        : `${cual} no se actualiza desde hace ${formatWaitingHours(fx.ageHours)}.`,
    detalle:
      moneda === 'USD'
        ? 'La búsqueda automática dejó de traerla y los pagos se cotizan a una tasa vieja.'
        : 'La búsqueda automática dejó de traerla y los pagos de las órdenes en euros se cotizan a una tasa vieja.',
    arreglo: { rotulo: 'Revisar la tasa', destino: A_LA_TASA },
  }
}

/**
 * Las cuentas a las que transfieren los pacientes: que haya al menos una
 * activa que no sea la de relleno (en Helios puede haber varias activas).
 */
export function bloqueoDeCuenta(
  cuentas: ReadonlyArray<Pick<PaymentDestination, 'isActive' | 'rif'>>,
): Bloqueo | null {
  const activas = cuentas.filter((c) => c.isActive)
  if (activas.some((c) => !esCuentaDeRelleno(c.rif))) return null
  return {
    id: 'cuenta',
    texto:
      activas.length > 0
        ? 'La única cuenta de cobro activa es la de relleno.'
        : 'No hay ninguna cuenta de cobro activa.',
    detalle: 'Los pacientes no tienen una cuenta válida a la que transferir.',
    arreglo: { rotulo: 'Configurar la cuenta', destino: { to: '/admin/ajustes', search: { tab: 'cobro' } } },
  }
}

/** El extracto del banco: sin él al día no se coteja ningún pago. */
export function bloqueoDeExtracto(diasDesdeElUltimo: number | null): Bloqueo | null {
  if (!extractoViejo(diasDesdeElUltimo)) return null
  return {
    id: 'extracto',
    texto:
      diasDesdeElUltimo === null
        ? 'Nunca se ha importado el extracto del banco.'
        : `Hace ${diasDesdeElUltimo} días que no se importa el extracto del banco.`,
    detalle: 'Sin el extracto no se puede cotejar ningún pago, y los abonos sin dueño no aparecen.',
    arreglo: { rotulo: 'Importar el extracto', destino: { to: '/admin/cobros', search: { importar: true } } },
  }
}

