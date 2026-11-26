import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'

import {
  Button,
  Callout,
  Card,
  ConfirmDialog,
  ErrorBox,
  Input,
  SOLO_SUPER_ADMIN,
  Seccion,
  Segmented,
  SkeletonList,
  formatDateTime,
  formatUsd,
} from '@/components/ui'
import { useIsSuperAdmin } from '@/features/admin/role'
import { consultaAjustes, guardarAjustes, mensajeDeError } from '@/features/lab/admin'
import type { AjustesLab as Ajustes } from '@/features/lab/admin'
import type { ModoLab } from '@/features/lab/tipos'
import { formatoMontoEditable, leerMonto } from '@/lib/montos'

import { useEscritura } from '../muestras/comun'

const ROTULO_MODO: Record<ModoLab, string> = {
  apagado: 'Apagado',
  prueba: 'Solo clínicas de prueba',
  todos: 'Todos',
}

function explicacion(modo: ModoLab, clinicas: number): string {
  if (modo === 'apagado') return 'Ningún médico ve Helios Lab en su panel.'
  if (modo === 'prueba') {
    return `Solo ${clinicas === 1 ? 'la clínica' : `las ${clinicas} clínicas`} marcadas como de prueba ven Helios Lab.`
  }
  return 'Todos los médicos ven Helios Lab en su panel y pueden registrar muestras.'
}

export function AjustesLab() {
  const q = useQuery(consultaAjustes())
  if (q.isPending) return <SkeletonList rows={3} />
  if (q.isError) return <ErrorBox title="No se pudieron leer los ajustes" detail={mensajeDeError(q.error)} />
  return <Formulario ajustes={q.data} />
}

function Formulario({ ajustes }: { ajustes: Ajustes }) {
  const esSuper = useIsSuperAdmin()
  const [modo, setModo] = useState<ModoLab>(ajustes.modo)
  const [cargo, setCargo] = useState(formatoMontoEditable(ajustes.cargoHeliosUsd))
  const [confirmando, setConfirmando] = useState(false)

  const monto = leerMonto(cargo)
  const cargoValido = monto !== null && monto >= 0
  const sucio = modo !== ajustes.modo || (cargoValido && monto !== ajustes.cargoHeliosUsd)

  const guardar = useEscritura(
    () => guardarAjustes({ modo, cargoHeliosUsd: monto ?? ajustes.cargoHeliosUsd }),
    'Ajustes guardados.',
    () => setConfirmando(false),
  )

  function alGuardar() {
    if (modo === 'todos' && ajustes.modo !== 'todos') setConfirmando(true)
    else guardar.mutate(undefined)
  }

  return (
    <div className="flex max-w-3xl flex-col gap-8">
      {!esSuper && (
        <Callout tone="info" titulo="Solo lectura">
          Solo el super admin puede cambiar estos ajustes.
        </Callout>
      )}

      <Seccion
        titulo="Helios Lab en el panel del médico"
        info="Es el interruptor general: nace apagado. Con «Solo clínicas de prueba» lo ven únicamente las clínicas marcadas como de prueba."
      >
        <Card className="flex flex-col gap-4">
          <Segmented
            etiqueta="Quién ve Helios Lab"
            options={(['apagado', 'prueba', 'todos'] as const).map((m) => ({ value: m, label: ROTULO_MODO[m] }))}
            value={modo}
            onChange={(m) => esSuper && setModo(m)}
          />
          <p className="type-panel-body text-on-surface-variant">{explicacion(modo, ajustes.clinicasDePrueba)}</p>
          <p className="type-panel-caption text-panel-muted">
            Clínicas de prueba hoy: {ajustes.clinicasDePrueba}
            {ajustes.modo !== modo && ` · Ahora mismo está en «${ROTULO_MODO[ajustes.modo]}»`}
          </p>
          {modo === 'todos' && ajustes.modo !== 'todos' && (
            <Callout tone="warning" titulo="Esto lo activa para todos los médicos">
              Todas las clínicas verán Helios Lab y podrán registrar muestras reales con cobro al paciente.
            </Callout>
          )}
        </Card>
      </Seccion>

      <Seccion
        titulo="Cargo Helios por examen"
        info="Lo que Helios suma al precio de cada examen, en dólares. Cada muestra guarda el cargo del momento en que se registró: cambiarlo no toca las muestras anteriores."
      >
        <Card className="flex flex-col gap-3">
          <Input
            id="lab-cargo"
            label="Cargo Helios (USD)"
            value={cargo}
            onChange={setCargo}
            inputMode="decimal"
            error={cargo.trim() !== '' && !cargoValido}
            hint="Aplica a las muestras nuevas."
            className="w-48"
          />
          <p className="type-panel-caption text-panel-muted">
            Ahora: {formatUsd(ajustes.cargoHeliosUsd)}
            {ajustes.updatedAt && ` · Último cambio ${formatDateTime(ajustes.updatedAt)}`}
          </p>
        </Card>
      </Seccion>

      {guardar.mensaje && !confirmando && <ErrorBox title="No se pudo guardar" detail={guardar.mensaje} />}
      <div>
        <Button
          size="md"
          disabled={!esSuper || !sucio || !cargoValido || guardar.isPending}
          motivoApagado={!esSuper ? SOLO_SUPER_ADMIN : undefined}
          onClick={alGuardar}
        >
          Guardar ajustes
        </Button>
      </div>

      {confirmando && (
        <ConfirmDialog
          title="Activar Helios Lab para todos"
          summary="Vas a mostrarle Helios Lab a todos los médicos. Desde ese momento pueden registrar muestras y cobrarle al paciente. ¿Seguro que la prueba terminó bien?"
          nivel="critico"
          confirmWord="TODOS"
          reasonLabel="Motivo del cambio"
          confirmLabel="Activar para todos"
          busy={guardar.isPending}
          error={guardar.mensaje}
          onConfirm={() => guardar.mutate(undefined)}
          onClose={() => setConfirmando(false)}
        />
      )}
    </div>
  )
}
