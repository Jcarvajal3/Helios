import { Link } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { Link2, Upload } from 'lucide-react'

import {
  Button,
  Callout,
  Seccion,
  SkeletonBlock,
  Table,
  Td,
  Tr,
  formatDay,
  formatVes,
} from '@/components/ui'
import { fetchStatementMatches } from '@/features/admin/api'
import type { MovimientoDelExtracto, QueueItem, StatementMatch } from '@/features/admin/api'
import { clasificarCotejo } from '@/features/admin/colaDePagos'
import type { ResultadoCotejo } from '@/features/admin/colaDePagos'

/**
 * Cuánto se ensancha el monto para encontrar la referencia que está en el
 * banco por otra cifra. Cualquier monto: lo que se busca es la referencia.
 */
const CUALQUIER_MONTO_VES = 1_000_000_000

export type Cotejo = ResultadoCotejo | { tipo: 'cargando' } | { tipo: 'error'; reintentar: () => void }

/**
 * Qué dice el extracto de este pago.
 *
 * Con coincidencias se piden los movimientos que encajan, para enseñarlos y
 * no solo contarlos. Sin ninguna, se busca la referencia con cualquier monto:
 * es la forma de distinguir «no está» de «está por otra cifra». Si la consulta
 * falla, el cotejo es un error y no un «no aparece».
 */
export function useCotejo(item: QueueItem): Cotejo {
  const conCoincidencias = item.statementMatches > 0

  const exactos = useQuery({
    queryKey: ['statement-matches', item.reportId, 'exactos'],
    queryFn: () => fetchStatementMatches(item.reportId),
    enabled: conCoincidencias,
    staleTime: 60_000,
  })

  const amplios = useQuery({
    queryKey: ['statement-matches', item.reportId, 'cualquier-monto'],
    queryFn: () => fetchStatementMatches(item.reportId, CUALQUIER_MONTO_VES),
    enabled: !conCoincidencias,
    staleTime: 60_000,
  })

  const consulta = conCoincidencias ? exactos : amplios
  if (consulta.isError) return { tipo: 'error', reintentar: () => void consulta.refetch() }
  if (consulta.isPending) return { tipo: 'cargando' }

  return clasificarCotejo(item.statementMatches, exactos.data ?? [], amplios.data ?? [])
}

/**
 * El movimiento que respaldará la aprobación: el único libre, o el que eligió
 * quien aprueba entre varios. `null` si no hay ninguno que valga.
 */
export function movimientoQueRespalda(cotejo: Cotejo, elegido: string | null): StatementMatch | null {
  if (cotejo.tipo === 'encontrado') return cotejo.libre
  if (cotejo.tipo === 'varios') {
    return cotejo.movimientos.find((m) => m.id === elegido && m.disponible) ?? null
  }
  return null
}

/**
 * Qué dice el extracto de este pago: el veredicto en un aviso de una línea y,
 * debajo, los movimientos que encajan, que es donde se decide mirando.
 */
export function CotejoBanco({
  cotejo,
  elegido,
  onElegir,
  onImportar,
}: {
  cotejo: Cotejo
  /** El movimiento marcado entre varios. */
  elegido: string | null
  onElegir: (id: string) => void
  onImportar: () => void
}) {
  return (
    <Seccion
      titulo="El extracto del banco"
      info="Se busca la referencia en los movimientos importados del banco. Sin ninguno que encaje, se busca con cualquier monto: así se distingue «no está» de «está por otra cifra»."
    >
      <VeredictoDelCotejo
        cotejo={cotejo}
        elegido={elegido}
        onElegir={onElegir}
        onImportar={onImportar}
      />
    </Seccion>
  )
}

function VeredictoDelCotejo({
  cotejo,
  elegido,
  onElegir,
  onImportar,
}: {
  cotejo: Cotejo
  elegido: string | null
  onElegir: (id: string) => void
  onImportar: () => void
}) {
  if (cotejo.tipo === 'cargando') {
    return <SkeletonBlock className="h-14 w-full" />
  }

  if (cotejo.tipo === 'error') {
    return (
      <Callout
        tone="warning"
        titulo="No se pudo cotejar con el extracto"
        accion={
          <Button size="sm" variant="tonal" onClick={cotejo.reintentar}>
            Reintentar
          </Button>
        }
      >
        Aprobarlo ahora sería hacerlo sin respaldo del banco.
      </Callout>
    )
  }

  if (cotejo.tipo === 'encontrado') {
    return (
      <>
        <Callout tone="success" titulo="Encontrado en el extracto" />
        <Movimientos movimientos={cotejo.movimientos} />
      </>
    )
  }

  if (cotejo.tipo === 'varios') {
    const libres = cotejo.movimientos.filter((m) => m.disponible).length
    return (
      <>
        <Callout tone="warning" titulo={`${libres} movimientos del extracto encajan`}>
          Elige el que corresponde a este pago: queda guardado con la aprobación y no podrá
          respaldar otro.
        </Callout>
        <Movimientos movimientos={cotejo.movimientos} elegido={elegido} onElegir={onElegir} />
      </>
    )
  }

  if (cotejo.tipo === 'ya_usado') {
    return (
      <>
        <Callout
          tone="warning"
          titulo="El movimiento que encaja ya respalda otro pago"
          detalles="Un mismo movimiento no puede respaldar dos pagos."
        >
          Si este pago es real, se aprueba sin cotejo y con el motivo.
        </Callout>
        <Movimientos movimientos={cotejo.movimientos} />
      </>
    )
  }

  if (cotejo.tipo === 'monto_distinto') {
    return (
      <>
        <Callout tone="warning" titulo="La referencia está en el extracto por otro monto">
          Suele ser un error al teclear el monto.
        </Callout>
        <Movimientos movimientos={cotejo.movimientos} />
      </>
    )
  }

  return (
    <Callout
      tone="info"
      titulo="No aparece en el extracto"
      accion={
        <Button size="sm" variant="tonal" onClick={onImportar}>
          <Upload size={14} aria-hidden /> Importar el extracto
        </Button>
      }
    >
      Puede que el extracto de ese día todavía no se haya importado.
    </Callout>
  )
}

