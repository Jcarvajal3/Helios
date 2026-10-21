import { useState } from 'react'
import { Link } from '@tanstack/react-router'

import { formatUsd } from '@/components/ui'
import { desgloseCorto } from '@/features/admin/metricas/cohortes/desglose'
import { pastillaDeSemana, tramosDeCobro } from '@/features/admin/metricas/cohortes/estados'
import { pct } from '@/features/admin/metricas/cohortes/frases'
import { rotuloDeSemana, semanaLarga } from '@/features/admin/metricas/cohortes/semanas'
import type { Cohorte } from '@/features/admin/metricas/cohortes/tipos'
import { BarraDeEstados } from '@/components/admin/metricas/cohortes/BarraDeEstados'
import { PastillaDeEstado } from '@/components/admin/metricas/cohortes/PastillaDeEstado'

/**
 * Una semana de la lista: lo que hay que cobrar de ella (la cuota 1 + la 2,
 * con la Comisión Helios dentro) con su desglose debajo en pequeño, una barra
 * con lo cobrado, lo vencido y lo por vencer, la pastilla de en qué está y
 * qué parte ya se cobró. Es un enlace: elegirla enseña esa semana en Por
 * cobrar › Cohortes, con el mismo local.
 */
export function FilaDeSemana({
  cohorte,
  activa,
  hoy,
  local,
  nombre,
}: {
  cohorte: Cohorte
  activa: boolean
  hoy: string
  local: string | null
  /** El nombre de la cohorte (A1, A2…); `null` mientras no se sabe cuál fue la primera. */
  nombre: string | null
}) {
  const [enfocada, setEnfocada] = useState(false)
  const a = cohorte.aCobrar
  const cobrado = a.cobradoPct === null ? '—' : pct(a.cobradoPct)

  return (
    <Link
      to="/admin/cobranza"
      search={{ vista: 'semana', cohorte: cohorte.semana, local: local ?? undefined }}
      aria-current={activa ? 'true' : undefined}
      aria-label={`${nombre ? `Cohorte ${nombre}, semana` : 'Semana'} ${semanaLarga(cohorte.semana)}: hay que cobrar ${formatUsd(a.importe.payableUsd)} (${desgloseCorto(a.importe)}); cobrado el ${cobrado}`}
      // Solo con el teclado: al pulsar con el ratón el enlace se queda con
      // el foco, y el globo taparía la lista después de elegir.
      onFocus={(e) => setEnfocada(e.currentTarget.matches(':focus-visible'))}
      onBlur={() => setEnfocada(false)}
      className={`flex flex-col gap-2 rounded-panel-control border px-3 py-3 transition-colors duration-[var(--transition-fast)] ${
        activa
          ? 'border-panel-hairline-strong bg-panel-raised'
          : 'border-transparent hover:bg-panel-raised'
      }`}
    >
      <span className="flex items-baseline gap-2">
        {nombre && (
          <span className="rounded-panel-control bg-panel-control px-1.5 py-0.5 type-panel-caption font-bold tabular-nums text-on-surface">
            {nombre}
          </span>
        )}
        <span className="type-panel-body font-bold text-on-surface">{rotuloDeSemana(cohorte.semana)}</span>
        <span className="ml-auto type-panel-body font-semibold tabular-nums text-on-surface">
          {formatUsd(a.importe.payableUsd)}
        </span>
      </span>
      <span className="-mt-1.5 self-end type-panel-caption tabular-nums text-panel-muted">
        {desgloseCorto(a.importe)}
      </span>
      <BarraDeEstados
        tramos={tramosDeCobro(a)}
        rotulo="Lo que hay que cobrar de la semana, por estado"
        titulo={`Semana ${rotuloDeSemana(cohorte.semana)}`}
        total={a.importe}
        enfocable={false}
        senaladaDesdeFuera={enfocada}
      />
      <span className="flex items-center gap-2">
        <PastillaDeEstado pastilla={pastillaDeSemana(cohorte, hoy)} />
        <span className="ml-auto type-panel-caption text-panel-muted">cobrado {cobrado}</span>
      </span>
    </Link>
  )
}
