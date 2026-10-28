import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { useToast } from '@/components/Toast'
import { Button, ErrorBox, Input, Modal, Select, Textarea } from '@/components/ui'
import { consultaEquipoDeLaAgenda, guardarLead, refrescarAgenda } from '@/features/admin/agenda/api'
import type { LeadGuardado } from '@/features/admin/agenda/api'
import {
  NOTA_MAXIMA,
  borradorDeLead,
  motivoParaNoGuardar,
} from '@/features/admin/agenda/agenda'
import type { BorradorDeLead, Lead } from '@/features/admin/agenda/agenda'
import { describeError } from '@/lib/supabase'

const SIN = 'ninguno'

/** Las especialidades de Helios, como sugerencias: se puede escribir otra. */
const ESPECIALIDADES = ['Medicina general', 'Odontología', 'Cosmetología', 'Pediatría', 'Ginecología', 'Dermatología']

/**
 * Apuntar un médico en la agenda, o corregir sus datos (`lead`). Solo el
 * nombre es obligatorio: a veces se apunta con lo que se sabe y se completa
 * después.
 */
export function FormularioDeLead({
  lead,
  yo = null,
  onGuardado,
  onClose,
}: {
  lead?: Lead
  /** Quien apunta: un médico nuevo queda a su cargo, para que le salga en «Mis médicos». */
  yo?: string | null
  onGuardado: (guardado: LeadGuardado) => void
  onClose: () => void
}) {
  const client = useQueryClient()
  const avisar = useToast()
  const [borrador, setBorrador] = useState(() => (lead ? borradorDeLead(lead) : { ...borradorDeLead(), responsableId: yo ?? '' }))
  const equipo = useQuery(consultaEquipoDeLaAgenda())

  const guardar = useMutation({
    mutationFn: (b: BorradorDeLead) => guardarLead(lead?.id ?? null, b),
    onSuccess: (g) => {
      refrescarAgenda(client)
      if (g.estado === 'convertido' && lead?.estado !== 'convertido') {
        avisar(`${borrador.nombre.trim()} ya es cliente${g.clinica ? `: ${g.clinica}` : ''}. Quedó como afiliado.`)
      } else {
        avisar(lead ? 'Datos guardados.' : `${borrador.nombre.trim()} quedó en la agenda.`)
      }
      onGuardado(g)
    },
  })

  function cambiar(parte: Partial<BorradorDeLead>) {
    setBorrador((b) => ({ ...b, ...parte }))
  }

  // Todo el equipo activo, tenga el rol que tenga.
  const opcionesEquipo = [
    { value: SIN, label: 'Nadie' },
    ...(equipo.data ?? []).map((m) => ({ value: m.userId, label: m.nombre })),
  ]
  const bloqueo = motivoParaNoGuardar(borrador)

  return (
    <Modal title={lead ? `Editar a ${lead.nombre}` : 'Apuntar un médico'} width="lg" onClose={onClose}>
      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault()
          if (!bloqueo && !guardar.isPending) guardar.mutate(borrador)
        }}
      >
        <div className="grid gap-3 sm:grid-cols-2">
          <Input
            id="lead-nombre"
            label="Nombre del médico"
            value={borrador.nombre}
            placeholder="Dra. Nadia Khabbaze"
            autoFocus
            autoComplete="off"
            onChange={(nombre) => cambiar({ nombre })}
          />
          <div>
            <Input
              id="lead-especialidad"
              label="Especialidad (opcional)"
              value={borrador.especialidad}
              placeholder="Odontología"
              autoComplete="off"
              onChange={(especialidad) => cambiar({ especialidad })}
            />
            <div className="mt-1 flex flex-wrap gap-1">
              {ESPECIALIDADES.filter((e) => e !== borrador.especialidad).slice(0, 4).map((e) => (
                <button
                  key={e}
                  type="button"
                  className="rounded-full border border-panel-hairline px-2 py-0.5 type-panel-caption text-on-surface-variant hover:text-on-surface"
                  onClick={() => cambiar({ especialidad: e })}
                >
                  {e}
                </button>
              ))}
            </div>
          </div>
          <Input
            id="lead-telefono"
            label="Teléfono"
            type="tel"
            inputMode="tel"
            value={borrador.telefono}
            placeholder="0414 1234567"
            autoComplete="off"
            onChange={(telefono) => cambiar({ telefono })}
          />
          <Input
            id="lead-consultorio"
            label="Consultorio o centro (opcional)"
            value={borrador.consultorio}
            placeholder="Centro Médico Docente La Trinidad"
            autoComplete="off"
            onChange={(consultorio) => cambiar({ consultorio })}
          />
          <Input
            id="lead-direccion"
            label="Dirección"
            value={borrador.direccion}
            placeholder="Torre, piso, consultorio y ciudad"
            autoComplete="off"
            onChange={(direccion) => cambiar({ direccion })}
            className="sm:col-span-2"
          />
          <Select
            id="lead-responsable"
            label="Gestionado por"
            value={borrador.responsableId || SIN}
            options={opcionesEquipo}
            onChange={(v) => cambiar({ responsableId: v === SIN ? '' : v })}
          />
        </div>
        <Textarea
          id="lead-notas"
          label="Notas (opcional)"
          rows={3}
          maxLength={NOTA_MAXIMA}
          value={borrador.notas}
          placeholder="Quién lo refirió, horario en que atiende, lo que conviene saber antes de llamarlo."
          onChange={(notas) => cambiar({ notas })}
        />

        {guardar.isError && <ErrorBox title="No se pudo guardar" detail={describeError(guardar.error)} />}

        <div className="flex flex-wrap items-center justify-end gap-3">
          {bloqueo && <span className="type-panel-caption text-on-surface-variant">{bloqueo}</span>}
          <Button size="sm" variant="text" onClick={onClose}>
            Cancelar
          </Button>
          <Button size="sm" type="submit" disabled={!!bloqueo || guardar.isPending}>
            {guardar.isPending ? 'Guardando…' : lead ? 'Guardar' : 'Apuntar'}
          </Button>
        </div>
      </form>
    </Modal>
  )
}
