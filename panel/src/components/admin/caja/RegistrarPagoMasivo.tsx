import { useState } from 'react'
import { queryOptions, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ListChecks } from 'lucide-react'

import {
  Badge,
  Button,
  Checkbox,
  ConfirmDialog,
  ErrorBox,
  Input,
  Select,
  SkeletonTable,
  formatDateTime,
  formatDay,
  formatUsd,
  formatVes,
  hoyCaracas,
} from '@/components/ui'
import { Callout } from '@/components/kit/Callout'
import { Modal } from '@/components/overlays'
import { useToast } from '@/components/Toast'
import { registerBulkPayout } from '@/features/admin/api'
import { llamarRpc } from '@/features/admin/metricas/consulta'
import {
  bloqueoDelRegistro,
  cuentaCorta,
  leerLotesDePagoMasivo,
  lineasARegistrar,
  porRegistrar,
} from '@/features/admin/pagoMasivo'
import type { LineaDelLote, LoteDePagoMasivo } from '@/features/admin/pagoMasivo'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

/** Cuántos archivos se ofrecen: los de los últimos días bastan. */
const LOTES = 10

function consultaLotes() {
  return queryOptions({
    queryKey: ['admin-bulk-payouts', LOTES],
    queryFn: ({ signal }) =>
      llamarRpc('admin_bulk_payouts', { p_limit: LOTES }, { signal, leer: leerLotesDePagoMasivo }),
  })
}

function sumar(lineas: ReadonlyArray<LineaDelLote>, cifra: (l: LineaDelLote) => number, decimales: number) {
  const f = 10 ** decimales
  return lineas.reduce((s, l) => Math.round((s + cifra(l)) * f) / f, 0)
}

/** «Pago del 14 oct · 3 por registrar · bajado 14 oct, 9:40». */
function nombreDelLote(lote: LoteDePagoMasivo): string {
  const faltan = porRegistrar(lote).length
  const estado = faltan === 0 ? 'nada por registrar' : `${faltan} por registrar`
  return `Pago del ${formatDay(lote.payDate)} · ${estado} · bajado ${formatDateTime(lote.createdAt)}`
}

/**
 * «Registrar el pago masivo»: cuando el banco procesó el archivo, registra de
 * una vez la transferencia de cada clínica que iba en él, con los bolívares,
 * la fecha de pago y la referencia del archivo (o la que dé el banco).
 *
 * Todo o nada y sin repetir: una línea ya registrada no se vuelve a registrar,
 * y una cuyas liquidaciones se pagaron por otro lado desde que se bajó el
 * archivo no se ofrece.
 */
export function RegistrarPagoMasivo() {
  const [abierto, setAbierto] = useState(false)

  return (
    <>
      <Button size="sm" variant="text" onClick={() => setAbierto(true)}>
        <ListChecks size={15} aria-hidden />
        Registrar el pago masivo
      </Button>
      {abierto && <VentanaDelRegistro onClose={() => setAbierto(false)} />}
    </>
  )
}

function VentanaDelRegistro({ onClose }: { onClose: () => void }) {
  const lotes = useQuery(consultaLotes())

  return (
    <Modal title="Registrar el pago masivo" onClose={onClose} width="lg">
      {lotes.isPending ? (
        <SkeletonTable rows={3} columns={4} />
      ) : lotes.isError ? (
        <ErrorBox title="No se pudieron leer los archivos del banco" detail={describeError(lotes.error)} />
      ) : lotes.data.length === 0 ? (
        <p className="type-panel-body text-on-surface-variant">
          Todavía no se ha bajado ningún archivo del banco. Bájalo con «Archivo del banco» y, cuando el banco lo
          procese, regístralo aquí.
        </p>
      ) : (
        <Formulario lotes={lotes.data} onClose={onClose} />
      )}
    </Modal>
  )
}

