import { useQuery } from '@tanstack/react-query'
import { Download, Landmark, X } from 'lucide-react'

import {
  Button,
  Card,
  EmptyState,
  ErrorBox,
  FilterBar,
  Filtro,
  NoSePudoLeer,
  Segmented,
  SkeletonBlock,
  SkeletonTable,
  Table,
  Td,
  Tr,
  formatDateTime,
  formatDay,
  formatUsd,
  formatVes,
  diaOperativo,
  hoyCaracas,
} from '@/components/ui'
import { FiltroFechas } from '@/components/FiltrosDeLista'
import { useResumenDelDinero } from '@/components/admin/caja/useResumenDelDinero'
import { FILTRO_DE_TIPOS, nombreDeAsiento, nombreDeCuenta } from '@/features/admin/contabilidad'
import { fetchLedgerEntries } from '@/features/admin/asientos'
import type { LedgerTransaction } from '@/features/admin/asientos'
import { construirCsv, csvDinero, csvInstante, descargarCsv } from '@/lib/csv'
import type { CsvColumn } from '@/lib/csv'
import { describeError } from '@/lib/supabase'

/** Cuántos asientos se piden. La pantalla avisa si se llega. */
const LIMITE = 200

/** Quién firma un asiento que no escribió nadie del equipo. */
const SIN_ACTOR = 'Proceso automático'

/** Los filtros del libro, tal como viajan en la URL. */
export type FiltrosLibro = {
  tipo?: string
  desde?: string
  hasta?: string
  /** La contraparte: una persona o un local, nunca los dos. */
  persona?: string
  local?: string
}

/**
 * El libro de asientos.
 *
 * Si la caja dice una cifra que no cuadra con el banco, la única forma de
 * saber por qué es bajar del saldo al asiento: el monto en bolívares a la tasa
 * del día del asiento (la cifra del extracto), el saldo de caja después de
 * cada asiento y el filtro por fecha y por contraparte.
 *
 * Los filtros viven en la URL: un enlace al libro de una persona en marzo se
 * puede mandar tal cual.
 */
