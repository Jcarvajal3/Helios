import { BloqueoDeLaCuenta } from '@/components/UserBlockCard'
import type { BloqueoDeCuenta } from '@/components/UserBlockCard'
import {
  Callout,
  Card,
  Meter,
  Seccion,
  Table,
  Td,
  Tr,
  formatDateTime,
  formatUsd,
} from '@/components/ui'
import type { LevelConfig } from '@/features/admin/ops'
import type { UserDetail } from '@/features/admin/users'

/**
 * La pestaña Resumen: lo que frena la cuenta, el camino al siguiente nivel,
 * y los cambios de nivel.
 *
 * Lo que debe, lo que puede gastar y lo que falta para liberar el cupo ya
 * están en el carril, a la vista desde cualquier pestaña: aquí no se repiten.
 * Las acciones sobre la cuenta, tampoco: van en el carril y en el «⋯».
 */
export function PestanaResumen({
  user,
  niveles,
  bloqueo,
}: {
  user: UserDetail
  /** Los niveles activos. `undefined` mientras se leen o si no se pudieron leer. */
  niveles: Array<LevelConfig> | undefined
  bloqueo: BloqueoDeCuenta
}) {
  const siguiente = niveles?.find((l) => l.level === user.level + 1)
  const vacia =
    !user.isBlacklisted &&
    bloqueo.estado !== 'abierto' &&
    bloqueo.estado !== 'error' &&
    bloqueo.anteriores.length === 0 &&
    !siguiente &&
    user.levelChanges.length === 0

  return (
    <>
      {user.isBlacklisted && (
        <Callout tone="error" titulo="Marca interna">
          {user.blacklistReason ?? 'Sin motivo escrito.'} Si una clínica vuelve a registrar
          esta cédula, no se le podrá financiar.
        </Callout>
      )}

      <BloqueoDeLaCuenta bloqueo={bloqueo} />

      {siguiente && <SiguienteNivel user={user} siguiente={siguiente} />}

      {user.levelChanges.length > 0 && (
        <Seccion titulo="Cambios de nivel">
          <Table headers={['Cuándo', 'Cambio', 'Por qué', 'Nota']}>
            {user.levelChanges.map((l) => (
              <Tr key={`${l.createdAt}-${l.toLevel}`}>
                <Td className="whitespace-nowrap">{formatDateTime(l.createdAt)}</Td>
                <Td className="tabular-nums">
                  {l.fromLevel} → {l.toLevel}
                </Td>
                <Td className="text-on-surface-variant">{l.reason}</Td>
                <Td className="type-panel-caption text-on-surface-variant">{l.note ?? '—'}</Td>
              </Tr>
            ))}
          </Table>
        </Seccion>
      )}

      {vacia && (
        <p className="type-panel-body text-panel-muted">
          Sin marcas, sin bloqueos y sin cambios de nivel todavía.
        </p>
      )}
    </>
  )
}

// ── Siguiente nivel ────────────────────────────────────────────────────────

/**
 * Lo que le falta para subir, en dos medidores: el consumo pagado y la
 * antigüedad que pide el nivel siguiente. Era un párrafo con cuatro cifras
 * que había que comparar de cabeza.
 */
function SiguienteNivel({ user, siguiente }: { user: UserDetail; siguiente: LevelConfig }) {
  const meses = mesesDesde(user.createdAt)
  // FINANCED, como el motor de niveles (level_standing): el consumo de sus
  // cuotas pagadas. `debt.paidUsd` lleva el fee dentro y lo inflaba un 23 %.
  const pagado =
    user.debt.paidFinancedUsd ??
    user.installments.filter((i) => i.status === 'paid').reduce((s, i) => s + i.financedUsd, 0)

  return (
    <Seccion
      titulo="Siguiente nivel"
      info="Lo que pide el nivel siguiente: un financiamiento pagado (sin comisión, la suma del financiamiento de sus cuotas pagadas) y unos meses desde que pidió el código."
    >
      <Card className="flex flex-col gap-4">
        <p className="type-panel-body text-on-surface">
          {siguiente.label}: {formatUsd(siguiente.monthlyLimitUsd)} de cupo
        </p>
        {siguiente.requiredSpendUsd > 0 && (
          <Progreso
            rotulo="Financiamiento pagado (sin comisión)"
            cifra={`${formatUsd(pagado)} de ${formatUsd(siguiente.requiredSpendUsd)}`}
            valor={pagado}
            max={siguiente.requiredSpendUsd}
          />
        )}
        {siguiente.requiredMonths > 0 && (
          <Progreso
            rotulo="Antigüedad"
            cifra={`${meses === 0 ? 'Menos de un mes' : `${meses} ${meses === 1 ? 'mes' : 'meses'}`} de ${
              siguiente.requiredMonths
            }`}
            valor={meses}
            max={siguiente.requiredMonths}
          />
        )}
      </Card>
    </Seccion>
  )
}

function Progreso({
  rotulo,
  cifra,
  valor,
  max,
}: {
  rotulo: string
  cifra: string
  valor: number
  max: number
}) {
  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex items-baseline justify-between gap-3">
        <span className="type-panel-label text-on-surface-variant">{rotulo}</span>
        <span className="type-panel-body text-on-surface">{cifra}</span>
      </div>
      <Meter valor={valor} max={max} rotulo={`${rotulo}: ${cifra}`} />
    </div>
  )
}

function mesesDesde(iso: string): number {
  const desde = new Date(iso).getTime()
  return Math.max(0, Math.floor((Date.now() - desde) / (30 * 24 * 3600 * 1000)))
}

