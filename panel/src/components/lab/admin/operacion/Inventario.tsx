import { useRef, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import {
  Badge,
  Button,
  Card,
  EmptyState,
  ErrorBox,
  Input,
  Modal,
  SectionTitle,
  SkeletonTable,
  Table,
  Td,
  Tr,
} from '@/components/ui'
import { useToast } from '@/components/Toast'
import {
  CLAVE_LAB_OPERACION,
  claveDeOperacion,
  consultaInventarioDeMedicos,
  consultaKits,
  guardarMinimos,
  mensajeDeErrorLab,
  ordenarInventario,
  registrarMovimiento,
} from '@/features/lab/operacion'
import type { InventarioDeMedico, KitDeLab } from '@/features/lab/operacion'
import { KITS, ROTULO_KIT } from '@/features/lab/tipos'

/** Un entero de lo que se teclea, o `null` si no es un número entero. */
function enteroDe(texto: string): number | null {
  const t = texto.trim()
  if (!/^-?\d+$/.test(t)) return null
  return Number(t)
}

type Accion = { clase: 'entrada' | 'ajuste' | 'minimos'; kit: KitDeLab }

/** Inventario de Helios Lab: los kits de Helios y los que tiene cada médico. */
export function InventarioDeLab() {
  const kits = useQuery(consultaKits())
  const medicos = useQuery(consultaInventarioDeMedicos())
  const [accion, setAccion] = useState<Accion | null>(null)

  return (
    <div className="flex flex-col gap-6">
      <section className="flex flex-col gap-3">
        <SectionTitle>Kits en Helios</SectionTitle>
        {kits.isError ? (
          <ErrorBox title="No se pudieron leer los kits" detail={mensajeDeErrorLab(kits.error)} />
        ) : kits.isPending ? (
          <SkeletonTable rows={3} />
        ) : kits.data.length === 0 ? (
          <EmptyState title="Todavía no hay kits" description="Los tipos de kit (sangre, orina, biopsia) los crea la base." />
        ) : (
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {kits.data.map((kit) => (
              <TarjetaDeKit key={kit.tipo} kit={kit} onAccion={(clase) => setAccion({ clase, kit })} />
            ))}
          </div>
        )}
      </section>

      <section className="flex flex-col gap-3">
        <SectionTitle>Kits por médico</SectionTitle>
        {medicos.isError ? (
          <ErrorBox title="No se pudo leer el inventario de los médicos" detail={mensajeDeErrorLab(medicos.error)} />
        ) : medicos.isPending ? (
          <SkeletonTable rows={5} />
        ) : medicos.data.length === 0 ? (
          <EmptyState
            title="Ningún médico tiene kits todavía"
            description="Aparecen aquí cuando se les entrega el primero."
          />
        ) : (
          <TablaDeMedicos medicos={ordenarInventario(medicos.data)} />
        )}
      </section>

      {accion && accion.clase !== 'minimos' && (
        <MovimientoModal tipo={accion.clase} kit={accion.kit} onClose={() => setAccion(null)} />
      )}
      {accion?.clase === 'minimos' && <MinimosModal kit={accion.kit} onClose={() => setAccion(null)} />}
    </div>
  )
}

function TarjetaDeKit({ kit, onAccion }: { kit: KitDeLab; onAccion: (clase: Accion['clase']) => void }) {
  return (
    <Card className="flex flex-col gap-3">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <h3 className="type-panel-body font-semibold text-on-surface">{kit.nombre || ROTULO_KIT[kit.tipo]}</h3>
          <p className="type-panel-caption text-on-surface-variant">En médicos: {kit.enMedicos}</p>
        </div>
        {kit.reponer && (
          <Badge tone="warning" icono>
            Reponer
          </Badge>
        )}
      </div>
      <p className="flex flex-wrap items-baseline gap-x-1.5">
        <span className="type-panel-figure tabular-nums text-on-surface">{kit.stockHelios}</span>
        <span className="type-panel-body text-on-surface-variant">en Helios · mínimo {kit.minimoHelios}</span>
      </p>
      <p className="type-panel-caption text-on-surface-variant">Mínimo por médico: {kit.minimoPorMedico}</p>
      <div className="flex flex-wrap gap-2">
        <Button size="sm" onClick={() => onAccion('entrada')}>
          Registrar entrada
        </Button>
        <Button size="sm" variant="tonal" onClick={() => onAccion('ajuste')}>
          Ajuste
        </Button>
        <Button size="sm" variant="text" onClick={() => onAccion('minimos')}>
          Mínimos
        </Button>
      </div>
    </Card>
  )
}

function TablaDeMedicos({ medicos }: { medicos: ReadonlyArray<InventarioDeMedico> }) {
  return (
    <Table headers={['Médico', ...KITS.map((k) => ROTULO_KIT[k]), 'Entregados', 'Usados', 'Estado']} apilada>
      {medicos.map((m) => (
        <Tr key={m.merchantId} className={m.bajoMinimo ? 'bg-warning/10' : ''}>
          <Td>
            <span className="font-semibold">{m.medico}</span>
            {m.consultorio && (
              <span className="block type-panel-caption text-on-surface-variant">{m.consultorio}</span>
            )}
          </Td>
          {KITS.map((k) => (
            <Td key={k} className="tabular-nums">
              {m.kits[k]}
            </Td>
          ))}
          <Td className="tabular-nums">{m.entregadosTotal}</Td>
          <Td className="tabular-nums">{m.usadosTotal}</Td>
          <Td>
            {m.bajoMinimo ? (
              <Badge tone="warning" icono>
                Bajo el mínimo
              </Badge>
            ) : (
              <Badge tone="success">Al día</Badge>
            )}
          </Td>
        </Tr>
      ))}
    </Table>
  )
}

function MovimientoModal({
  tipo,
  kit,
  onClose,
}: {
  tipo: 'entrada' | 'ajuste'
  kit: KitDeLab
  onClose: () => void
}) {
  const queryClient = useQueryClient()
  const avisar = useToast()
  const [cantidad, setCantidad] = useState('')
  const [nota, setNota] = useState('')
  // Una clave por formulario abierto: reintentar tras un fallo de red no duplica el movimiento.
  const clave = useRef(claveDeOperacion())

  const n = enteroDe(cantidad)
  const invalida = n === null || n === 0 || (tipo === 'entrada' && n < 0)
  const rotulo = kit.nombre || ROTULO_KIT[kit.tipo]

  const guardar = useMutation({
    mutationFn: () => registrarMovimiento({ tipo, kit: kit.tipo, cantidad: n ?? 0, nota, clave: clave.current }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: CLAVE_LAB_OPERACION })
      avisar(tipo === 'entrada' ? `Entrada de ${n} kits de ${rotulo} registrada` : `Ajuste de ${rotulo} registrado`)
      onClose()
    },
  })

  return (
    <Modal
      title={tipo === 'entrada' ? `Registrar entrada · ${rotulo}` : `Ajuste · ${rotulo}`}
      onClose={onClose}
      width="sm"
    >
      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault()
          if (!invalida && !guardar.isPending) guardar.mutate()
        }}
      >
        <p className="type-panel-body text-on-surface-variant">
          {tipo === 'entrada'
            ? `Kits que llegan a Helios. Ahora hay ${kit.stockHelios}.`
            : `Corrige el stock de Helios (ahora ${kit.stockHelios}). Usa un número negativo para restar.`}
        </p>
        <Input
          id="lab-mov-cantidad"
          label="Cantidad"
          value={cantidad}
          onChange={setCantidad}
          inputMode="numeric"
          autoFocus
          error={cantidad !== '' && invalida}
          hint={cantidad !== '' && invalida ? 'Escribe un número entero distinto de cero.' : undefined}
        />
        <Input
          id="lab-mov-nota"
          label={tipo === 'ajuste' ? 'Motivo del ajuste' : 'Nota (opcional)'}
          value={nota}
          onChange={setNota}
        />
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

