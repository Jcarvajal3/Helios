import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { ChevronDown, ChevronRight, Landmark } from 'lucide-react'

import {
  Badge,
  Button,
  Callout,
  EmptyState,
  Seccion,
  SkeletonList,
  formatDay,
  formatMoneda,
  formatUsd,
} from '@/components/ui'
import { RegistrarTransferencia } from '@/components/admin/caja/RegistrarTransferencia'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import { fetchMerchantSettlements, fetchMerchantUpcomingSettlements } from '@/features/admin/api'
import type { Settlement } from '@/features/admin/api'
import { partirPorMotivo } from '@/features/admin/clinicas/clinicas'
import { MOTIVO_DE_LIQUIDACION } from '@/features/admin/liquidaciones'

/** Cuántas líneas se enseñan de un día de pago antes de pedir ver el resto. */
const LINEAS_VISIBLES = 8

/** Por debajo de medio céntimo, una liquidación está pagada. */
const SALDADA = 0.005

type Grupo = {
  runDate: string
  lineas: Settlement[]
  /** Lo que falta de las líneas del grupo. */
  pendienteUsd: number
  /** Ya debió pagarse un día que pasó. */
  atrasado: boolean
  /** Entra en el pago de hoy. */
  esteCierre: boolean
}

/**
 * Lo que se le debe a un local, AGRUPADO POR DÍA DE PAGO, y desde aquí se le
 * paga.
 *
 * Desde el 2026-10-06 se paga a diario: cada liquidación, el día siguiente a
 * su vencimiento (la consulta a los días 8 y 15, la comisión de la secretaria
 * junto con la primera mitad). La unidad de trabajo es el día de pago
 * (el «cierre» de la base): nadie paga «la cuota de la orden 1187», se paga un
 * día. Cada uno lleva su estado, su total y una casilla que marca el bloque
 * entero; vienen marcados los atrasados y el de hoy, que es lo que hay que
 * transferir.
 *
 * Si se llega desde un día de pago concreto (`cierre`), se enseña ese y nada
 * más, con TODAS sus líneas: también las ya pagadas. Un pago saldado tiene que
 * poder contar qué se pagó, no decir que no queda nada.
 *
 * Los días que vienen llevan también las mitades de la consulta por vencer
 * (`porVencer`): todavía no son liquidaciones, pero sin ellas un día futuro
 * salía solo con la comisión de la secretaria. Suman en su día y no se pueden
 * marcar: se pagan cuando el cron las crea, no antes.
 */
