import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowDown, ArrowUp } from 'lucide-react'

import { hoyOperativo } from '@/components/admin/inicio/reloj'
import {
  Badge,
  Button,
  Callout,
  Card,
  EmptyState,
  ErrorBox,
  IconButton,
  Input,
  Modal,
  SectionTitle,
  SkeletonList,
  formatDay,
} from '@/components/ui'
import { useToast } from '@/components/Toast'
import {
  CLAVE_LAB_OPERACION,
  armarRuta,
  consultaLogistica,
  consultaRutaDelDia,
  fijarKitsDeParada,
  iniciarRuta,
  mensajeDeErrorLab,
  moverParada,
  ordenAlMover,
} from '@/features/lab/operacion'
import type { LogisticaDelDia, ParadaDeRuta, RutaDelDia } from '@/features/lab/operacion'
import { KITS, ROTULO_KIT } from '@/features/lab/tipos'
import type { KitTipo } from '@/features/lab/tipos'

const ESTILO_FECHA = /^\d{4}-\d{2}-\d{2}$/

/** Logística de Helios Lab: qué hay que mover un día y la ruta del driver. */
export function LogisticaDeLab() {
  const [fecha, setFecha] = useState(() => hoyOperativo())
  const fechaValida = ESTILO_FECHA.test(fecha)
  const hoy = hoyOperativo()

  return (
    <div className="flex flex-col gap-6">
      <Card className="flex flex-wrap items-end gap-4">
        <div className="w-44">
          <Input id="lab-log-fecha" label="Día" type="date" value={fecha} onChange={setFecha} />
        </div>
        <p className="min-w-0 flex-1 type-panel-body text-on-surface-variant">
          {fechaValida ? (
            <>
              {fecha === hoy ? 'Hoy' : formatDay(fecha)} · lo que hay que retirar, entregar y reponer para armar la ruta.
            </>
          ) : (
            'Elige un día.'
          )}
        </p>
        {fecha !== hoy && (
          <Button variant="text" size="md" onClick={() => setFecha(hoy)}>
            Ir a hoy
          </Button>
        )}
      </Card>

      {fechaValida && (
        <>
          <ResumenDelDia fecha={fecha} />
          <RutaDeLogistica fecha={fecha} />
        </>
      )}
    </div>
  )
}

// ── Lo que hay que mover ───────────────────────────────────────────────────

function ResumenDelDia({ fecha }: { fecha: string }) {
  const consulta = useQuery(consultaLogistica(fecha))

  if (consulta.isError) {
    return <ErrorBox title="No se pudo leer la logística del día" detail={mensajeDeErrorLab(consulta.error)} />
  }
  if (consulta.isPending) return <SkeletonList rows={4} />

  return <TarjetasDelDia datos={consulta.data} />
}

