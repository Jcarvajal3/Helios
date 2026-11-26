import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Check, MapPin, Package, Phone, TestTube } from 'lucide-react'

import { hoyOperativo } from '@/components/admin/inicio/reloj'
import {
  Badge,
  Button,
  Card,
  EmptyState,
  ErrorBox,
  Modal,
  SkeletonList,
  Textarea,
  formatDay,
  formatPhone,
} from '@/components/ui'
import { useToast } from '@/components/Toast'
import {
  CLAVE_LAB_OPERACION,
  completarParada,
  consultaRutaDelDia,
  mensajeDeErrorLab,
  paradaActual,
  progresoDeRuta,
} from '@/features/lab/operacion'
import type { ParadaDeRuta } from '@/features/lab/operacion'
import { ROTULO_KIT } from '@/features/lab/tipos'

/**
 * La ruta del día del driver, pensada para el teléfono: una tarjeta grande por
 * parada, en orden, y un botón enorme para completarla. Se repregunta cada
 * minuto (y al volver a la pestaña) por si la oficina movió algo.
 */
export function RutaDelDia() {
  const fecha = hoyOperativo()
  const consulta = useQuery(consultaRutaDelDia(fecha, { cadaMinuto: true }))
  const [porCompletar, setPorCompletar] = useState<ParadaDeRuta | null>(null)

  if (consulta.isError && !consulta.data) {
    return <ErrorBox title="No se pudo leer la ruta" detail={mensajeDeErrorLab(consulta.error)} />
  }
  if (consulta.isPending) return <SkeletonList rows={3} />

  const ruta = consulta.data
  if (ruta.paradas.length === 0 || ruta.estado === null) {
    return (
      <EmptyState
        title="No hay ruta para hoy"
        description="Cuando la oficina la arme y la inicie, aparece aquí. Esta pantalla se actualiza sola."
      />
    )
  }

  const { hechas, total } = progresoDeRuta(ruta.paradas)
  const actual = paradaActual(ruta.paradas)
  const esBorrador = ruta.estado === 'borrador'

  return (
    <div className="mx-auto flex w-full max-w-xl flex-col gap-4">
      <header className="flex flex-col gap-2">
        <div className="flex items-baseline justify-between gap-3">
          <p className="type-panel-section text-on-surface">
            {hechas} de {total}
          </p>
          <p className="type-panel-caption text-on-surface-variant">{formatDay(fecha)}</p>
        </div>
        <div
          role="progressbar"
          aria-valuemin={0}
          aria-valuemax={total}
          aria-valuenow={hechas}
          aria-label={`${hechas} de ${total} paradas`}
          className="h-2 w-full overflow-hidden rounded-full bg-panel-control"
        >
          <div className="h-full rounded-full bg-success transition-[width]" style={{ width: `${(hechas / total) * 100}%` }} />
        </div>
        {ruta.estado === 'cerrada' && (
          <Badge tone="success" icono>
            Ruta terminada
          </Badge>
        )}
        {esBorrador && <Badge tone="warning">La oficina todavía no inicia la ruta</Badge>}
      </header>

      <ol className="flex flex-col gap-3">
        {ruta.paradas.map((p) => (
          <li key={p.id}>
            {p.estado === 'pendiente' ? (
              <TarjetaDeParada
                parada={p}
                esLaActual={p.id === actual?.id}
                puedeCompletar={!esBorrador}
                onCompletar={() => setPorCompletar(p)}
              />
            ) : (
              <ParadaHecha parada={p} />
            )}
          </li>
        ))}
      </ol>

      {porCompletar && <CompletarModal parada={porCompletar} fecha={fecha} onClose={() => setPorCompletar(null)} />}
    </div>
  )
}

