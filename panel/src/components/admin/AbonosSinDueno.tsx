import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Ban, Inbox, Link2 } from 'lucide-react'

import { DataTable } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import {
  Button,
  ConfirmDialog,
  EmptyState,
  ErrorBox,
  Menu,
  SkeletonList,
  formatDateTime,
  formatDay,
  formatDocument,
  formatUsd,
  formatPhone,
  formatVes,
  hoyCaracas,
} from '@/components/ui'
import { AsignarAbono } from '@/components/admin/caja/AsignarAbono'
import { LigarDesdeElAbono } from '@/components/admin/caja/LigarMovimiento'
import { discardDeposit, fetchUnmatchedDeposits } from '@/features/admin/deposits'
import type { UnmatchedDeposit } from '@/features/admin/deposits'
import { payerDocument, readPayerHint } from '@/features/admin/payer'
import { useToast } from '@/components/Toast'
import { csvDinero } from '@/lib/csv'
import { describeError } from '@/lib/supabase'

/**
 * Cuántos abonos pide la consulta. Con nombre porque la tabla lo necesita
 * para avisar de que hay más y no se están viendo.
 */
const LIMITE = 100

type Abierto = { deposito: UnmatchedDeposit; siguiente: UnmatchedDeposit | null }

/**
 * El dinero que entró al banco y nadie ha reclamado.
 *
 * El extracto se importaba solo para cotejar: dado un pago reportado,
 * comprobar que existe. La pregunta contraria (qué entró sin dueño) es la que
 * encuentra a quien transfirió y no reportó, a quien escribió mal la
 * referencia y a quien pagó por otra persona.
 *
 * El abono que se está asignando viaja en la URL (`?asignar=`): así «Siguiente
 * abono» es solo cambiar ese id.
 */
export function AbonosSinDueno({
  asignar,
  onAsignar,
}: {
  asignar: string | undefined
  onAsignar: (id: string | undefined) => void
}) {
  const query = useQuery({
    queryKey: ['unmatched-deposits', LIMITE],
    queryFn: () => fetchUnmatchedDeposits(LIMITE),
    refetchInterval: 60_000,
  })

  const [descartando, setDescartando] = useState<UnmatchedDeposit | null>(null)
  const [ligando, setLigando] = useState<UnmatchedDeposit | null>(null)

  // El abono abierto y el que va después se recuerdan al abrirlo: al asignarlo,
  // la lista se recarga sin él y la ventana tiene que seguir en pie para
  // ofrecer el siguiente.
  const rows = query.data ?? []
  const [abierto, setAbierto] = useState<Abierto | null>(null)
  const actual = asignar ? rows.find((d) => d.id === asignar) : undefined
  if (actual && abierto?.deposito.id !== actual.id) {
    const i = rows.indexOf(actual)
    setAbierto({ deposito: actual, siguiente: (i + 1 < rows.length ? rows.at(i + 1) : i > 0 ? rows.at(i - 1) : undefined) ?? null })
  }
  const enCurso = asignar && abierto?.deposito.id === asignar ? abierto : null

  if (query.isPending) return <SkeletonList rows={4} />

  if (query.isError) {
    return (
      <ErrorBox title="No se pudieron cargar los abonos" detail={describeError(query.error)} />
    )
  }

  // Helios y Ronda cobran en la misma cuenta del BNC: los abonos cuyo pagador
  // no es de Helios van aparte, plegados, para no asignarle a un paciente el
  // pago de un usuario de Ronda.
  const deHelios = rows.filter((d) => d.deHelios)
  const ajenos = rows.filter((d) => !d.deHelios)
  const conTasa = deHelios.filter((d) => d.amountUsd !== null)
  const sinTasa = deHelios.length - conTasa.length
  const total = conTasa.reduce((s, d) => s + (d.amountUsd ?? 0), 0)

  const columnas = construirColumnas({
    onAsignar: (d) => onAsignar(d.id),
    onDescartar: setDescartando,
    onLigar: setLigando,
  })

  return (
    <>
      {deHelios.length === 0 ? (
        <EmptyState
          icon={<Inbox size={48} />}
          title="Todo el dinero de Helios que entró tiene dueño"
          description="Todos los abonos de pacientes de Helios del extracto importado respaldan un pago aprobado o se descartaron."
        />
      ) : (
        <DataTable
          rows={deHelios}
          rowKey={(d) => d.id}
          columns={columnas}
          noun={['abono sin dueño', 'abonos sin dueño']}
          limit={LIMITE}
          summary={`${formatUsd(total)} que entraron al banco sin un pago aprobado que los respalde${
            sinTasa > 0
              ? `, más ${sinTasa} ${sinTasa === 1 ? 'abono' : 'abonos'} sin tasa BCV de su día`
              : ''
          }`}
          exportar={{ archivo: `abonos-sin-dueno-${hoyCaracas()}` }}
          onRowClick={(d) => onAsignar(d.id)}
        />
      )}

      {ajenos.length > 0 && (
        <details className="mt-8">
          <summary className="cursor-pointer type-panel-section text-on-surface">
            Ajenos a Helios, probablemente de Ronda ({ajenos.length})
          </summary>
          <p className="mt-2 mb-3 type-panel-caption text-on-surface-variant">
            Helios y Ronda cobran en la misma cuenta del BNC. Quien pagó estos abonos (la cédula o el teléfono que
            escribe el banco) no es paciente de Helios ni el pagador de ningún pago registrado aquí. No cuentan en
            Inicio; si alguno sí es de Helios, ábrelo y confirma antes de asignarlo.
          </p>
          <DataTable
            rows={ajenos}
            rowKey={(d) => d.id}
            columns={columnas}
            noun={['abono ajeno', 'abonos ajenos']}
            onRowClick={(d) => onAsignar(d.id)}
          />
        </details>
      )}

      {enCurso && (
        <AsignarAbono
          key={enCurso.deposito.id}
          deposit={enCurso.deposito}
          siguiente={enCurso.siguiente}
          onSiguiente={(id) => onAsignar(id)}
          onClose={() => onAsignar(undefined)}
        />
      )}

      {descartando && (
        <DescartarAbono deposit={descartando} onClose={() => setDescartando(null)} />
      )}

      {ligando && (
        <LigarDesdeElAbono abono={{ ...ligando, descartado: false }} onClose={() => setLigando(null)} />
      )}
    </>
  )
}