export function Libro({
  filtros,
  onCambiar,
}: {
  filtros: FiltrosLibro
  onCambiar: (patch: FiltrosLibro) => void
}) {
  const entries = useQuery({
    queryKey: ['admin-ledger', filtros.tipo, filtros.desde, filtros.hasta, filtros.persona, filtros.local, LIMITE],
    queryFn: () =>
      fetchLedgerEntries({
        limit: LIMITE,
        type: filtros.tipo ?? null,
        from: filtros.desde ?? null,
        to: filtros.hasta ?? null,
        userId: filtros.persona ?? null,
        merchantId: filtros.local ?? null,
      }),
  })

  // La misma caja que Dinero, de la misma lectura.
  const resumen = useResumenDelDinero()

  const rows = entries.data ?? []
  const idContraparte = filtros.persona ?? filtros.local
  const nombreContraparte =
    rows.find((t) => t.counterpartyId === idContraparte)?.counterpartyName ??
    (filtros.persona ? 'Un paciente' : 'Una clínica')

  return (
    <>
      <FilterBar>
        <Filtro label="Tipo de asiento">
          <Segmented
            options={[...FILTRO_DE_TIPOS]}
            value={filtros.tipo ?? ''}
            onChange={(value) => onCambiar({ tipo: value || undefined })}
          />
        </Filtro>
        <FiltroFechas
          id="libro-fechas"
          label="Día operativo"
          desde={filtros.desde}
          hasta={filtros.hasta}
          max={diaOperativo()}
          onChange={(rango) => onCambiar(rango)}
        />
        {idContraparte && (
          <Filtro label="Contraparte">
            <button
              type="button"
              onClick={() => onCambiar({ persona: undefined, local: undefined })}
              className="flex h-panel-control-md items-center gap-2 rounded-panel-control bg-panel-control px-3 type-panel-control text-on-surface transition-colors hover:bg-shell-inset"
            >
              {nombreContraparte} <X size={14} aria-label="Quitar" />
            </button>
          </Filtro>
        )}
        <Button
          size="sm"
          variant="tonal"
          disabled={rows.length === 0}
          motivoApagado="No hay asientos que exportar."
          onClick={() => exportarCsv(rows)}
        >
          <Download size={14} /> Exportar CSV
        </Button>
      </FilterBar>

      <Card className="mb-6">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <span className="type-panel-body text-on-surface-variant">Dinero en caja según el libro</span>
          {resumen.isPending && <SkeletonBlock className="h-6 w-24" />}
          {resumen.isError && <NoSePudoLeer onReintentar={() => void resumen.refetch()} />}
          {resumen.data && (
            <span className="type-panel-figure text-on-surface">
              {formatUsd(resumen.data.cash.cash)}
            </span>
          )}
        </div>
      </Card>

      {entries.isPending && <SkeletonTable rows={8} columns={6} />}

      {entries.isError && (
        <ErrorBox title="No se pudo leer el libro" detail={describeError(entries.error)} />
      )}

      {entries.data?.length === 0 && (
        <EmptyState
          icon={<Landmark size={40} />}
          title="Ningún asiento con este filtro"
          description="El libro se llena solo: cada financiamiento, cada pago aprobado y cada transferencia a una clínica escribe aquí."
        />
      )}

      {rows.length > 0 && (
        <Table
          headers={[
            'Fecha',
            'Tipo',
            'Concepto',
            {
              label: 'Movimiento',
              info: 'El monto en bolívares solo aparece en los asientos que mueven caja, y va a la tasa del día operativo del asiento, no a la de hoy: es la cifra que tiene que aparecer en el extracto del banco.',
            },
            {
              label: 'Caja después',
              info: 'El saldo de la cuenta de caja justo después de ese asiento, acumulado desde el primer día y no desde la primera fila de la tabla. Filtrar no lo cambia.',
            },
            'Registrado por',
          ]}
        >
          {rows.map((t) => (
            <Tr key={t.transactionId}>
              {/* Arriba el día operativo; debajo, el instante en que se
                  escribió. Un asiento de las 3 a. m. es del día anterior. */}
              <Td className="whitespace-nowrap text-on-surface-variant">
                {formatDay(t.businessDate)}
                <span className="block type-panel-caption text-panel-muted">
                  {formatDateTime(t.createdAt)}
                </span>
              </Td>
              <Td className="whitespace-nowrap font-medium">{nombreDeAsiento(t.type)}</Td>
              <Td className="max-w-xs text-on-surface-variant">
                {t.memo ?? '—'}
                {t.counterpartyKind && t.counterpartyId && (
                  <button
                    type="button"
                    onClick={() =>
                      onCambiar(
                        t.counterpartyKind === 'persona'
                          ? { persona: t.counterpartyId ?? undefined, local: undefined }
                          : { local: t.counterpartyId ?? undefined, persona: undefined },
                      )
                    }
                    className="mt-0.5 block type-panel-caption text-on-surface underline decoration-panel-hairline-strong underline-offset-2 hover:decoration-on-surface"
                  >
                    {t.counterpartyName ?? 'Sin nombre'}
                  </button>
                )}
              </Td>
              <Td className="whitespace-nowrap">
                <div className="flex flex-col gap-0.5">
                  {t.lines.map((l, i) => (
                    <span key={i} className="type-panel-caption tabular-nums">
                      <span className="text-on-surface-variant">{nombreDeCuenta(l.account)}</span>{' '}
                      {/* El signo dice si es debe o haber: no es un estado, así que va sin color. */}
                      <span className="text-on-surface">
                        {l.debit > 0 ? `+${formatUsd(l.debit)}` : `−${formatUsd(l.credit)}`}
                      </span>
                    </span>
                  ))}
                  {t.amountVes !== null && (
                    <span className="type-panel-caption tabular-nums text-panel-muted">
                      {formatVes(t.amountVes)}
                      {t.fxRate !== null && ` · ${t.fxRate.toLocaleString('es-VE')} Bs/$`}
                    </span>
                  )}
                </div>
              </Td>
              <Td className="whitespace-nowrap tabular-nums text-on-surface">{formatUsd(t.cashBalance)}</Td>
              <Td className="text-on-surface-variant">{t.actorName ?? SIN_ACTOR}</Td>
            </Tr>
          ))}
        </Table>
      )}

      {rows.length >= LIMITE && (
        <p className="mt-4 type-panel-caption text-panel-muted">
          Solo se ven los {LIMITE} más recientes: acota las fechas para ver más.
        </p>
      )}
    </>
  )
}

type LineaCsv = { t: LedgerTransaction; l: LedgerTransaction['lines'][number]; i: number }

/**
 * El CSV del libro con el filtro puesto: una fila por LÍNEA del asiento, no
 * por asiento. Los bolívares, la tasa y el saldo son del asiento y van solo en
 * su primera línea: repetidos, sumar la columna contaría dos veces lo mismo.
 */
const COLUMNAS_CSV: Array<CsvColumn<LineaCsv>> = [
  { header: 'Dia operativo', value: ({ t }) => t.businessDate },
  { header: 'Fecha y hora (Caracas)', value: ({ t }) => csvInstante(t.createdAt) },
  { header: 'Tipo', value: ({ t }) => nombreDeAsiento(t.type) },
  { header: 'Concepto', value: ({ t }) => t.memo },
  { header: 'Contraparte', value: ({ t }) => t.counterpartyName },
  { header: 'Cuenta', value: ({ l }) => nombreDeCuenta(l.account) },
  { header: 'Debe', value: ({ l }) => csvDinero(l.debit) },
  { header: 'Haber', value: ({ l }) => csvDinero(l.credit) },
  { header: 'Bolivares', value: ({ t, i }) => (i === 0 ? csvDinero(t.amountVes) : '') },
  { header: 'Tasa', value: ({ t, i }) => (i === 0 ? csvDinero(t.fxRate, 6) : '') },
  { header: 'Caja despues', value: ({ t, i }) => (i === 0 ? csvDinero(t.cashBalance) : '') },
  { header: 'Registrado por', value: ({ t }) => t.actorName ?? SIN_ACTOR },
]

function exportarCsv(rows: LedgerTransaction[]) {
  const filas = rows.flatMap((t) => t.lines.map((l, i) => ({ t, l, i })))
  descargarCsv(`libro-${hoyCaracas()}`, construirCsv(COLUMNAS_CSV, filas))
}