export function LiquidacionesDelLocal({
  merchantId,
  merchantName,
  nextRunDate,
  cierre,
  onVerTodos,
}: {
  merchantId: string
  merchantName: string
  /** El día del próximo pago (hoy), según el servidor. */
  nextRunDate: string | null
  cierre: string | null
  onVerTodos: () => void
}) {
  const settlements = useQuery({
    queryKey: ['settlements', merchantId, cierre ?? 'abiertas'],
    // Con el día de pago, el servidor trae las de ese día en cualquier estado.
    queryFn: () => fetchMerchantSettlements(merchantId, cierre ?? undefined),
  })
  const porVencer = useQuery({
    queryKey: ['settlements', merchantId, 'por-vencer'],
    queryFn: () => fetchMerchantUpcomingSettlements(merchantId),
  })

  const [abiertos, setAbiertos] = useState<Set<string> | null>(null)
  const [completos, setCompletos] = useState<Set<string>>(new Set())
  // Hasta que alguien toque una casilla, manda lo marcado por defecto.
  const [tocado, setTocado] = useState<Set<string> | null>(null)

  const lineas = useMemo(
    () =>
      [...(settlements.data ?? []), ...(porVencer.data ?? [])].filter((s) =>
        cierre ? s.runDate === cierre : s.pendingUsd > SALDADA,
      ),
    [settlements.data, porVencer.data, cierre],
  )
  // Lo que se puede marcar y pagar: lo que ya es liquidación.
  const abiertas = useMemo(() => lineas.filter((s) => !s.porVencer && s.pendingUsd > SALDADA), [lineas])

  const grupos = useMemo<Grupo[]>(() => {
    const porCierre = new Map<string, Settlement[]>()
    for (const s of lineas) porCierre.set(s.runDate, [...(porCierre.get(s.runDate) ?? []), s])

    return [...porCierre.entries()]
      .map(([runDate, deLaSemana]) => ({
        runDate,
        lineas: deLaSemana,
        pendienteUsd: deLaSemana.reduce((sum, s) => sum + s.pendingUsd, 0),
        atrasado: nextRunDate ? runDate < nextRunDate : false,
        esteCierre: nextRunDate ? runDate === nextRunDate : deLaSemana.every((s) => s.inNextRun),
      }))
      .sort((a, b) => a.runDate.localeCompare(b.runDate))
  }, [lineas, nextRunDate])

  const porDefecto = useMemo(
    () =>
      new Set(
        grupos
          .filter((g) => g.atrasado || g.esteCierre)
          .flatMap((g) => g.lineas.filter((s) => !s.porVencer && s.pendingUsd > SALDADA).map((s) => s.id)),
      ),
    [grupos],
  )
  const marcadas = tocado ?? porDefecto

  // Lo que FALTA de cada línea, no su monto: una liquidación pagada a medias
  // debe el resto, y sumar el monto entero pagaría dos veces lo cobrado.
  const totalMarcado = abiertas
    .filter((s) => marcadas.has(s.id))
    .reduce((sum, s) => sum + s.pendingUsd, 0)
  // Lo marcado en consultas y comisiones del personal: lo que falta de cada una.
  const desgloseMarcado = partirPorMotivo(
    abiertas.filter((s) => marcadas.has(s.id)).map((s) => ({ reason: s.reason, amountUsd: s.pendingUsd })),
  )

  function alternar(ids: string[], marcar: boolean) {
    const siguiente = new Set(marcadas)
    for (const id of ids) {
      if (marcar) siguiente.add(id)
      else siguiente.delete(id)
    }
    setTocado(siguiente)
  }

  function alternarAbierto(runDate: string, abiertoAhora: boolean) {
    setAbiertos((prev) => {
      const siguiente = new Set(prev ?? (abiertoAhora ? [runDate] : []))
      if (siguiente.has(runDate)) siguiente.delete(runDate)
      else siguiente.add(runDate)
      return siguiente
    })
  }

  if (settlements.isPending) return <SkeletonList rows={3} />

  if (settlements.isError) {
    return (
      <SeccionSinLeer
        titulo="No se pudieron cargar las liquidaciones"
        error={settlements.error}
        onReintentar={() => void settlements.refetch()}
      />
    )
  }

  if (lineas.length === 0) {
    return (
      <Seccion titulo="Por día de pago">
        {cierre && <AvisoDelCierre cierre={cierre} saldado={false} onVerTodos={onVerTodos} />}
        <EmptyState
          icon={<Landmark size={40} />}
          title={cierre ? 'Esta clínica no tiene liquidaciones ese día' : 'No se le debe nada'}
          description={
            cierre
              ? 'Ninguna de sus liquidaciones tocaba pagarse ese día.'
              : 'No queda ninguna liquidación pendiente con esta clínica.'
          }
        />
      </Seccion>
    )
  }

  // Un día que solo trae mitades por vencer no está saldado: todavía no toca.
  const saldado = abiertas.length === 0 && !lineas.some((s) => s.porVencer)

  return (
    <Seccion
      titulo="Por día de pago"
      info="Cada liquidación se paga el día siguiente a su vencimiento (la consulta, a los 8 y a los 15 días; la comisión de la secretaria, junto con la primera mitad). Se paga un día, no una cuota suelta: cada día de pago lleva su estado, su total y una casilla que lo marca entero. Vienen marcados los atrasados y el de hoy."
      controles={
        <span className="type-panel-caption text-panel-muted">
          {grupos.length} {grupos.length === 1 ? 'día de pago' : 'días de pago'} · {lineas.length}{' '}
          {lineas.length === 1 ? 'liquidación' : 'liquidaciones'}
        </span>
      }
    >
      {cierre && <AvisoDelCierre cierre={cierre} saldado={saldado} onVerTodos={onVerTodos} />}

      <div className="flex flex-col gap-2">
        {grupos.map((grupo) => {
          const pendientesDelGrupo = grupo.lineas.filter((s) => !s.porVencer && s.pendingUsd > SALDADA)
          const idsPendientes = pendientesDelGrupo.map((s) => s.id)
          const marcadasDelGrupo = idsPendientes.filter((id) => marcadas.has(id)).length
          const todas = idsPendientes.length > 0 && marcadasDelGrupo === idsPendientes.length
          const algunas = marcadasDelGrupo > 0 && !todas
          const abierto =
            abiertos === null
              ? grupo.runDate === cierre || grupos.length === 1
              : abiertos.has(grupo.runDate)
          const completo = completos.has(grupo.runDate)
          const visibles = completo ? grupo.lineas : grupo.lineas.slice(0, LINEAS_VISIBLES)
          const ocultas = grupo.lineas.length - visibles.length

          return (
            <div
              key={grupo.runDate}
              className="overflow-hidden rounded-panel-card border border-panel-hairline bg-panel-card"
            >
              {/* Marcar un día de pago entero es lo que se hace siempre;
                  abrirlo es lo raro. Por eso son dos objetivos distintos. */}
              <div className="flex items-center gap-3 p-3">
                {/* Casilla cruda y no `Checkbox` del kit: necesita el estado
                    «a medias» (`indeterminate`), que el kit no tiene. */}
                <input
                  type="checkbox"
                  checked={todas}
                  disabled={idsPendientes.length === 0}
                  ref={(el) => {
                    if (el) el.indeterminate = algunas
                  }}
                  onChange={() => alternar(idsPendientes, !todas)}
                  aria-label={`Marcar el pago del ${formatDay(grupo.runDate)}`}
                  className="size-4 shrink-0 accent-on-surface disabled:opacity-30"
                />

                <button
                  type="button"
                  onClick={() => alternarAbierto(grupo.runDate, abierto)}
                  aria-expanded={abierto}
                  className="flex flex-1 items-center gap-3 text-left"
                >
                  {abierto ? (
                    <ChevronDown size={16} className="shrink-0 text-on-surface-variant" aria-hidden />
                  ) : (
                    <ChevronRight size={16} className="shrink-0 text-on-surface-variant" aria-hidden />
                  )}

                  <span className="flex-1">
                    <span className="flex flex-wrap items-center gap-2">
                      <span className="type-panel-body font-semibold text-on-surface">
                        Pago del {formatDay(grupo.runDate)}
                      </span>
                      <EstadoDelGrupo grupo={grupo} />
                    </span>
                    <span className="block type-panel-caption text-on-surface-variant">
                      {grupo.lineas.length}{' '}
                      {grupo.lineas.length === 1 ? 'liquidación' : 'liquidaciones'}
                      {algunas && ` · ${marcadasDelGrupo} marcadas`}
                      {(() => {
                        const partes = partirPorMotivo(
                          grupo.lineas.map((s) => ({ reason: s.reason, amountUsd: s.pendingUsd })),
                        )
                        return partes.comisionesUsd > 0
                          ? ` · Consultas ${formatUsd(partes.consultasUsd)} + Comisiones del personal ${formatUsd(partes.comisionesUsd)}`
                          : ''
                      })()}
                    </span>
                  </span>

                  <span className="shrink-0 type-panel-section tabular-nums text-on-surface">
                    {formatUsd(grupo.pendienteUsd)}
                  </span>
                </button>
              </div>

              {abierto && (
                <div className="flex flex-col gap-1 border-t border-panel-hairline px-3 pb-3 pt-2">
                  {visibles.map((s) => (
                    <LineaLiquidacion
                      key={s.id}
                      settlement={s}
                      checked={!s.porVencer && marcadas.has(s.id)}
                      onToggle={() => alternar([s.id], !marcadas.has(s.id))}
                    />
                  ))}

                  {ocultas > 0 && (
                    <Button
                      variant="text"
                      size="sm"
                      onClick={() => setCompletos((prev) => new Set(prev).add(grupo.runDate))}
                    >
                      Ver las {ocultas} restantes
                    </Button>
                  )}
                </div>
              )}
            </div>
          )
        })}
      </div>

      {abiertas.length > 0 && (
        <RegistrarTransferencia
          merchantId={merchantId}
          merchantName={merchantName}
          settlementIds={[...marcadas]}
          lineas={abiertas.filter((s) => marcadas.has(s.id))}
          totalUsd={totalMarcado}
          desglose={desgloseMarcado}
          onRegistrado={() => setTocado(null)}
        />
      )}
    </Seccion>
  )
}