function MinimosModal({ kit, onClose }: { kit: KitDeLab; onClose: () => void }) {
  const queryClient = useQueryClient()
  const avisar = useToast()
  const [enHelios, setEnHelios] = useState(String(kit.minimoHelios))
  const [porMedico, setPorMedico] = useState(String(kit.minimoPorMedico))
  const a = enteroDe(enHelios)
  const b = enteroDe(porMedico)
  const invalida = a === null || b === null || a < 0 || b < 0

  const guardar = useMutation({
    mutationFn: () => guardarMinimos({ tipo: kit.tipo, minimoHelios: a ?? 0, minimoPorMedico: b ?? 0 }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: CLAVE_LAB_OPERACION })
      avisar('Mínimos guardados')
      onClose()
    },
  })

  return (
    <Modal title={`Mínimos · ${kit.nombre || ROTULO_KIT[kit.tipo]}`} onClose={onClose} width="sm">
      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault()
          if (!invalida && !guardar.isPending) guardar.mutate()
        }}
      >
        <Input
          id="lab-min-helios"
          label="Mínimo en Helios"
          value={enHelios}
          onChange={setEnHelios}
          inputMode="numeric"
          autoFocus
          hint="Por debajo de esto, el kit sale como «Reponer»."
        />
        <Input
          id="lab-min-medico"
          label="Mínimo por médico"
          value={porMedico}
          onChange={setPorMedico}
          inputMode="numeric"
          hint="Un médico con menos de esto entra en la ruta para recibir kits."
        />
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