function Formulario({ lotes, onClose }: { lotes: LoteDePagoMasivo[]; onClose: () => void }) {
  const hoy = hoyCaracas()
  const queryClient = useQueryClient()
  const isSuperAdmin = useIsSuperAdmin()
  const avisar = useToast()

  // Por defecto, el más reciente que tenga algo por registrar.
  const inicial = lotes.find((l) => porRegistrar(l).length > 0) ?? lotes[0]
  const [loteId, setLoteId] = useState(inicial.id)
  const lote = lotes.find((l) => l.id === loteId) ?? inicial
  const pendientes = porRegistrar(lote)

  const [marcadas, setMarcadas] = useState<Set<string>>(() => new Set(porRegistrar(inicial).map((l) => l.id)))
  const [referencias, setReferencias] = useState<Record<string, string>>({})
  const [confirmando, setConfirmando] = useState(false)

  const lineasMarcadas = pendientes.filter((l) => marcadas.has(l.id))
  const cambiadas = lote.lines.filter((l) => l.state === 'cambio')
  const totalVes = sumar(lineasMarcadas, (l) => l.amountVes, 2)
  const totalUsd = sumar(lineasMarcadas, (l) => l.amountUsd, 4)
  const n = lineasMarcadas.length
  const transferencias = `${n} ${n === 1 ? 'transferencia' : 'transferencias'}`

  const bloqueo = isSuperAdmin ? bloqueoDelRegistro(lote, lineasMarcadas, referencias, hoy) : SOLO_SUPER_ADMIN

  function elegirLote(id: string) {
    const nuevo = lotes.find((l) => l.id === id)
    if (!nuevo) return
    setLoteId(id)
    setMarcadas(new Set(porRegistrar(nuevo).map((l) => l.id)))
    setReferencias({})
  }

  function alternar(id: string, marcada: boolean) {
    setMarcadas((antes) => {
      const despues = new Set(antes)
      if (marcada) despues.add(id)
      else despues.delete(id)
      return despues
    })
  }

  const mutation = useMutation({
    // El motivo viaja como la nota de cada transferencia y queda en la bitácora.
    mutationFn: (motivo: string) =>
      registerBulkPayout({
        bulkPayoutId: lote.id,
        lines: lineasARegistrar(lineasMarcadas, referencias),
        note: motivo,
      }),
    onSuccess: (r) => {
      setConfirmando(false)
      avisar(
        r.registered === 0
          ? 'Ya estaban registradas: no se registró nada dos veces'
          : `${r.registered} ${r.registered === 1 ? 'transferencia registrada' : 'transferencias registradas'} del pago masivo`,
      )
      for (const clave of [
        'admin-bulk-payouts',
        'admin-bulk-payout-sheet',
        'merchant-payables',
        'settlements',
        'merchant-payouts',
        'settlement-runs',
        'run-payables',
        'admin-overview',
        'admin-cash',
        'admin-forecast',
      ]) {
        void queryClient.invalidateQueries({ queryKey: [clave] })
      }
      onClose()
    },
  })

  return (
    <div className="flex flex-col gap-4">
      <p className="type-panel-body text-on-surface-variant">
        Cuando el banco haya procesado el archivo, marca las transferencias que pagó y regístralas de una vez: cada
        una con los bolívares, la fecha de pago y la referencia del archivo, o la que te dé el banco.
      </p>

      {lotes.length > 1 && (
        <Select
          id="pago-masivo-lote"
          label="Archivo"
          value={lote.id}
          options={lotes.map((l) => ({ value: l.id, label: nombreDelLote(l) }))}
          onChange={elegirLote}
        />
      )}

      <div className="flex flex-wrap gap-x-6 gap-y-1 type-panel-caption text-on-surface-variant">
        <span>Fecha de pago: {formatDay(lote.payDate)}</span>
        <span>Descripción: {lote.description}</span>
        <span>Cuenta debitada: {cuentaCorta(lote.debitAccount)}</span>
        {lote.fxRateUsd !== null && (
          <span>
            BCV del archivo: {formatVes(lote.fxRateUsd)} por dólar
            {lote.fxRateEur !== null && ` · ${formatVes(lote.fxRateEur)} por euro`}
          </span>
        )}
        {lote.createdByName && <span>Lo bajó {lote.createdByName}</span>}
      </div>

      <ul className="flex flex-col divide-y divide-panel-hairline rounded-panel-control border border-panel-hairline">
        {lote.lines.map((l) => (
          <li key={l.id} className="flex flex-wrap items-start justify-between gap-3 px-3 py-3">
            <div className="flex min-w-0 flex-1 flex-col gap-2">
              <Checkbox
                id={`pago-masivo-linea-${l.id}`}
                checked={l.state === 'pendiente' && marcadas.has(l.id)}
                disabled={l.state !== 'pendiente'}
                onChange={(marcada) => alternar(l.id, marcada)}
                label={
                  <span className="type-panel-body">
                    <span className="block text-on-surface">{l.merchantName}</span>
                    <span className="block type-panel-caption text-on-surface-variant">
                      Fila {l.fila} · {l.beneficiaryName} · {cuentaCorta(l.beneficiaryAccount)} · referencia{' '}
                      {l.reference}
                    </span>
                  </span>
                }
              />
              {l.state === 'pendiente' && marcadas.has(l.id) && (
                <Input
                  id={`pago-masivo-ref-${l.id}`}
                  label="Referencia del banco"
                  value={referencias[l.id] ?? ''}
                  onChange={(v) => setReferencias((antes) => ({ ...antes, [l.id]: v }))}
                  placeholder={l.reference}
                  autoComplete="off"
                  hint="Vacía, va la del archivo."
                  className="max-w-xs"
                />
              )}
            </div>
            <div className="flex flex-col items-end gap-1 text-right">
              <span className="whitespace-nowrap tabular-nums type-panel-body text-on-surface">
                {formatVes(l.amountVes)}
              </span>
              <span className="whitespace-nowrap tabular-nums type-panel-caption text-on-surface-variant">
                {formatUsd(l.amountUsd)}
              </span>
              {l.state === 'registrada' && (
                <Badge tone="success">
                  Registrada{l.payoutReference && l.payoutReference !== l.reference ? ` · ${l.payoutReference}` : ''}
                </Badge>
              )}
              {l.state === 'cambio' && <Badge tone="warning">Se pagó por otro lado</Badge>}
            </div>
          </li>
        ))}
      </ul>

      {cambiadas.length > 0 && (
        <Callout
          tone="warning"
          titulo={`${cambiadas.length} ${cambiadas.length === 1 ? 'transferencia ya no cuadra' : 'transferencias ya no cuadran'}`}
        >
          Desde que se bajó el archivo, lo que pagaban se pagó (todo o en parte) por otro lado. No se registran aquí:
          si el banco también les transfirió, revísalo en la página de cada clínica.
        </Callout>
      )}

      <div className="flex flex-wrap items-center justify-between gap-4 rounded-panel-control bg-panel-raised p-4">
        <span className="type-panel-body text-on-surface-variant">
          {transferencias} marcadas de {lote.lines.length} del archivo
        </span>
        <span className="text-right">
          <span className="block type-panel-figure text-on-surface">{formatVes(totalVes)}</span>
          <span className="block type-panel-caption tabular-nums text-on-surface-variant">{formatUsd(totalUsd)}</span>
        </span>
      </div>

      <div className="flex flex-wrap items-start justify-end gap-3">
        <Button size="md" variant="text" onClick={onClose}>
          Cancelar
        </Button>
        <Button
          size="md"
          disabled={bloqueo !== null}
          motivoApagado={bloqueo ?? undefined}
          onClick={() => setConfirmando(true)}
        >
          Registrar {transferencias}
        </Button>
      </div>

      <p className="type-panel-caption text-panel-muted">
        Registra transferencias que el banco ya hizo: no mueve dinero.
      </p>

      {confirmando && (
        <ConfirmDialog
          title="Registrar el pago masivo"
          summary={`Vas a registrar ${transferencias} por ${formatVes(totalVes)} (${formatUsd(totalUsd)}), del archivo con fecha de pago ${formatDay(lote.payDate)}.`}
          detail={
            <p className="type-panel-body text-on-surface-variant">
              Cada una se registra por transferencia con los bolívares, la fecha y la referencia del archivo (o la del
              banco, si la escribiste), salda las liquidaciones que iban en su fila y escribe su asiento en el libro.
              Es todo o nada: si alguna no se puede registrar, no se registra ninguna. Al confirmar baja «Por pagar a
              clínicas».
            </p>
          }
          nivel="sensible"
          reasonLabel="Motivo"
          reasonPlaceholder="El banco procesó el pago masivo de hoy"
          confirmLabel={`Registrar ${transferencias}`}
          busy={mutation.isPending}
          error={mutation.isError ? describeError(mutation.error) : undefined}
          onConfirm={(motivo) => mutation.mutate(motivo)}
          onClose={() => {
            setConfirmando(false)
            mutation.reset()
          }}
        />
      )}
    </div>
  )
}