/** Por qué se ve un solo día de pago, con la salida al lado. */
function AvisoDelCierre({
  cierre,
  saldado,
  onVerTodos,
}: {
  cierre: string
  saldado: boolean
  onVerTodos: () => void
}) {
  return (
    <Callout
      tone="info"
      titulo={`Solo el pago del ${formatDay(cierre)}`}
      accion={
        <Button variant="tonal" size="sm" onClick={onVerTodos}>
          Ver todo lo que se le debe
        </Button>
      }
    >
      {saldado ? 'Ya está saldado: estas son las liquidaciones que se le pagaron.' : undefined}
    </Callout>
  )
}

function EstadoDelGrupo({ grupo }: { grupo: Grupo }) {
  if (grupo.pendienteUsd <= SALDADA) {
    return (
      <Badge tone="success" icono>
        Saldado
      </Badge>
    )
  }
  if (grupo.atrasado) {
    return (
      <Badge tone="error" icono>
        Atrasado
      </Badge>
    )
  }
  if (grupo.esteCierre) {
    return (
      <Badge tone="warning" icono>
        Toca pagar
      </Badge>
    )
  }
  return <Badge>Por llegar</Badge>
}

/**
 * Una liquidación dentro de su día de pago: qué se devengó, de qué orden y cuánto
 * falta. En una pagada a medias, el monto original va al lado en pequeño; en
 * una de una orden en euros, lo que es en euros. Ni una ya pagada ni una mitad
 * por vencer se pueden marcar.
 */
