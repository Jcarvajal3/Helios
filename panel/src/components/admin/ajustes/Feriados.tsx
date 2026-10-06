import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { CalendarDays, Trash2 } from 'lucide-react'

import { useToast } from '@/components/Toast'
import { SelectorDePaso } from '@/components/admin/tableros/SelectorDePaso'
import {
  Badge,
  Button,
  ConfirmDialog,
  DataLabel,
  EmptyState,
  ErrorBox,
  Input,
  Seccion,
  Segmented,
  SkeletonTable,
  Table,
  Td,
  Tr,
  formatDay,
} from '@/components/ui'
import { fetchHolidays, setHoliday } from '@/features/admin/ajustes'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

const TIPOS = [
  { value: 'nacional', label: 'Nacional' },
  { value: 'regional', label: 'Regional' },
  { value: 'bancario', label: 'Bancario' },
] as const

type TipoFeriado = (typeof TIPOS)[number]['value']

function rotuloDeTipo(tipo: string): string {
  return TIPOS.find((t) => t.value === tipo)?.label ?? tipo
}

/**
 * Los días en que ni el BCV publica ni los bancos operan.
 *
 * Sin ellos, «día hábil» era sábados y domingos fuera, y el aviso de tasa vieja
 * saltaba un martes de Carnaval. El año va en la URL (`?anio=`).
 */
export function Feriados({ anio, onAnio }: { anio: number; onAnio: (anio: number) => void }) {
  const avisar = useToast()
  const queryClient = useQueryClient()
  const isSuperAdmin = useIsSuperAdmin()
  const [anadiendo, setAnadiendo] = useState(false)
  const [quitando, setQuitando] = useState<string | null>(null)

  const query = useQuery({
    queryKey: ['admin-holidays', anio],
    queryFn: () => fetchHolidays(anio),
  })

  const quitar = useMutation({
    mutationFn: (day: string) => setHoliday({ day, remove: true }),
    onSuccess: (_data, day) => {
      avisar(`El ${formatDay(day)} vuelve a contar como día hábil.`)
      setQuitando(null)
      void queryClient.invalidateQueries({ queryKey: ['admin-holidays'] })
    },
  })

  const motivoApagado = isSuperAdmin ? undefined : SOLO_SUPER_ADMIN

  return (
    <Seccion
      titulo="Feriados"
      info="Los días en que ni el BCV publica ni los bancos operan. No cuentan como hábiles para la tasa: sin ellos, un martes de Carnaval hacía saltar el aviso de tasa vieja. A las clínicas se les paga igual: los días de pago son corridos."
      controles={
        <>
          <SelectorDePaso
            etiqueta="Año"
            rotulo={String(anio)}
            anterior={{ onClick: () => onAnio(anio - 1) }}
            siguiente={{ onClick: () => onAnio(anio + 1) }}
          />
          <Button
            size="sm"
            disabled={!isSuperAdmin}
            motivoApagado={motivoApagado}
            onClick={() => setAnadiendo(true)}
          >
            Añadir un feriado
          </Button>
        </>
      }
    >
      {query.isLoading && <SkeletonTable rows={6} columns={3} />}

      {query.isError && (
        <ErrorBox title="No se pudo leer el calendario" detail={describeError(query.error)} />
      )}

      {query.data && query.data.length === 0 && (
        <EmptyState
          icon={<CalendarDays size={40} />}
          title={`Ningún feriado en ${anio}`}
          description="Sin calendario, un martes de Carnaval cuenta como día hábil y el aviso de tasa vieja salta sin motivo."
        />
      )}

      {query.data && query.data.length > 0 && (
        <Table headers={['Día', 'Qué es', 'Tipo', '']}>
          {query.data.map((h) => (
            <Tr key={h.day}>
              <Td className="whitespace-nowrap font-medium">{formatDay(h.day)}</Td>
              <Td className="text-on-surface-variant">{h.name}</Td>
              <Td>
                <Badge tone="neutral">{rotuloDeTipo(h.kind)}</Badge>
              </Td>
              <Td>
                <Button
                  size="sm"
                  variant="text"
                  disabled={!isSuperAdmin}
                  motivoApagado={motivoApagado}
                  onClick={() => setQuitando(h.day)}
                >
                  <Trash2 size={14} /> Quitar
                </Button>
              </Td>
            </Tr>
          ))}
        </Table>
      )}

      {anadiendo && <NuevoFeriado anio={anio} onClose={() => setAnadiendo(false)} />}

      {quitando && (
        <ConfirmDialog
          title="Quitar el feriado"
          summary={`El ${formatDay(quitando)} vuelve a contar como día hábil para la tasa.`}
          confirmLabel="Quitarlo"
          danger
          busy={quitar.isPending}
          error={quitar.isError ? describeError(quitar.error) : undefined}
          onConfirm={() => quitar.mutate(quitando)}
          onClose={() => setQuitando(null)}
        />
      )}
    </Seccion>
  )
}

function NuevoFeriado({ anio, onClose }: { anio: number; onClose: () => void }) {
  const avisar = useToast()
  const queryClient = useQueryClient()
  const [day, setDay] = useState(`${anio}-01-01`)
  const [name, setName] = useState('')
  const [kind, setKind] = useState<TipoFeriado>('nacional')

  const mutation = useMutation({
    mutationFn: () => setHoliday({ day, name: name.trim(), kind }),
    onSuccess: () => {
      avisar(`${name.trim()} el ${formatDay(day)}: ese día deja de contar como hábil.`)
      void queryClient.invalidateQueries({ queryKey: ['admin-holidays'] })
      onClose()
    },
  })

  return (
    <ConfirmDialog
      title="Añadir un feriado"
      summary="Ese día deja de contar como hábil para la tasa."
      detail={
        <div className="flex flex-col gap-3">
          <Input id="fer-dia" label="Día" type="date" value={day} onChange={setDay} />
          <Input id="fer-nombre" label="Qué es" value={name} onChange={setName} placeholder="Carnaval" />
          <div className="flex flex-col gap-shell-gap-stack">
            <DataLabel>Tipo</DataLabel>
            <Segmented etiqueta="Tipo" options={[...TIPOS]} value={kind} onChange={setKind} />
          </div>
        </div>
      }
      bloqueo={
        day === '' ? 'Elige el día.' : name.trim().length === 0 ? 'Falta el nombre del feriado.' : undefined
      }
      confirmLabel="Añadir"
      busy={mutation.isPending}
      error={mutation.isError ? describeError(mutation.error) : undefined}
      onConfirm={() => mutation.mutate()}
      onClose={onClose}
    />
  )
}
