import { useId, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import {
  Badge,
  Button,
  Callout,
  Card,
  ErrorBox,
  Modal,
  SkeletonBlock,
  Table,
  Td,
  Textarea,
  Tr,
  formatDateTime,
  formatDay,
  formatUsd,
  formatVes,
} from '@/components/ui'
import { useToast } from '@/components/Toast'
import type { QueueItem } from '@/features/admin/api'
import {
  fetchMovimientosParaLigar,
  fetchPagosParaLigar,
  ligarMovimiento,
  pideMotivo,
} from '@/features/admin/ligarExtracto'
import type { MovimientoParaLigar, PagoParaLigar } from '@/features/admin/ligarExtracto'
import { describeError } from '@/lib/supabase'

/** Lo mínimo para que un motivo diga algo. Lo mismo exige el servidor. */
const MOTIVO_MINIMO = 3

/**
 * Desde la ficha de un pago aprobado sin movimiento: qué movimiento del
 * extracto lo respalda. Se buscan por monto y fecha, con cualquier referencia,
 * también entre los descartados.
 */
export function LigarDesdeElPago({ item, onClose }: { item: QueueItem; onClose: () => void }) {
  const query = useQuery({
    queryKey: ['link-candidates', item.reportId],
    queryFn: () => fetchMovimientosParaLigar(item.reportId),
  })

  const libres = (query.data ?? []).filter((m) => m.disponible)
  const [marcado, setMarcado] = useState<string | null>(null)
  // Con un único libre, ya va marcado: es el que se ve y el que se liga.
  const elegido = libres.find((m) => m.id === marcado) ?? (libres.length === 1 ? libres[0] : null)

  return (
    <Modal title="Ligar un movimiento del extracto" width="lg" onClose={onClose}>
      <div className="flex flex-col gap-5">
        <Card tone="inset">
          <p className="type-panel-body text-on-surface">
            {item.fullName ?? 'Sin nombre'} reportó{' '}
            <span className="tabular-nums">{formatVes(item.amountVes)}</span> con la referencia{' '}
            <span className="font-mono">{item.reference ?? '—'}</span>
          </p>
          <p className="mt-0.5 type-panel-caption text-on-surface-variant">
            El {formatDateTime(item.createdAt)} · aprobado sin movimiento del extracto
          </p>
        </Card>

        {query.isPending && <SkeletonBlock className="h-24 w-full" />}

        {query.isError && (
          <ErrorBox title="No se pudieron leer los movimientos" detail={describeError(query.error)} />
        )}

        {query.isSuccess && query.data.length === 0 && (
          <Callout tone="info" titulo="Ningún movimiento del extracto cuadra en monto y fecha">
            Puede que el extracto de ese día todavía no se haya importado.
          </Callout>
        )}

        {query.isSuccess && query.data.length > 0 && (
          <Table
            headers={[
              'Respalda',
              'Fecha',
              'Referencia del banco',
              'Estado',
              'Monto',
              {
                label: 'Diferencia',
                info: 'El monto del movimiento menos el que el paciente tenía que pagar en bolívares. Solo salen los de ±1 Bs.',
              },
            ]}
          >
            {query.data.map((m) => (
              <FilaMovimiento
                key={m.id}
                m={m}
                marcado={elegido?.id === m.id}
                onMarcar={() => setMarcado(m.id)}
              />
            ))}
          </Table>
        )}

        <Confirmar
          reportId={item.reportId}
          lineId={elegido?.id ?? null}
          motivo={elegido ? porQueMotivo(elegido.referenciaCoincide, elegido.descartado) : null}
          sinElegir={
            query.isSuccess && libres.length === 0
              ? 'No hay ningún movimiento libre que ligar.'
              : 'Elige el movimiento que respalda este pago.'
          }
          onClose={onClose}
        />
      </div>
    </Modal>
  )
}

/** Un abono del extracto, pendiente o descartado, visto desde su lista. */
export type AbonoParaLigar = {
  id: string
  bank: string
  movedOn: string
  reference: string
  amountVes: number
  amountUsd: number | null
  descartado: boolean
}

/**
 * Desde un abono sin dueño o descartado: el pago ya aprobado al que respalda.
 * Es la salida que faltaba entre «Asignar», que crea un pago nuevo y cobraría
 * las cuotas otra vez, y «No es de un usuario».
 */
export function LigarDesdeElAbono({ abono, onClose }: { abono: AbonoParaLigar; onClose: () => void }) {
  const query = useQuery({
    queryKey: ['link-reports', abono.id],
    queryFn: () => fetchPagosParaLigar(abono.id),
  })

  const pagos = query.data ?? []
  const [marcado, setMarcado] = useState<string | null>(null)
  const elegido = pagos.find((p) => p.reportId === marcado) ?? (pagos.length === 1 ? pagos[0] : null)

  return (
    <Modal title="Es de un pago ya aprobado" width="lg" onClose={onClose}>
      <div className="flex flex-col gap-5">
        <Card tone="inset">
          <div className="flex flex-wrap items-baseline justify-between gap-3">
            <div>
              <p className="type-panel-body text-on-surface">
                Referencia <span className="font-mono">{abono.reference}</span> · {abono.bank}
              </p>
              <p className="mt-0.5 type-panel-caption text-on-surface-variant">
                Entró el {formatDay(abono.movedOn)}
                {abono.descartado && ' · descartado'}
              </p>
            </div>
            <p className="type-panel-section tabular-nums text-on-surface">
              {abono.amountUsd === null ? formatVes(abono.amountVes) : formatUsd(abono.amountUsd)}
            </p>
          </div>
        </Card>

        {query.isPending && <SkeletonBlock className="h-24 w-full" />}

        {query.isError && (
          <ErrorBox title="No se pudieron leer los pagos" detail={describeError(query.error)} />
        )}

        {query.isSuccess && pagos.length === 0 && (
          <Callout tone="info" titulo="Ningún pago aprobado sin movimiento cuadra con este abono">
            Se buscan por monto (±1 Bs) y a cinco días del reporte. Si es de alguien que no reportó,
            asígnalo.
          </Callout>
        )}

        {query.isSuccess && pagos.length > 0 && (
          <Table
            headers={[
              'Respalda',
              'Paciente',
              'Reportado',
              'Referencia reportada',
              'Monto',
              {
                label: 'Diferencia',
                info: 'El monto del abono menos el que el paciente tenía que pagar en bolívares. Solo salen los de ±1 Bs.',
              },
            ]}
          >
            {pagos.map((p) => (
              <FilaPago
                key={p.reportId}
                p={p}
                marcado={elegido?.reportId === p.reportId}
                onMarcar={() => setMarcado(p.reportId)}
              />
            ))}
          </Table>
        )}

        <Confirmar
          reportId={elegido?.reportId ?? null}
          lineId={abono.id}
          motivo={elegido ? porQueMotivo(elegido.referenciaCoincide, abono.descartado) : null}
          sinElegir="Elige el pago al que respalda este abono."
          onClose={onClose}
        />
      </div>
    </Modal>
  )
}

// ── Las filas ──────────────────────────────────────────────────────────────

function FilaMovimiento({
  m,
  marcado,
  onMarcar,
}: {
  m: MovimientoParaLigar
  marcado: boolean
  onMarcar: () => void
}) {
  return (
    <Tr className={m.disponible ? '' : 'opacity-60'}>
      <Td>
        {m.disponible && (
          <input
            type="radio"
            name="movimiento-para-ligar"
            aria-label={`Respalda este pago: movimiento del ${formatDay(m.movedOn)}, referencia ${m.reference}`}
            checked={marcado}
            onChange={onMarcar}
            className="size-4 accent-on-surface"
          />
        )}
      </Td>
      <Td className="whitespace-nowrap">{formatDay(m.movedOn)}</Td>
      <Td className="max-w-xs">
        <span className="block font-mono type-panel-caption">{m.reference}</span>
        <Coincide si={m.referenciaCoincide} />
      </Td>
      <Td className="max-w-xs text-on-surface-variant">
        {m.usadoPor ? (
          <span className="type-panel-caption text-on-surface">
            Ya respalda el pago de {m.usadoPor.fullName ?? 'otro paciente'}
          </span>
        ) : m.descartado ? (
          <span className="block type-panel-caption">
            <span className="text-on-surface">Descartado{m.descartadoPor ? ` por ${m.descartadoPor}` : ''}</span>
            {m.motivoDelDescarte && <span className="block">«{m.motivoDelDescarte}»</span>}
          </span>
        ) : (
          <span className="type-panel-caption">Sin dueño</span>
        )}
      </Td>
      <Td className="whitespace-nowrap tabular-nums">{formatVes(m.amountVes)}</Td>
      <Diferencia ves={m.differenceVes} />
    </Tr>
  )
}

function FilaPago({ p, marcado, onMarcar }: { p: PagoParaLigar; marcado: boolean; onMarcar: () => void }) {
  return (
    <Tr>
      <Td>
        <input
          type="radio"
          name="pago-para-ligar"
          aria-label={`Respalda el pago de ${p.fullName ?? 'sin nombre'} del ${formatDateTime(p.createdAt)}`}
          checked={marcado}
          onChange={onMarcar}
          className="size-4 accent-on-surface"
        />
      </Td>
      <Td className="max-w-48">{p.fullName ?? 'Sin nombre'}</Td>
      <Td className="whitespace-nowrap text-on-surface-variant">{formatDateTime(p.createdAt)}</Td>
      <Td>
        <span className="block font-mono type-panel-caption">{p.reference ?? '—'}</span>
        <Coincide si={p.referenciaCoincide} />
      </Td>
      <Td className="whitespace-nowrap tabular-nums">
        {formatUsd(p.amountUsd)}
        <span className="block type-panel-caption text-on-surface-variant">{formatVes(p.amountVes)}</span>
      </Td>
      <Diferencia ves={p.differenceVes} />
    </Tr>
  )
}

function Coincide({ si }: { si: boolean }) {
  return (
    <Badge tone={si ? 'success' : 'warning'} icono className="mt-1">
      {si ? 'Coincide con la reportada' : 'Otra referencia'}
    </Badge>
  )
}

function Diferencia({ ves }: { ves: number }) {
  return (
    <Td className="whitespace-nowrap tabular-nums text-on-surface-variant">
      {ves > 0 ? '+' : ves < 0 ? '−' : ''}
      {formatVes(Math.abs(ves))}
    </Td>
  )
}

// ── Confirmar ──────────────────────────────────────────────────────────────

/** Por qué hace falta motivo para ligar este par, o `null` si no hace falta. */
function porQueMotivo(referenciaCoincide: boolean, descartado: boolean): string | null {
  if (!pideMotivo({ referenciaCoincide, descartado })) return null
  if (descartado && !referenciaCoincide) {
    return 'Estaba descartado y la referencia no es la reportada: di por qué es de este pago.'
  }
  if (descartado) return 'Estaba descartado: di por qué se recupera.'
  return 'La referencia no es la reportada: di por qué es de este pago.'
}

/**
 * El motivo y el botón. Tras ligar se refresca todo lo que enseña el cotejo:
 * la ficha, la lista de pagos (su columna «En el extracto») y las dos listas
 * de abonos, de las que el movimiento sale.
 */
function Confirmar({
  reportId,
  lineId,
  motivo,
  sinElegir,
  onClose,
}: {
  reportId: string | null
  lineId: string | null
  /** Por qué se pide motivo; `null` si es opcional. */
  motivo: string | null
  /** Qué falta cuando todavía no hay par. */
  sinElegir: string
  onClose: () => void
}) {
  const queryClient = useQueryClient()
  const avisar = useToast()
  const id = useId()
  const [nota, setNota] = useState('')

  const mutation = useMutation({
    mutationFn: (par: { reportId: string; lineId: string; note: string }) =>
      ligarMovimiento({ reportId: par.reportId, lineId: par.lineId, note: par.note || undefined }),
    onSuccess: () => {
      avisar('Movimiento ligado: el pago sale como encontrado en el extracto')
      for (const clave of [
        'payment-report',
        'payment-queue',
        'unmatched-deposits',
        'discarded-deposits',
        'statement-matches',
        'link-candidates',
        'link-reports',
      ]) {
        void queryClient.invalidateQueries({ queryKey: [clave] })
      }
      onClose()
    },
  })

  const texto = nota.trim()
  const bloqueo =
    reportId === null || lineId === null
      ? sinElegir
      : motivo !== null && texto.length < MOTIVO_MINIMO
        ? texto.length === 0
          ? 'Escribe el motivo para poder ligarlo.'
          : `El motivo tiene que tener al menos ${MOTIVO_MINIMO} caracteres.`
        : null

  return (
    <div className="flex flex-col gap-4">
      <Textarea
        id={id}
        label={motivo === null ? 'Nota (opcional)' : 'Motivo'}
        value={nota}
        onChange={setNota}
        rows={2}
        hint={motivo ?? undefined}
        placeholder="Puso las primeras cifras del comprobante; en el banco es 1119488724"
      />

      {mutation.isError && <ErrorBox title="No se pudo ligar" detail={describeError(mutation.error)} />}

      <div className="flex flex-wrap items-start gap-3">
        <Button
          size="md"
          disabled={bloqueo !== null || mutation.isPending}
          motivoApagado={bloqueo ?? undefined}
          onClick={() => {
            if (reportId !== null && lineId !== null) mutation.mutate({ reportId, lineId, note: texto })
          }}
        >
          {mutation.isPending ? 'Ligando…' : 'Ligar el movimiento'}
        </Button>
        <Button size="md" variant="tonal" onClick={onClose}>
          Cancelar
        </Button>
      </div>
    </div>
  )
}
