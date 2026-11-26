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
  SkeletonTable,
  Table,
  Td,
  Tr,
} from '@/components/ui'
import { useIsSuperAdmin } from '@/features/admin/role'
import { consultaLaboratorios, guardarLaboratorio, mensajeDeError } from '@/features/lab/admin'
import type { Laboratorio } from '@/features/lab/admin'

import { useEscritura } from '../muestras/comun'

export function Laboratorios() {
  const q = useQuery(consultaLaboratorios())
  const esSuper = useIsSuperAdmin()
  const [editando, setEditando] = useState<Laboratorio | 'nuevo' | null>(null)

  if (q.isPending) return <SkeletonTable rows={4} />
  if (q.isError) return <ErrorBox title="No se pudieron leer los laboratorios" detail={mensajeDeError(q.error)} />

  return (
    <div className="flex flex-col gap-4">
      <div className="flex justify-end">
        <Button
          size="md"
          disabled={!esSuper}
          motivoApagado={!esSuper ? SOLO_SUPER_ADMIN : undefined}
          onClick={() => setEditando('nuevo')}
        >
          <Plus size={16} aria-hidden />
          Nuevo laboratorio
        </Button>
      </div>

      {q.data.length === 0 ? (
        <EmptyState title="Todavía no hay laboratorios" description="Crea el primero para poder ponerle precios a los exámenes." />
      ) : (
        <Table headers={['Laboratorio', 'Correo', 'Teléfono', 'Dirección', 'Estado', '']}>
          {q.data.map((l) => (
            <Tr key={l.id}>
              <Td className="font-semibold">{l.nombre}</Td>
              <Td>{l.correo ?? '—'}</Td>
              <Td>{l.telefono ?? '—'}</Td>
              <Td className="max-w-64 whitespace-normal">{l.direccion ?? '—'}</Td>
              <Td>
                <Badge tone={l.activo ? 'success' : 'neutral'}>{l.activo ? 'Activo' : 'Apagado'}</Badge>
              </Td>
              <Td>
                <Button size="sm" variant="outlined" disabled={!esSuper} onClick={() => setEditando(l)}>
                  Editar
                </Button>
              </Td>
            </Tr>
          ))}
        </Table>
      )}

      {editando && (
        <FormularioLaboratorio
          inicial={editando === 'nuevo' ? null : editando}
          onClose={() => setEditando(null)}
        />
      )}
    </div>
  )
}

function FormularioLaboratorio({ inicial, onClose }: { inicial: Laboratorio | null; onClose: () => void }) {
  const [nombre, setNombre] = useState(inicial?.nombre ?? '')
  const [correo, setCorreo] = useState(inicial?.correo ?? '')
  const [telefono, setTelefono] = useState(inicial?.telefono ?? '')
  const [direccion, setDireccion] = useState(inicial?.direccion ?? '')
  const [activo, setActivo] = useState(inicial?.activo ?? true)

  const guardar = useEscritura(
    () =>
      guardarLaboratorio({
        id: inicial?.id ?? null,
        nombre,
        correo: correo || null,
        telefono: telefono || null,
        direccion: direccion || null,
        activo,
      }),
    'Laboratorio guardado.',
    onClose,
  )

  return (
    <Modal title={inicial ? 'Editar laboratorio' : 'Nuevo laboratorio'} onClose={onClose}>
      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault()
          if (nombre.trim()) guardar.mutate(undefined)
        }}
      >
        <Input id="lab-nombre" label="Nombre" value={nombre} onChange={setNombre} autoFocus />
        <Input id="lab-correo" label="Correo (recibe las muestras y envía los resultados)" type="email" value={correo} onChange={setCorreo} />
        <Input id="lab-tel" label="Teléfono" inputMode="tel" value={telefono} onChange={setTelefono} />
        <Input id="lab-dir" label="Dirección (la ve el conductor)" value={direccion} onChange={setDireccion} />
        <Checkbox id="lab-activo" label="Activo: los médicos pueden elegirlo" checked={activo} onChange={setActivo} />
        {guardar.mensaje && <ErrorBox title="No se pudo guardar" detail={guardar.mensaje} />}
        <div className="flex justify-end gap-2">
          <Button size="md" variant="text" onClick={onClose}>
            Cancelar
          </Button>
          <Button size="md" type="submit" disabled={!nombre.trim() || guardar.isPending}>
            Guardar
          </Button>
        </div>
      </form>
    </Modal>
  )
}
