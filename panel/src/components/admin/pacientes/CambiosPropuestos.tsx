import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { ArrowRight } from 'lucide-react'

import { ENLACE_EN_CELDA } from '@/components/DataTable'
import { useToast } from '@/components/Toast'
import { Button, Card, ConfirmDialog, formatDateTime, formatPhone } from '@/components/ui'
import { CLAVE_CAMBIOS_PROPUESTOS, resolverCambioPropuesto } from '@/features/admin/pacientes/api'
import type { CambioPropuesto } from '@/features/admin/pacientes/datos'
import { describeError } from '@/lib/supabase'

/** Un teléfono se lee como teléfono; lo demás, tal cual. */
function valor(campo: string, v: string | null): string {
  if (v === null) return '—'
  return campo.includes('phone') ? formatPhone(v) : v
}

/**
 * Los cambios de datos que propuso una clínica al registrar a un paciente que
 * ya existía (contrato §1.3 y §2.4). La clínica no sobrescribe nada: Helios
 * decide. Aprobar pone lo propuesto; rechazar deja lo que había. Las dos
 * cosas piden nota y quedan en la bitácora.
 */
export function CambiosPropuestos({
  cambios,
  conPaciente = true,
}: {
  cambios: ReadonlyArray<CambioPropuesto>
  /** En la ficha del paciente no hace falta decir de quién es. */
  conPaciente?: boolean
}) {
  const client = useQueryClient()
  const avisar = useToast()
  const [decidiendo, setDecidiendo] = useState<{ cambio: CambioPropuesto; aprobar: boolean } | null>(null)

  const resolver = useMutation({
    mutationFn: (p: { id: string; aprobar: boolean; nota: string }) => resolverCambioPropuesto(p),
    onSuccess: (_, p) => {
      avisar(p.aprobar ? 'Cambio aprobado: los datos del paciente ya son los nuevos' : 'Cambio rechazado')
      setDecidiendo(null)
      void client.invalidateQueries({ queryKey: CLAVE_CAMBIOS_PROPUESTOS })
      if (decidiendo) void client.invalidateQueries({ queryKey: ['admin-user', decidiendo.cambio.profileId] })
      void client.invalidateQueries({ queryKey: ['admin-users'] })
    },
  })

  return (
    <div className="flex flex-col gap-3">
      {cambios.map((c) => (
        <Card key={c.id} tone="inset">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              {conPaciente && (
                <Link
                  to="/admin/pacientes/$id"
                  params={{ id: c.profileId }}
                  search={{ tab: 'datos' }}
                  className={`type-panel-body font-semibold ${ENLACE_EN_CELDA}`}
                >
                  {c.patientName ?? 'Paciente sin nombre'}
                </Link>
              )}
              <p className="type-panel-caption text-on-surface-variant">
                Propuesto el {formatDateTime(c.createdAt)}
                {c.merchantName ? ` por ${c.merchantName}` : ''}
                {c.requestedByName ? ` (${c.requestedByName})` : ''}
              </p>
            </div>
            {c.status === 'pendiente' ? (
              <div className="flex gap-2">
                <Button size="sm" variant="tonal" onClick={() => setDecidiendo({ cambio: c, aprobar: false })}>
                  Rechazar
                </Button>
                <Button size="sm" onClick={() => setDecidiendo({ cambio: c, aprobar: true })}>
                  Aprobar
                </Button>
              </div>
            ) : (
              <p className="type-panel-caption text-on-surface-variant">
                {c.status === 'aprobado' ? 'Aprobado' : c.status === 'rechazado' ? 'Rechazado' : c.status}
                {c.resolvedAt ? ` el ${formatDateTime(c.resolvedAt)}` : ''}
                {c.resolvedByName ? ` por ${c.resolvedByName}` : ''}
                {c.note ? `. ${c.note}` : ''}
              </p>
            )}
          </div>

          {c.diferencias.length === 0 ? (
            <p className="mt-3 type-panel-caption text-on-surface-variant">
              Lo propuesto ya coincide con lo que hay.
            </p>
          ) : (
            <dl className="mt-3 grid grid-cols-1 gap-x-6 gap-y-2 sm:grid-cols-[minmax(0,12rem)_1fr]">
              {c.diferencias.map((d) => (
                <div key={d.campo} className="contents">
                  <dt className="type-panel-caption text-on-surface-variant">{d.rotulo}</dt>
                  <dd className="flex flex-wrap items-center gap-2 type-panel-body">
                    <span className="text-on-surface-variant line-through">{valor(d.campo, d.actual)}</span>
                    <ArrowRight size={12} aria-hidden className="text-on-surface-variant" />
                    <span className="font-semibold text-on-surface">{valor(d.campo, d.propuesto)}</span>
                  </dd>
                </div>
              ))}
            </dl>
          )}
        </Card>
      ))}

      {decidiendo && (
        <ConfirmDialog
          title={decidiendo.aprobar ? 'Aprobar el cambio' : 'Rechazar el cambio'}
          summary={
            decidiendo.aprobar
              ? `Los datos de ${decidiendo.cambio.patientName ?? 'este paciente'} pasan a ser los que propuso la clínica: ${decidiendo.cambio.diferencias.map((d) => d.rotulo.toLowerCase()).join(', ') || 'nada cambia'}.`
              : `Los datos de ${decidiendo.cambio.patientName ?? 'este paciente'} se quedan como están.`
          }
          nivel="sensible"
          reasonLabel={decidiendo.aprobar ? 'Cómo se comprobó' : 'Por qué no'}
          reasonPlaceholder={
            decidiendo.aprobar ? 'Lo confirmó el paciente por WhatsApp' : 'El paciente dice que su correo es el de siempre'
          }
          confirmLabel={decidiendo.aprobar ? 'Aprobar' : 'Rechazar'}
          busy={resolver.isPending}
          error={resolver.isError ? describeError(resolver.error) : undefined}
          onConfirm={(nota) => resolver.mutate({ id: decidiendo.cambio.id, aprobar: decidiendo.aprobar, nota })}
          onClose={() => {
            setDecidiendo(null)
            resolver.reset()
          }}
        />
      )}
    </div>
  )
}
