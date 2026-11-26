import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Plus } from 'lucide-react'

import {
  Badge,
  Button,
  Checkbox,
  EmptyState,
  ErrorBox,
  Input,
  Modal,
  SOLO_SUPER_ADMIN,
  Seccion,
  Select,
  SkeletonTable,
  Table,
  Td,
  Textarea,
  Tr,
  formatUsd,
} from '@/components/ui'
import { useIsSuperAdmin } from '@/features/admin/role'
import {
  consultaExamenes,
  consultaLaboratorios,
  guardarExamen,
  guardarPrecio,
  mensajeDeError,
} from '@/features/lab/admin'
import type { Examen, Laboratorio } from '@/features/lab/admin'
import { KITS, ROTULO_KIT } from '@/features/lab/tipos'
import type { KitTipo } from '@/features/lab/tipos'
import { formatoMontoEditable, leerMonto } from '@/lib/montos'

import { useEscritura } from '../muestras/comun'

/** Exámenes y, debajo, la matriz de precios examen × laboratorio. */
export function ExamenesYPrecios() {
  const examenes = useQuery(consultaExamenes())
  const labs = useQuery(consultaLaboratorios())

  if (examenes.isPending || labs.isPending) return <SkeletonTable rows={6} />
  if (examenes.isError) return <ErrorBox title="No se pudieron leer los exámenes" detail={mensajeDeError(examenes.error)} />
  if (labs.isError) return <ErrorBox title="No se pudieron leer los laboratorios" detail={mensajeDeError(labs.error)} />

  return (
    <div className="flex flex-col gap-10">
      <ListaDeExamenes examenes={examenes.data} />
      <MatrizDePrecios examenes={examenes.data} laboratorios={labs.data} />
    </div>
  )
}

function ListaDeExamenes({ examenes }: { examenes: Examen[] }) {
  const esSuper = useIsSuperAdmin()
  const [editando, setEditando] = useState<Examen | 'nuevo' | null>(null)

  return (
    <Seccion
      titulo="Exámenes"
      controles={
        <Button
          size="md"
          disabled={!esSuper}
          motivoApagado={!esSuper ? SOLO_SUPER_ADMIN : undefined}
          onClick={() => setEditando('nuevo')}
        >
          <Plus size={16} aria-hidden />
          Nuevo examen
        </Button>
      }
    >
      {examenes.length === 0 ? (
        <EmptyState title="Todavía no hay exámenes" />
      ) : (
        <Table headers={['Código', 'Examen', 'Kit', 'Indicaciones', 'Estado', '']}>
          {examenes.map((e) => (
            <Tr key={e.id}>
              <Td className="font-semibold">{e.codigo}</Td>
              <Td>{e.nombre}</Td>
              <Td>{e.kitTipo ? ROTULO_KIT[e.kitTipo] : '—'}</Td>
              <Td className="max-w-72 whitespace-normal type-panel-caption text-on-surface-variant">{e.indicaciones ?? '—'}</Td>
              <Td>
                <Badge tone={e.activo ? 'success' : 'neutral'}>{e.activo ? 'Activo' : 'Apagado'}</Badge>
              </Td>
              <Td>
                <Button size="sm" variant="outlined" disabled={!esSuper} onClick={() => setEditando(e)}>
                  Editar
                </Button>
              </Td>
            </Tr>
          ))}
        </Table>
      )}
      {editando && (
        <FormularioExamen inicial={editando === 'nuevo' ? null : editando} onClose={() => setEditando(null)} />
      )}
    </Seccion>
  )
}