function LineaLiquidacion({
  settlement,
  checked,
  onToggle,
}: {
  settlement: Settlement
  checked: boolean
  onToggle: () => void
}) {
  const pagada = settlement.pendingUsd <= SALDADA
  const aMedias = !pagada && settlement.paidUsd > SALDADA
  const porVencer = settlement.porVencer === true
  const bloqueada = pagada || porVencer

  return (
    <label
      className={`flex items-center gap-3 rounded-panel-control px-2 py-2 ${
        bloqueada ? '' : 'cursor-pointer hover:bg-panel-raised'
      }`}
    >
      {/* Cruda porque la fila entera es su rótulo, con el monto a la derecha:
          el `Checkbox` del kit pone su propio rótulo al lado. */}
      <input
        type="checkbox"
        checked={!bloqueada && checked}
        disabled={bloqueada}
        title={porVencer ? 'Se podrá pagar cuando venza la cuota del paciente' : undefined}
        onChange={onToggle}
        className="size-4 shrink-0 accent-on-surface disabled:opacity-30"
      />
      <span className="flex-1 type-panel-body text-on-surface">
        {MOTIVO_DE_LIQUIDACION[settlement.reason]}
        {settlement.orderNumber != null && (
          <span className="text-on-surface-variant"> · orden #{settlement.orderNumber}</span>
        )}
        <span className="ml-2 type-panel-caption text-on-surface-variant">
          vence el {formatDay(settlement.dueDate)}
        </span>
      </span>
      {pagada && (
        <Badge tone="success" icono>
          Pagada
        </Badge>
      )}
      {aMedias && <Badge>A medias</Badge>}
      {porVencer && <Badge>Por vencer</Badge>}
      <span className="shrink-0 text-right">
        <span className="font-semibold tabular-nums text-on-surface">
          {formatUsd(pagada ? settlement.amountUsd : settlement.pendingUsd)}
        </span>
        {aMedias && (
          <span className="block type-panel-caption tabular-nums text-on-surface-variant">
            de {formatUsd(settlement.amountUsd)}
          </span>
        )}
        {/* Una de una orden en euros se paga a la tasa del euro: lo que es en
            euros, al lado, que es lo que se pasa a bolívares. */}
        {settlement.currency === 'EUR' && (
          <span className="block type-panel-caption tabular-nums text-on-surface-variant">
            cobrada en {formatMoneda(pagada ? settlement.amountCur : settlement.pendingCur, 'EUR')}
          </span>
        )}
      </span>
    </label>
  )
}
