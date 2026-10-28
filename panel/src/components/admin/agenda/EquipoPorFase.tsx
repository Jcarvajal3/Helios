import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { CalendarDays, MessageCircle, Phone } from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

import { useToast } from '@/components/Toast'
import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { Chip, ErrorBox, Modal, SOLO_SUPER_ADMIN, SkeletonList } from '@/components/ui'
import { consultaEquipoDeLaAgenda, guardarFasesDe, refrescarAgenda } from '@/features/admin/agenda/api'
import { FASES, ROTULO_FASE } from '@/features/admin/agenda/agenda'
import type { Fase } from '@/features/admin/agenda/agenda'
import { useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

const ICONO_FASE: Record<Fase, LucideIcon> = {
  mensaje: MessageCircle,
  llamada: Phone,
  visita: CalendarDays,
}

/**
 * Quién trabaja cada fase. Decide el reparto: un médico que pasa a Llamada
 * o a Visita se le asigna solo a alguien de esa fase (el que menos lleva), y
 * «Asignarme médicos» toma de las fases de quien lo pulsa. Una persona puede
 * estar en varias. Lo cambia un super admin; cada clic se guarda al momento.
 */
export function EquipoPorFase({ onClose }: { onClose: () => void }) {
  const client = useQueryClient()
  const avisar = useToast()
  const esSuperAdmin = useIsSuperAdmin()
  const equipo = useQuery(consultaEquipoDeLaAgenda())

  const guardar = useMutation({
    mutationFn: ({ userId, fases }: { userId: string; fases: Fase[]; nombre: string }) => guardarFasesDe(userId, fases),
    onSuccess: (_, { nombre, fases }) => {
      refrescarAgenda(client)
      avisar(
        fases.length === 0
          ? `${nombre} ya no está en ninguna fase.`
          : `${nombre}: ${fases.map((f) => ROTULO_FASE[f].label).join(', ')}.`,
      )
    },
  })

  return (
    <Modal title="Equipo por fase" width="lg" onClose={onClose}>
      <div className="flex flex-col gap-4">
        <p className="type-panel-body text-on-surface-variant">
          Cuando un médico pasa a Llamada o a Visita, se le asigna solo a alguien de esa fase, al que menos médicos
          lleva en ella; si ya la había llevado alguien, vuelve a esa persona. Mensaje no reparte: sus médicos se toman
          con «Asignarme médicos», que da solo de las fases de quien lo pulsa.
        </p>

        {!esSuperAdmin && <p className="type-panel-caption text-on-surface-variant">{SOLO_SUPER_ADMIN}.</p>}

        {equipo.isPending && <SkeletonList rows={4} />}
        {equipo.isError && (
          <ErrorConReintento
            title="No se pudo leer el equipo"
            error={equipo.error}
            onReintentar={() => void equipo.refetch()}
          />
        )}

        {equipo.isSuccess && (
          <>
            <div className="grid gap-2 sm:grid-cols-3">
              {FASES.map((f) => {
                const Icono = ICONO_FASE[f]
                const quienes = equipo.data.filter((m) => m.fases.includes(f)).map((m) => m.nombre)
                return (
                  <div key={f} className="rounded-panel-control border border-panel-hairline px-3 py-2">
                    <p className="flex items-center gap-1.5 type-panel-control text-on-surface">
                      <Icono size={14} aria-hidden /> {ROTULO_FASE[f].label}
                    </p>
                    <p className="type-panel-caption text-on-surface-variant">
                      {quienes.length > 0 ? quienes.join(', ') : 'Nadie: sigue con quien lo llevaba'}
                    </p>
                  </div>
                )
              })}
            </div>

            <ul className="divide-y divide-panel-hairline rounded-panel-card border border-panel-hairline">
              {equipo.data.map((m) => (
                <li key={m.userId} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2.5">
                  <span className="min-w-0">
                    <span className="block type-panel-body text-on-surface">{m.nombre}</span>
                    <span className="block type-panel-caption text-on-surface-variant">
                      {m.rol === 'agenda' ? 'Agenda' : m.rol === 'super_admin' ? 'Super admin' : 'Operador'}
                    </span>
                  </span>
                  <span className="flex flex-wrap gap-1.5" role="group" aria-label={`Fases de ${m.nombre}`}>
                    {FASES.map((f) => {
                      const esta = m.fases.includes(f)
                      return (
                        <Chip
                          key={f}
                          selected={esta}
                          onClick={() => {
                            if (!esSuperAdmin || guardar.isPending) return
                            const fases = esta ? m.fases.filter((x) => x !== f) : FASES.filter((x) => x === f || m.fases.includes(x))
                            guardar.mutate({ userId: m.userId, fases, nombre: m.nombre })
                          }}
                        >
                          {ROTULO_FASE[f].label}
                        </Chip>
                      )
                    })}
                  </span>
                </li>
              ))}
            </ul>
          </>
        )}

        {guardar.isError && <ErrorBox title="No se pudo guardar" detail={describeError(guardar.error)} />}
      </div>
    </Modal>
  )
}