// ── Las columnas ───────────────────────────────────────────────────────────

function construirColumnas({
  onAsignar,
  onDescartar,
  onLigar,
}: {
  onAsignar: (d: UnmatchedDeposit) => void
  onDescartar: (d: UnmatchedDeposit) => void
  /** Es de un pago ya aprobado sin movimiento: se liga, no se asigna. */
  onLigar: (d: UnmatchedDeposit) => void
}): Array<Column<UnmatchedDeposit>> {
  return [
    {
      key: 'fecha',
      header: 'Fecha',
      identity: true,
      sort: (d) => d.movedOn,
      sortDir: 'desc',
      csv: (d) => d.movedOn,
      cell: (d) => (
        <span className="block whitespace-nowrap">
          {formatDay(d.movedOn)}
          <span className="block type-panel-caption text-on-surface-variant">
            importado el {formatDateTime(d.importedAt)}
          </span>
        </span>
      ),
    },
    {
      key: 'referencia',
      header: 'Referencia',
      sort: (d) => d.reference,
      csv: (d) => d.reference,
      cell: (d) => <span className="font-mono type-panel-caption">{d.reference}</span>,
    },
    {
      key: 'banco',
      header: 'Banco',
      sort: (d) => d.bank,
      csv: (d) => d.bank,
      cell: (d) => <span className="text-on-surface-variant">{d.bank}</span>,
    },
    {
      key: 'monto',
      header: 'Monto',
      info: 'En dólares, a la tasa BCV del dólar del día del abono; debajo, lo que entró en bolívares.',
      type: 'number',
      sortDir: 'desc',
      // Por el euro, que es la moneda del sistema. Un abono sin tasa del día no
      // tiene equivalente, y `null` lo manda al final en vez de fingir que vale 0.
      sort: (d) => d.amountUsd,
      csv: (d) => (d.amountUsd === null ? null : csvDinero(d.amountUsd)),
      cell: (d) =>
        d.amountUsd === null ? (
          <span className="text-on-surface-variant">{formatVes(d.amountVes)}</span>
        ) : (
          <>
            <span className="font-semibold">{formatUsd(d.amountUsd)}</span>
            <span className="mt-0.5 block type-panel-caption font-normal text-on-surface-variant">
              {formatVes(d.amountVes)}
            </span>
          </>
        ),
    },
    {
      key: 'monto-ves',
      header: 'Monto en bolívares',
      type: 'number',
      hidden: true,
      csv: (d) => csvDinero(d.amountVes),
      cell: (d) => formatVes(d.amountVes),
    },
    {
      // El banco escribe en la descripción quién hizo el pago móvil: es la
      // respuesta a la pregunta que trae a cualquiera aquí.
      key: 'pagador',
      header: 'Quién pagó',
      sort: (d) => readPayerHint(d.description)?.document ?? '',
      csv: (d) => {
        const p = readPayerHint(d.description)
        return p ? [payerDocument(p), p.phone].filter(Boolean).join(' ') : null
      },
      cell: (d) => {
        const pagador = readPayerHint(d.description)
        if (!pagador) return <span className="type-panel-caption text-on-surface-variant">—</span>

        const documento = payerDocument(pagador)
        return (
          <span className="block whitespace-nowrap">
            {documento !== null && (
              <span className="block type-panel-body text-on-surface">
                {formatDocument(documento)}
              </span>
            )}
            {pagador.phone !== null && (
              <span className="block type-panel-caption text-on-surface-variant">
                {formatPhone(pagador.phone)}
                {pagador.bankName !== null && ` · ${pagador.bankName}`}
              </span>
            )}
          </span>
        )
      },
    },
    {
      key: 'descripcion',
      header: 'Descripción',
      hidden: true,
      sort: (d) => d.description,
      csv: (d) => d.description,
      cell: (d) => (
        <span className="block max-w-64 type-panel-caption text-on-surface-variant">
          {d.description ?? '—'}
        </span>
      ),
    },
    {
      key: 'acciones',
      header: '',
      cell: (d) => (
        <div className="flex items-center gap-1.5">
          <Button size="sm" variant="tonal" onClick={() => onAsignar(d)}>
            Asignar
          </Button>
          <Menu
            etiqueta={`Más acciones del abono ${d.reference}`}
            items={[
              { label: 'Es de un pago ya aprobado', icon: Link2, onSelect: () => onLigar(d) },
              { label: 'No es de un paciente', icon: Ban, onSelect: () => onDescartar(d) },
            ]}
          />
        </div>
      ),
    },
  ]
}