function TarjetaDeParada({
  parada,
  esLaActual,
  puedeCompletar,
  onCompletar,
}: {
  parada: ParadaDeRuta
  esLaActual: boolean
  puedeCompletar: boolean
  onCompletar: () => void
}) {
  const esLab = parada.tipo === 'laboratorio'
  return (
    <Card className={`flex flex-col gap-4 ${esLaActual ? 'ring-2 ring-primary-bright' : ''}`}>
      <div className="flex items-start gap-3">
        <span
          aria-hidden
          className="flex size-10 shrink-0 items-center justify-center rounded-full bg-on-surface type-panel-section tabular-nums text-shell-canvas"
        >
          {parada.orden}
        </span>
        <div className="min-w-0 flex-1">
          <h2 className="type-panel-section break-words text-on-surface">{parada.nombre}</h2>
          <Badge tone={esLab ? 'brand' : 'neutral'} className="mt-1">
            {esLab ? 'Laboratorio' : 'Consultorio'}
          </Badge>
        </div>
      </div>

      {parada.direccion && (
        <p className="flex items-start gap-2 type-panel-body break-words text-on-surface">
          <MapPin size={18} aria-hidden className="mt-0.5 shrink-0 text-on-surface-variant" />
          {parada.direccion}
        </p>
      )}

      {parada.telefono && (
        <a
          href={`tel:${parada.telefono.replace(/[^\d+]/g, '')}`}
          className="flex min-h-12 items-center gap-2 rounded-panel-card bg-panel-control px-3 type-panel-body font-semibold text-on-surface"
        >
          <Phone size={18} aria-hidden className="shrink-0" />
          {formatPhone(parada.telefono)}
        </a>
      )}

      {parada.kitsADejar.length > 0 && (
        <div className="flex flex-col gap-1.5">
          <p className="flex items-center gap-2 type-panel-label text-on-surface-variant">
            <Package size={16} aria-hidden /> Dejar
          </p>
          <ul className="flex flex-wrap gap-2">
            {parada.kitsADejar.map((k) => (
              <li key={k.kit}>
                <Badge tone="brand">
                  {k.cantidad} × {ROTULO_KIT[k.kit]}
                </Badge>
              </li>
            ))}
          </ul>
        </div>
      )}

      {parada.muestras.length > 0 && (
        <div className="flex flex-col gap-1.5">
          <p className="flex items-center gap-2 type-panel-label text-on-surface-variant">
            <TestTube size={16} aria-hidden /> {esLab ? 'Entregar' : 'Retirar'} ({parada.muestras.length})
          </p>
          <ul className="flex flex-col divide-y divide-panel-hairline rounded-panel-card bg-panel-raised">
            {parada.muestras.map((m) => (
              <li key={m.codigo} className="flex flex-wrap items-baseline justify-between gap-x-3 px-3 py-2">
                <span className="type-panel-body font-semibold tabular-nums text-on-surface">{m.codigo}</span>
                <span className="type-panel-caption text-on-surface-variant">
                  {[m.examen, m.kit ? ROTULO_KIT[m.kit] : null].filter(Boolean).join(' · ')}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {parada.kitsADejar.length === 0 && parada.muestras.length === 0 && (
        <p className="type-panel-body text-on-surface-variant">Nada que dejar ni retirar aquí.</p>
      )}

      <Button
        variant={esLaActual ? 'filled' : 'tonal'}
        disabled={!puedeCompletar}
        motivoApagado={!puedeCompletar ? 'Espera a que la oficina inicie la ruta.' : undefined}
        onClick={onCompletar}
        className="min-h-14"
      >
        Completar parada
      </Button>
    </Card>
  )
}

/** Una parada ya hecha: una línea que no estorba; se abre para ver qué fue. */
function ParadaHecha({ parada }: { parada: ParadaDeRuta }) {
  const completada = parada.estado === 'completada'
  return (
    <details className="rounded-panel-card border border-panel-hairline bg-panel-card">
      <summary className="flex min-h-12 cursor-pointer list-none items-center gap-3 px-3 py-2">
        <Check size={18} aria-hidden className={completada ? 'shrink-0 text-success' : 'shrink-0 text-warning'} />
        <span className="min-w-0 flex-1 truncate type-panel-body text-on-surface-variant">
          {parada.orden}. {parada.nombre}
        </span>
        <span className="type-panel-caption text-on-surface-variant">{completada ? 'Completada' : 'Saltada'}</span>
      </summary>
      <div className="flex flex-col gap-1 px-3 pb-3 type-panel-caption text-on-surface-variant">
        {parada.direccion && <p>{parada.direccion}</p>}
        {parada.kitsADejar.length > 0 && (
          <p>Dejó: {parada.kitsADejar.map((k) => `${k.cantidad} ${ROTULO_KIT[k.kit]}`).join(', ')}</p>
        )}
        {parada.muestras.length > 0 && <p>Muestras: {parada.muestras.map((m) => m.codigo).join(', ')}</p>}
      </div>
    </details>
  )
}

function CompletarModal({ parada, fecha, onClose }: { parada: ParadaDeRuta; fecha: string; onClose: () => void }) {
  const queryClient = useQueryClient()
  const avisar = useToast()
  const [nota, setNota] = useState('')

  const completar = useMutation({
    mutationFn: () => completarParada(parada.id, nota),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: CLAVE_LAB_OPERACION })
      avisar(`Parada ${parada.orden} completada`)
      onClose()
    },
  })

  return (
    <Modal title="Completar parada" onClose={onClose} width="sm">
      <div className="flex flex-col gap-4">
        <p className="type-panel-body text-on-surface">
          ¿Ya terminaste en <strong>{parada.nombre}</strong>? Al confirmar, se marcan como entregadas y retiradas las
          muestras y los kits de esta parada.
        </p>
        <Textarea
          id={`lab-nota-${fecha}`}
          label="Nota (opcional)"
          value={nota}
          onChange={setNota}
          rows={3}
          maxLength={300}
          placeholder="Algo que la oficina deba saber"
        />
        {completar.isError && <ErrorBox title="No se pudo completar" detail={mensajeDeErrorLab(completar.error)} />}
        <div className="flex flex-col gap-2">
          <Button disabled={completar.isPending} onClick={() => completar.mutate()} className="min-h-14">
            {completar.isPending ? 'Guardando…' : 'Sí, completar'}
          </Button>
          <Button variant="text" onClick={onClose}>
            Cancelar
          </Button>
        </div>
      </div>
    </Modal>
  )
}
