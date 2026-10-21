import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowRight } from 'lucide-react'

import {
  Badge,
  Button,
  Card,
  Checkbox,
  ConfirmDialog,
  Input,
  Meter,
  NoSePudoLeer,
  SOLO_SUPER_ADMIN,
  Seccion,
  SkeletonList,
  formatUsd,
} from '@/components/ui'
import { useToast } from '@/components/Toast'
import { fetchLevelConfig, saveLevelConfig } from '@/features/admin/ops'
import type { LevelConfig } from '@/features/admin/ops'
import { CLAVES_RIESGO, fetchUsoDelCupo } from '@/features/admin/riesgo/consultas'
import type { UsoDeNivel } from '@/features/admin/riesgo/credito'
import { useIsSuperAdmin } from '@/features/admin/role'
import { comoEntero } from '@/lib/busqueda'
import { formatoMontoEditable, leerMonto } from '@/lib/montos'
import { describeError } from '@/lib/supabase'

/*
 * Los niveles: el cupo de cada uno y lo que hace falta para llegar a él.
 *
 * Vivía como pestaña de Ajustes. Sale a su propia pantalla porque es trabajo
 * de Riesgo, no un ajuste que se toca una vez: se mira cada vez que se decide
 * si subir o bajar un cupo.
 *
 * Las cifras de cada nivel (personas, cupo ocupado, lo que falta por volver)
 * salen de `admin_credit_utilization`, que es la misma cuenta que frena una
 * compra y va en consumo, sin la Comisión Helios. Un nivel apagado no está en esa
 * cuenta.
 */

export function Niveles() {
  const niveles = useQuery({ queryKey: ['admin-levels'], queryFn: fetchLevelConfig })
  const uso = useQuery({ queryKey: CLAVES_RIESGO.usoDelCupo, queryFn: fetchUsoDelCupo })

  if (niveles.isError) {
    return (
      <Card>
        <NoSePudoLeer onReintentar={() => void niveles.refetch()} />
      </Card>
    )
  }
  if (!niveles.data) return <SkeletonList rows={3} />

  return (
    <Seccion
      titulo="Cupo y requisitos de cada nivel"
      info="Subir el límite de un nivel cambia al instante el disponible de toda la gente que está en él. Los requisitos son acumulativos: el estado automático sube a cada paciente al nivel más alto que cumple, y el gasto cuenta lo pagado, no lo financiado."
      controles={
        <Link
          to="/admin/metricas"
          search={{ vista: 'mora', sub: 'cupos' }}
          className="inline-flex items-center gap-1 type-panel-body text-on-surface-variant hover:text-on-surface"
        >
          Ver el uso del cupo por nivel <ArrowRight size={14} aria-hidden />
        </Link>
      }
    >
      <div className="flex flex-col gap-4">
        {niveles.data.map((nivel) => (
          <TarjetaNivel
            key={nivel.level}
            nivel={nivel}
            uso={uso.data?.niveles.find((u) => u.nivel === nivel.level) ?? null}
            usoEstado={uso.isError ? 'error' : uso.data ? 'listo' : 'cargando'}
            onReintentarUso={() => void uso.refetch()}
          />
        ))}
      </div>
    </Seccion>
  )
}

/**
 * Personas y cupo del nivel: una línea y el medidor de lo ocupado. El cupo es
 * consumo, sin la Comisión Helios: la comisión no entra en ninguna de estas cifras.
 */
function CifrasDelNivel({
  nivel,
  uso,
  estado,
  onReintentar,
}: {
  nivel: LevelConfig
  uso: UsoDeNivel | null
  estado: 'listo' | 'cargando' | 'error'
  onReintentar: () => void
}) {
  if (estado === 'error') return <NoSePudoLeer onReintentar={onReintentar} />
  if (estado === 'cargando') return <span className="type-panel-body text-panel-muted">…</span>
  if (!uso) {
    return (
      <span className="type-panel-body text-panel-muted">
        {nivel.isActive ? 'Sin datos de uso' : 'Apagado: no cuenta en el uso del cupo'}
      </span>
    )
  }
  return (
    <div className="flex flex-col gap-2">
      <span className="type-panel-body text-on-surface-variant">
        {uso.personas} {uso.personas === 1 ? 'paciente' : 'pacientes'} · {formatUsd(uso.ocupado)} de{' '}
        {formatUsd(uso.cupoTotal)} de cupo ocupado · {formatUsd(uso.exposicion)} por volver
      </span>
      {uso.cupoTotal > 0 && (
        <Meter
          valor={uso.ocupado}
          max={uso.cupoTotal}
          rotulo={`Cupo ocupado de ${nivel.label}: ${formatUsd(uso.ocupado)} de ${formatUsd(uso.cupoTotal)}`}
        />
      )}
    </div>
  )
}