function TarjetasDelDia({ datos }: { datos: LogisticaDelDia }) {
  return (
    <div className="grid gap-4 lg:grid-cols-3">
      <Card className="flex flex-col gap-3">
        <div className="flex items-center justify-between gap-2">
          <SectionTitle>Por retirar</SectionTitle>
          <Badge tone={datos.porRetirar.length > 0 ? 'brand' : 'neutral'}>{datos.porRetirar.length}</Badge>
        </div>
        {datos.porRetirar.length === 0 ? (
          <p className="type-panel-body text-on-surface-variant">Ningún consultorio tiene muestras esperando.</p>
        ) : (
          <ul className="flex flex-col divide-y divide-panel-hairline">
            {datos.porRetirar.map((r) => (
              <li key={r.merchantId} className="flex items-start justify-between gap-3 py-2">
                <div className="min-w-0">
                  <p className="type-panel-body font-semibold text-on-surface">{r.medico}</p>
                  <p className="type-panel-caption text-on-surface-variant">
                    {[r.consultorio, r.direccion].filter(Boolean).join(' · ') || 'Sin dirección'}
                  </p>
                  {r.codigos.length > 0 && (
                    <p className="type-panel-caption tabular-nums text-on-surface-variant">{r.codigos.join(', ')}</p>
                  )}
                </div>
                <Badge tone="brand">
                  {r.muestras} {r.muestras === 1 ? 'muestra' : 'muestras'}
                </Badge>
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card className="flex flex-col gap-3">
        <div className="flex items-center justify-between gap-2">
          <SectionTitle>Pedidos de kits</SectionTitle>
          <Badge tone={datos.pedidos.length > 0 ? 'warning' : 'neutral'}>{datos.pedidos.length}</Badge>
        </div>
        {datos.pedidos.length === 0 ? (
          <p className="type-panel-body text-on-surface-variant">No hay pedidos pendientes.</p>
        ) : (
          <ul className="flex flex-col divide-y divide-panel-hairline">
            {datos.pedidos.map((p, i) => (
              <li key={p.id ?? `${p.merchantId}-${i}`} className="flex items-start justify-between gap-3 py-2">
                <div className="min-w-0">
                  <p className="type-panel-body font-semibold text-on-surface">{p.medico}</p>
                  {p.nota && <p className="type-panel-caption text-on-surface-variant">{p.nota}</p>}
                </div>
                <Badge tone="warning">
                  {p.cantidad} {p.kit ? ROTULO_KIT[p.kit] : 'kits'}
                </Badge>
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card className="flex flex-col gap-3">
        <div className="flex items-center justify-between gap-2">
          <SectionTitle>Médicos bajo el mínimo</SectionTitle>
          <Badge tone={datos.bajoMinimo.length > 0 ? 'warning' : 'neutral'}>{datos.bajoMinimo.length}</Badge>
        </div>
        {datos.bajoMinimo.length === 0 ? (
          <p className="type-panel-body text-on-surface-variant">Todos tienen los kits que necesitan.</p>
        ) : (
          <ul className="flex flex-col divide-y divide-panel-hairline">
            {datos.bajoMinimo.map((m) => (
              <li key={m.merchantId} className="py-2">
                <p className="type-panel-body font-semibold text-on-surface">{m.medico}</p>
                <p className="type-panel-caption text-on-surface-variant">
                  {KITS.filter((k) => m.kits[k] !== null)
                    .map((k) => `${ROTULO_KIT[k]} ${m.kits[k]}`)
                    .join(' · ') || m.consultorio || ''}
                </p>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  )
}

// ── La ruta ────────────────────────────────────────────────────────────────

const ROTULO_ESTADO_RUTA = { borrador: 'Borrador', en_curso: 'En curso', cerrada: 'Cerrada' } as const

function RutaDeLogistica({ fecha }: { fecha: string }) {
  const queryClient = useQueryClient()
  const avisar = useToast()
  const consulta = useQuery(consultaRutaDelDia(fecha))
  const [editando, setEditando] = useState<ParadaDeRuta | null>(null)

  const refrescar = () => queryClient.invalidateQueries({ queryKey: CLAVE_LAB_OPERACION })

  const armar = useMutation({
    mutationFn: () => armarRuta(fecha),
    onSuccess: async () => {
      await refrescar()
      avisar('Ruta armada')
    },
  })
  const iniciar = useMutation({
    mutationFn: () => iniciarRuta(fecha),
    onSuccess: async () => {
      await refrescar()
      avisar('Ruta iniciada: el driver ya la ve en su teléfono')
    },
  })
  const mover = useMutation({
    mutationFn: (v: { id: string; orden: number }) => moverParada(v.id, v.orden),
    onSuccess: refrescar,
  })

  if (consulta.isError) {
    return <ErrorBox title="No se pudo leer la ruta" detail={mensajeDeErrorLab(consulta.error)} />
  }
  if (consulta.isPending) return <SkeletonList rows={4} />

  const ruta: RutaDelDia = consulta.data
  const enBorrador = ruta.estado === null || ruta.estado === 'borrador'
  const hayParadas = ruta.paradas.length > 0
  const ocupado = armar.isPending || iniciar.isPending || mover.isPending
  const error = armar.error ?? iniciar.error ?? mover.error

  return (
    <section className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <SectionTitle>Ruta del día</SectionTitle>
          {ruta.estado && (
            <Badge tone={ruta.estado === 'en_curso' ? 'brand' : ruta.estado === 'cerrada' ? 'success' : 'neutral'}>
              {ROTULO_ESTADO_RUTA[ruta.estado]}
            </Badge>
          )}
        </div>
        <div className="flex flex-wrap gap-2">
          <Button
            variant="tonal"
            size="md"
            disabled={!enBorrador || ocupado}
            title={!enBorrador ? 'La ruta ya salió; no se puede rehacer' : undefined}
            onClick={() => armar.mutate()}
          >
            {armar.isPending ? 'Armando…' : hayParadas ? 'Rehacer ruta' : 'Armar ruta'}
          </Button>
          <Button
            size="md"
            disabled={!enBorrador || !hayParadas || ocupado}
            title={!hayParadas ? 'Arma la ruta primero' : !enBorrador ? 'La ruta ya salió' : undefined}
            onClick={() => iniciar.mutate()}
          >
            {iniciar.isPending ? 'Iniciando…' : 'Iniciar ruta'}
          </Button>
        </div>
      </div>

      {error && <ErrorBox title="No se pudo completar" detail={mensajeDeErrorLab(error)} />}
      {enBorrador && hayParadas && (
        <Callout tone="info" titulo="Es un borrador">
          Ordena las paradas y ajusta los kits a dejar. El driver no la ve hasta que la inicies.
        </Callout>
      )}

      {!hayParadas ? (
        <EmptyState
          title="Todavía no hay ruta para este día"
          description="Arma la ruta: entran los consultorios con muestras por retirar, con pedidos o bajo el mínimo, y al final el laboratorio."
        />
      ) : (
        <ol className="flex flex-col gap-2">
          {ruta.paradas.map((p, i) => (
            <FilaDeParada
              key={p.id}
              parada={p}
              editable={enBorrador}
              ocupado={ocupado}
              primera={i === 0}
              ultima={i === ruta.paradas.length - 1}
              onMover={(sentido) => {
                const orden = ordenAlMover(ruta.paradas, p.id, sentido)
                if (orden !== null) mover.mutate({ id: p.id, orden })
              }}
              onKits={() => setEditando(p)}
            />
          ))}
        </ol>
      )}

      {editando && <KitsDeParadaModal parada={editando} onClose={() => setEditando(null)} />}
    </section>
  )
}

function FilaDeParada({
  parada,
  editable,
  ocupado,
  primera,
  ultima,
  onMover,
  onKits,
}: {
  parada: ParadaDeRuta
  editable: boolean
  ocupado: boolean
  primera: boolean
  ultima: boolean
  onMover: (sentido: 'arriba' | 'abajo') => void
  onKits: () => void
}) {
  const esLab = parada.tipo === 'laboratorio'
  return (
    <li>
      <Card className="flex flex-wrap items-center gap-3">
        <span
          aria-hidden
          className="flex size-8 shrink-0 items-center justify-center rounded-full bg-panel-control type-panel-body font-semibold tabular-nums text-on-surface"
        >
          {parada.orden}
        </span>
        <div className="min-w-0 flex-1">
          <p className="flex flex-wrap items-center gap-2 type-panel-body font-semibold text-on-surface">
            {parada.nombre}
            <Badge tone={esLab ? 'brand' : 'neutral'}>{esLab ? 'Laboratorio' : 'Consultorio'}</Badge>
            {parada.estado !== 'pendiente' && (
              <Badge tone={parada.estado === 'completada' ? 'success' : 'warning'} icono>
                {parada.estado === 'completada' ? 'Completada' : 'Saltada'}
              </Badge>
            )}
          </p>
          {parada.direccion && <p className="type-panel-caption text-on-surface-variant">{parada.direccion}</p>}
          <p className="type-panel-caption text-on-surface-variant">
            {parada.kitsADejar.length > 0
              ? `Dejar: ${parada.kitsADejar.map((k) => `${k.cantidad} ${ROTULO_KIT[k.kit]}`).join(', ')}`
              : 'Sin kits a dejar'}
            {parada.muestras.length > 0 &&
              ` · Retirar ${parada.muestras.length} ${parada.muestras.length === 1 ? 'muestra' : 'muestras'}`}
          </p>
        </div>
        {editable && (
          <div className="flex items-center gap-1.5">
            {!esLab && (
              <Button variant="tonal" size="sm" disabled={ocupado} onClick={onKits}>
                Kits a dejar
              </Button>
            )}
            <IconButton label={`Subir ${parada.nombre}`} disabled={primera || ocupado} onClick={() => onMover('arriba')}>
              <ArrowUp size={16} aria-hidden />
            </IconButton>
            <IconButton label={`Bajar ${parada.nombre}`} disabled={ultima || ocupado} onClick={() => onMover('abajo')}>
              <ArrowDown size={16} aria-hidden />
            </IconButton>
          </div>
        )}
      </Card>
    </li>
  )
}

function KitsDeParadaModal({ parada, onClose }: { parada: ParadaDeRuta; onClose: () => void }) {
  const queryClient = useQueryClient()
  const avisar = useToast()
  const actuales = (k: KitTipo) => parada.kitsADejar.find((x) => x.kit === k)?.cantidad ?? 0
  const [valores, setValores] = useState<Record<KitTipo, string>>({
    sangre: String(actuales('sangre')),
    orina: String(actuales('orina')),
    biopsia: String(actuales('biopsia')),
  })

  const numeros = KITS.map((k) => ({ kit: k, n: /^\d+$/.test(valores[k].trim()) ? Number(valores[k].trim()) : null }))
  const invalida = numeros.some((x) => x.n === null)

  const guardar = useMutation({
    mutationFn: async () => {
      // Solo lo que cambió; 0 quita el kit de la parada.
      for (const { kit, n } of numeros) {
        if (n !== null && n !== actuales(kit)) await fijarKitsDeParada(parada.id, kit, n)
      }
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: CLAVE_LAB_OPERACION })
      avisar('Kits de la parada guardados')
      onClose()
    },
  })

  return (
    <Modal title={`Kits a dejar · ${parada.nombre}`} onClose={onClose} width="sm">
      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault()
          if (!invalida && !guardar.isPending) guardar.mutate()
        }}
      >
        <p className="type-panel-body text-on-surface-variant">Cuántos kits de cada tipo deja el driver aquí. Con 0 no deja ninguno.</p>
        {KITS.map((k, i) => (
          <Input
            key={k}
            id={`lab-parada-kit-${k}`}
            label={ROTULO_KIT[k]}
            value={valores[k]}
            onChange={(v) => setValores((prev) => ({ ...prev, [k]: v }))}
            inputMode="numeric"
            autoFocus={i === 0}
          />
        ))}
        {invalida && <p className="type-panel-caption text-error">Escribe números enteros, de cero para arriba.</p>}
        {guardar.isError && <ErrorBox title="No se pudo guardar" detail={mensajeDeErrorLab(guardar.error)} />}
        <div className="flex justify-end gap-2">
          <Button variant="text" size="md" onClick={onClose}>
            Cancelar
          </Button>
          <Button type="submit" size="md" disabled={invalida || guardar.isPending}>
            {guardar.isPending ? 'Guardando…' : 'Guardar'}
          </Button>
        </div>
      </form>
    </Modal>
  )
}