function FormularioExamen({ inicial, onClose }: { inicial: Examen | null; onClose: () => void }) {
  const [codigo, setCodigo] = useState(inicial?.codigo ?? '')
  const [nombre, setNombre] = useState(inicial?.nombre ?? '')
  const [kit, setKit] = useState<KitTipo>(inicial?.kitTipo ?? 'sangre')
  const [indicaciones, setIndicaciones] = useState(inicial?.indicaciones ?? '')
  const [activo, setActivo] = useState(inicial?.activo ?? true)

  const guardar = useEscritura(
    () =>
      guardarExamen({
        id: inicial?.id ?? null,
        codigo,
        nombre,
        kitTipo: kit,
        indicaciones: indicaciones || null,
        activo,
      }),
    'Examen guardado.',
    onClose,
  )
  const completo = codigo.trim() !== '' && nombre.trim() !== ''

  return (
    <Modal title={inicial ? 'Editar examen' : 'Nuevo examen'} onClose={onClose}>
      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault()
          if (completo) guardar.mutate(undefined)
        }}
      >
        <Input id="ex-codigo" label="Código" value={codigo} onChange={setCodigo} autoFocus />
        <Input id="ex-nombre" label="Nombre" value={nombre} onChange={setNombre} />
        <Select<KitTipo>
          id="ex-kit"
          label="Kit que se usa"
          value={kit}
          options={KITS.map((k) => ({ value: k, label: ROTULO_KIT[k] }))}
          onChange={setKit}
        />
        <Textarea
          id="ex-indic"
          label="Indicaciones para el paciente"
          rows={3}
          value={indicaciones}
          onChange={setIndicaciones}
        />
        <Checkbox id="ex-activo" label="Activo: los médicos pueden elegirlo" checked={activo} onChange={setActivo} />
        {guardar.mensaje && <ErrorBox title="No se pudo guardar" detail={guardar.mensaje} />}
        <div className="flex justify-end gap-2">
          <Button size="md" variant="text" onClick={onClose}>
            Cancelar
          </Button>
          <Button size="md" type="submit" disabled={!completo || guardar.isPending}>
            Guardar
          </Button>
        </div>
      </form>
    </Modal>
  )
}

function MatrizDePrecios({ examenes, laboratorios }: { examenes: Examen[]; laboratorios: Laboratorio[] }) {
  if (examenes.length === 0 || laboratorios.length === 0) {
    return (
      <Seccion titulo="Precios base">
        <EmptyState
          title="Faltan exámenes o laboratorios"
          description="Con al menos uno de cada uno puedes ponerle precio base a cada examen."
        />
      </Seccion>
    )
  }
  return (
    <Seccion
      titulo="Precios base"
      info="Lo que cobra cada laboratorio por examen, en dólares. Al precio final se le suman el Cargo Helios y la comisión del médico. Un precio apagado no se le ofrece al médico."
    >
      <Table headers={['Examen', ...laboratorios.map((l) => l.nombre)]}>
        {examenes.map((e) => (
          <Tr key={e.id}>
            <Td>
              <div className="flex flex-col">
                <span className="font-semibold">{e.nombre}</span>
                <span className="type-panel-caption text-panel-muted">{e.codigo}</span>
              </div>
            </Td>
            {laboratorios.map((l) => (
              <Td key={l.id}>
                <CeldaDePrecio examen={e} laboratorio={l} />
              </Td>
            ))}
          </Tr>
        ))}
      </Table>
    </Seccion>
  )
}

function CeldaDePrecio({ examen, laboratorio }: { examen: Examen; laboratorio: Laboratorio }) {
  const esSuper = useIsSuperAdmin()
  const actual = examen.precios.find((p) => p.laboratorioId === laboratorio.id) ?? null
  const [texto, setTexto] = useState(formatoMontoEditable(actual?.baseUsd))
  const [activo, setActivo] = useState(actual?.activo ?? true)

  const monto = leerMonto(texto)
  const valido = monto !== null && monto > 0
  const sucio = actual === null ? texto.trim() !== '' : monto !== actual.baseUsd || activo !== actual.activo

  const guardar = useEscritura(
    () =>
      guardarPrecio({
        laboratorioId: laboratorio.id,
        examenId: examen.id,
        baseUsd: monto ?? 0,
        activo,
      }),
    'Precio guardado.',
  )

  return (
    <div className="flex min-w-44 flex-col gap-1.5">
      <div className="flex items-center gap-2">
        <Input
          id={`precio-${examen.id}-${laboratorio.id}`}
          value={texto}
          onChange={setTexto}
          inputMode="decimal"
          placeholder="Sin precio"
          error={texto.trim() !== '' && !valido}
          className="w-28"
        />
        <Button size="sm" disabled={!esSuper || !sucio || !valido || guardar.isPending} onClick={() => guardar.mutate(undefined)}>
          Guardar
        </Button>
      </div>
      <Checkbox
        id={`activo-${examen.id}-${laboratorio.id}`}
        label={<span className="type-panel-caption">Activo{actual && ` · ${formatUsd(actual.baseUsd)}`}</span>}
        checked={activo}
        disabled={!esSuper}
        onChange={setActivo}
      />
      {guardar.mensaje && <span className="type-panel-caption text-error">{guardar.mensaje}</span>}
    </div>
  )
}