/**
 * El motivo, escrito, de por qué no se puede guardar todavía. Son las mismas
 * reglas que `admin_set_level_config`: un nivel apagado puede tener límite
 * cero (así está el 5), uno activo no.
 */
function motivoParaNoGuardar(p: {
  esSuperAdmin: boolean
  limite: number | null
  gasto: number | null
  meses: number | undefined
  activo: boolean
}): string | undefined {
  if (!p.esSuperAdmin) return SOLO_SUPER_ADMIN
  if (p.limite === null || p.limite < 0) return 'El límite tiene que ser un monto válido.'
  if (p.activo && p.limite <= 0) return 'Un nivel activo necesita un límite mayor que cero.'
  if (p.gasto === null || p.gasto < 0) return 'El gasto requerido tiene que ser un monto válido.'
  if (p.meses === undefined) return 'La antigüedad tiene que ser un número entero de meses.'
  return undefined
}

function TarjetaNivel({
  nivel,
  uso,
  usoEstado,
  onReintentarUso,
}: {
  nivel: LevelConfig
  uso: UsoDeNivel | null
  usoEstado: 'listo' | 'cargando' | 'error'
  onReintentarUso: () => void
}) {
  const avisar = useToast()
  const client = useQueryClient()
  const esSuperAdmin = useIsSuperAdmin()

  // En formato de aquí: «1.125» vuelve leído como mil ciento veinticinco.
  const [limiteTexto, setLimiteTexto] = useState(formatoMontoEditable(nivel.monthlyLimitUsd))
  const [gastoTexto, setGastoTexto] = useState(formatoMontoEditable(nivel.requiredSpendUsd))
  const [mesesTexto, setMesesTexto] = useState(String(nivel.requiredMonths))
  const [activo, setActivo] = useState(nivel.isActive)
  const [confirmando, setConfirmando] = useState(false)

  const limite = leerMonto(limiteTexto)
  const gasto = leerMonto(gastoTexto)
  const meses = comoEntero(mesesTexto, { min: 0, max: 120 })

  const cambiado =
    limite !== nivel.monthlyLimitUsd ||
    gasto !== nivel.requiredSpendUsd ||
    meses !== nivel.requiredMonths ||
    activo !== nivel.isActive

  const motivo = motivoParaNoGuardar({ esSuperAdmin, limite, gasto, meses, activo })

  const guardar = useMutation({
    // El motivo del diálogo va a la bitácora (`level.configure`).
    mutationFn: (nota: string) =>
      saveLevelConfig({
        level: nivel.level,
        monthlyLimitUsd: limite ?? nivel.monthlyLimitUsd,
        requiredSpendUsd: gasto ?? nivel.requiredSpendUsd,
        requiredMonths: meses ?? nivel.requiredMonths,
        isActive: activo,
        label: nivel.label,
        note: nota,
      }),
    onSuccess: () => {
      setConfirmando(false)
      avisar(
        activo
          ? `${nivel.label} guardado con un cupo de ${formatUsd(limite ?? nivel.monthlyLimitUsd)}`
          : `${nivel.label} guardado y apagado: nadie nuevo llega a él`,
      )
      void client.invalidateQueries({ queryKey: ['admin-levels'] })
      void client.invalidateQueries({ queryKey: CLAVES_RIESGO.usoDelCupo })
      void client.invalidateQueries({ queryKey: ['admin-overview'] })
      // El límite cambia al instante el disponible de toda la gente del nivel.
      void client.invalidateQueries({ queryKey: ['admin-user'] })
      void client.invalidateQueries({ queryKey: ['admin-users'] })
    },
  })

  const personas = uso?.personas ?? nivel.userCount
  const deQuien = `${personas} ${personas === 1 ? 'paciente' : 'pacientes'}`

  return (
    <Card>
      {/* Solo se marca el apagado: activo es lo normal, y cinco pastillas
          verdes iguales no dicen nada. */}
      <div className="flex flex-wrap items-center gap-3">
        <h3 className="type-panel-section text-on-surface">{nivel.label}</h3>
        {!nivel.isActive && <Badge>Apagado</Badge>}
      </div>

      <div className="mt-3">
        <CifrasDelNivel nivel={nivel} uso={uso} estado={usoEstado} onReintentar={onReintentarUso} />
      </div>

      <div className="mt-4 grid grid-cols-1 gap-4 md:grid-cols-3">
        <Input
          id={`limite-${nivel.level}`}
          label="Límite ($)"
          value={limiteTexto}
          onChange={setLimiteTexto}
          inputMode="decimal"
          error={limite === null || limite < 0 || (activo && limite <= 0)}
        />
        <Input
          id={`gasto-${nivel.level}`}
          label="Gasto pagado requerido ($)"
          value={gastoTexto}
          onChange={setGastoTexto}
          inputMode="decimal"
          error={gasto === null || gasto < 0}
        />
        <Input
          id={`meses-${nivel.level}`}
          label="Meses de antigüedad"
          value={mesesTexto}
          onChange={setMesesTexto}
          inputMode="numeric"
          error={meses === undefined}
        />
      </div>

      {/* Casilla y no interruptor: el estado se guarda con el resto del nivel,
          al pulsar «Guardar» y confirmar. */}
      <div className="mt-4 flex flex-wrap items-start justify-between gap-3">
        {/* `pt-2`: a la altura del centro del botón, que puede llevar su
            motivo colgando debajo. */}
        <div className="pt-2">
          <Checkbox
            id={`activo-${nivel.level}`}
            label="Nivel activo"
            checked={activo}
            onChange={setActivo}
          />
        </div>

        <Button
          size="sm"
          variant="tonal"
          // Sin cambios el botón se apaga sin más: no hay nada que explicar.
          disabled={motivo !== undefined || !cambiado || guardar.isPending}
          motivoApagado={guardar.isPending ? undefined : motivo}
          title={!cambiado ? 'No se ha cambiado nada' : undefined}
          onClick={() => setConfirmando(true)}
        >
          {guardar.isPending ? 'Guardando…' : 'Guardar'}
        </Button>
      </div>

      {/* Tocar un límite es cambiar el cupo de toda la gente del nivel en ese
          mismo instante: se confirma con motivo y palabra, y el resumen dice a
          cuántos afecta y cuánto deben hoy. */}
      {confirmando && (
        <ConfirmDialog
          title={`Cambiar ${nivel.label}`}
          nivel="critico"
          summary={
            limite !== nivel.monthlyLimitUsd
              ? `Vas a cambiar el cupo de ${nivel.label} de ${formatUsd(nivel.monthlyLimitUsd)} a ${formatUsd(
                  limite ?? nivel.monthlyLimitUsd,
                )}. Eso cambia en este momento el cupo de ${deQuien}${
                  uso ? `, que hoy ocupan ${formatUsd(uso.ocupado)} y deben devolver ${formatUsd(uso.exposicion)} de financiamiento (sin comisión)` : ''
                }.`
              : `Vas a cambiar los requisitos de ${nivel.label}, donde hay ${deQuien}${
                  uso ? ` que deben devolver ${formatUsd(uso.exposicion)} de financiamiento (sin comisión)` : ''
                }.`
          }
          detail={
            <ul className="flex flex-col gap-1 type-panel-body text-on-surface-variant">
              <li>
                Cupo: {formatUsd(nivel.monthlyLimitUsd)} → {formatUsd(limite ?? nivel.monthlyLimitUsd)}
              </li>
              <li>
                Gasto pagado: {formatUsd(nivel.requiredSpendUsd)} →{' '}
                {formatUsd(gasto ?? nivel.requiredSpendUsd)}
              </li>
              <li>
                Antigüedad: {nivel.requiredMonths} → {meses ?? nivel.requiredMonths} meses
              </li>
              <li>
                Estado: {nivel.isActive ? 'activo' : 'apagado'} → {activo ? 'activo' : 'apagado'}
              </li>
            </ul>
          }
          reasonLabel="Por qué se cambia"
          confirmLabel="Guardar el nivel"
          busy={guardar.isPending}
          error={guardar.isError ? describeError(guardar.error) : undefined}
          onConfirm={(nota) => guardar.mutate(nota)}
          onClose={() => setConfirmando(false)}
        />
      )}
    </Card>
  )
}