/**
 * El movimiento que respaldó un pago ya aprobado, o que no lo respaldó
 * ninguno. Lo que se ve es lo que se guardó al aprobar (o al ligarlo después),
 * no lo que coincide hoy. Sin movimiento, `onLigar` ofrece ligarlo: el
 * extracto del día suele llegar después de aprobar.
 */
export function MovimientoQueLoRespaldo({
  movimiento,
  onLigar,
}: {
  movimiento: MovimientoDelExtracto | null
  onLigar?: () => void
}) {
  if (!movimiento) {
    return (
      <Callout
        tone="info"
        titulo="Se aprobó sin un movimiento del extracto ligado"
        accion={
          onLigar && (
            <Button size="sm" variant="tonal" onClick={onLigar}>
              <Link2 size={14} aria-hidden /> Ligar un movimiento
            </Button>
          )
        }
      >
        Sin cotejo, o con el extracto de ese día sin importar todavía.
      </Callout>
    )
  }
  return (
    <Callout
      tone="success"
      titulo="Lo respaldó este movimiento del extracto"
      detalles={movimiento.description ?? undefined}
    >
      {formatDay(movimiento.movedOn)} · {movimiento.bank} ·{' '}
      <span className="font-mono">{movimiento.reference}</span> ·{' '}
      <span className="tabular-nums">{formatVes(movimiento.amountVes)}</span>
    </Callout>
  )
}

/**
 * Los movimientos candidatos, con todos sus datos: se decide mirándolos. Con
 * `onElegir`, cada movimiento libre lleva su botón de radio; uno que ya
 * respalda otro pago o que se descartó sale apagado y dice por qué.
 */
function Movimientos({
  movimientos,
  elegido = null,
  onElegir,
}: {
  movimientos: StatementMatch[]
  elegido?: string | null
  onElegir?: (id: string) => void
}) {
  const conEleccion = onElegir !== undefined
  return (
    <Table
      headers={[
        ...(conEleccion ? ['Respalda'] : []),
        'Fecha',
        'Descripción',
        'Banco',
        'Monto',
        {
          label: 'Diferencia',
          info: 'El monto del movimiento menos el que el paciente tenía que pagar en bolívares, a la tasa de su cotización.',
        },
      ]}
    >
      {movimientos.map((m) => (
        <Tr key={m.id} className={m.disponible ? '' : 'opacity-60'}>
          {conEleccion && (
            <Td>
              {m.disponible && (
                <input
                  type="radio"
                  name="movimiento-que-respalda"
                  aria-label={`Respalda este pago: movimiento del ${formatDay(m.movedOn)}, referencia ${m.reference}`}
                  checked={elegido === m.id}
                  onChange={() => onElegir(m.id)}
                  className="size-4 accent-on-surface"
                />
              )}
            </Td>
          )}
          <Td className="whitespace-nowrap">{formatDay(m.movedOn)}</Td>
          <Td className="max-w-xs text-on-surface-variant">
            <span className="block font-mono type-panel-caption">{m.reference}</span>
            {m.description ?? 'Sin descripción'}
            {!m.disponible && <PorQueNoVale m={m} />}
          </Td>
          <Td className="text-on-surface-variant">{m.bank}</Td>
          <Td className="whitespace-nowrap tabular-nums">{formatVes(m.amountVes)}</Td>
          <Td
            className={`whitespace-nowrap tabular-nums ${
              Math.abs(m.differenceVes) > 1 ? 'text-warning' : 'text-on-surface-variant'
            }`}
          >
            {m.differenceVes > 0 ? '+' : m.differenceVes < 0 ? '−' : ''}
            {formatVes(Math.abs(m.differenceVes))}
          </Td>
        </Tr>
      ))}
    </Table>
  )
}

/** Por qué un movimiento no puede respaldar este pago, con el pago al que ya respalda. */
function PorQueNoVale({ m }: { m: StatementMatch }) {
  if (m.usadoPor) {
    return (
      <span className="mt-1 block type-panel-caption text-on-surface">
        Ya respalda el pago de{' '}
        <Link
          to="/admin/cobros/$id"
          params={{ id: m.usadoPor.reportId }}
          className="text-on-surface underline decoration-panel-hairline-strong underline-offset-2 hover:decoration-on-surface"
        >
          {m.usadoPor.fullName ?? 'otro paciente'}
        </Link>
      </span>
    )
  }
  if (m.descartado) {
    return (
      <span className="mt-1 block type-panel-caption text-on-surface">
        Se descartó como ajeno a los pacientes.
      </span>
    )
  }
  return null
}