// ── Descartar ──────────────────────────────────────────────────────────────

function DescartarAbono({ deposit, onClose }: { deposit: UnmatchedDeposit; onClose: () => void }) {
  const queryClient = useQueryClient()
  const avisar = useToast()

  const monto =
    deposit.amountUsd === null ? formatVes(deposit.amountVes) : formatUsd(deposit.amountUsd)

  const mutation = useMutation({
    mutationFn: (reason: string) => discardDeposit(deposit.id, reason),
    onSuccess: () => {
      avisar(`Abono de ${monto} descartado. Queda en la pestaña Descartados`)
      void queryClient.invalidateQueries({ queryKey: ['unmatched-deposits'] })
      void queryClient.invalidateQueries({ queryKey: ['discarded-deposits'] })
      onClose()
    },
  })

  return (
    <ConfirmDialog
      title="No es de un paciente"
      summary={`El abono de ${monto} del ${formatDay(deposit.movedOn)}, referencia ${deposit.reference}, sale de la lista.`}
      detail={
        <p className="type-panel-body text-on-surface-variant">
          <strong>No se escribe ningún asiento.</strong> Queda en Descartados, con tu motivo.
        </p>
      }
      nivel="sensible"
      reasonLabel="Qué es este abono"
      reasonPlaceholder="Depósito propio para cubrir el pago de hoy a las clínicas"
      confirmLabel="Sacarlo de la lista"
      busy={mutation.isPending}
      error={mutation.isError ? describeError(mutation.error) : undefined}
      onConfirm={(reason) => mutation.mutate(reason)}
      onClose={onClose}
    />
  )
}
