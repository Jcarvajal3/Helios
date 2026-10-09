import { useState } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'

import { CamposDeAlta } from '@/components/afiliacion/CamposDeAlta'
import type { Column } from '@/components/DataTable'
import { useToast } from '@/components/Toast'
import { Badge, Button, ErrorBox, Modal, Textarea, formatDateTime } from '@/components/ui'
import { CLAVE_SOLICITUDES, aprobarSolicitud, rechazarSolicitud } from '@/features/admin/clinicas/api'
import { correccionesDeSolicitud, motivoDeAlta } from '@/features/admin/clinicas/clinicas'
import type { AltaDeClinica, SolicitudDeAfiliacion } from '@/features/admin/clinicas/clinicas'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

// ═══════════════════════════════════════════════════════════════════════════
// Las solicitudes de afiliación que mandan los médicos desde la portada
// (`/afiliacion`). Esperan en Clínicas › Pendientes hasta que un super admin
// las aprueba (nace la clínica) o las rechaza.
// ═══════════════════════════════════════════════════════════════════════════

export const columnasSolicitudes: Array<Column<SolicitudDeAfiliacion>> = [
  {
    key: 'consultorio',
    header: 'Consultorio',
    identity: true,
    sort: (s) => s.alta.clinicName,
    csv: (s) => s.alta.clinicName,
    cell: (s) => (
      <div>
        <p className="font-medium text-on-surface">{s.alta.clinicName}</p>
        <p className="type-panel-caption text-on-surface-variant">{s.alta.taxId || 'Sin RIF'}</p>
      </div>
    ),
  },
  {
    key: 'medico',
    header: 'Médico',
    sort: (s) => s.alta.ownerName,
    csv: (s) => s.alta.ownerName,
    cell: (s) => (
      <div>
        <p className="text-on-surface">{s.alta.ownerName}</p>
        <p className="type-panel-caption text-on-surface-variant">{s.alta.ownerDocument}</p>
      </div>
    ),
  },
  {
    key: 'especialidad',
    header: 'Especialidad',
    sort: (s) => s.alta.specialty,
    csv: (s) => s.alta.specialty,
    cell: (s) => s.alta.specialty,
  },
  {
    key: 'contacto',
    header: 'Contacto',
    csv: (s) => `${s.alta.phone} · ${s.alta.email}`,
    cell: (s) => (
      <div>
        <p className="text-on-surface">{s.alta.phone}</p>
        <p className="type-panel-caption text-on-surface-variant">{s.alta.email}</p>
      </div>
    ),
  },
  {
    key: 'recibida',
    header: 'Recibida',
    sort: (s) => s.createdAt,
    sortDir: 'desc',
    csv: (s) => s.createdAt,
    cell: (s) => (
      <span className="flex flex-col items-start gap-1">
        <Badge tone="warning">Pendiente</Badge>
        <span className="type-panel-caption text-on-surface-variant">{formatDateTime(s.createdAt)}</span>
      </span>
    ),
  },
]

/**
 * Revisar una solicitud: los datos del médico en el mismo formulario del
 * alta, por si hay que corregir algo antes de aprobar. Aprobar crea la
 * clínica (con su cuenta de pago) y lleva a su ficha; rechazar pide el motivo,
 * que queda para el equipo (al médico no se le manda nada).
 */
export function RevisarSolicitud({ solicitud, onClose }: { solicitud: SolicitudDeAfiliacion; onClose: () => void }) {
  const avisar = useToast()
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const isSuperAdmin = useIsSuperAdmin()

  const [alta, setAlta] = useState<AltaDeClinica>(solicitud.alta)
  const [rechazando, setRechazando] = useState(false)
  const [motivo, setMotivo] = useState('')

  const refrescar = () => {
    void queryClient.invalidateQueries({ queryKey: CLAVE_SOLICITUDES })
    void queryClient.invalidateQueries({ queryKey: ['merchants'] })
  }

  const aprobar = useMutation({
    mutationFn: () => aprobarSolicitud({ id: solicitud.id, correcciones: correccionesDeSolicitud(solicitud.alta, alta) }),
    onSuccess: (merchantId) => {
      avisar(`${alta.clinicName.trim()} aprobada y dada de alta. Le falta el personal`)
      refrescar()
      onClose()
      void navigate({ to: '/admin/clinicas/$id', params: { id: merchantId } })
    },
  })

  const rechazar = useMutation({
    mutationFn: () => rechazarSolicitud({ id: solicitud.id, motivo: motivo.trim() }),
    onSuccess: () => {
      avisar('Solicitud rechazada')
      refrescar()
      onClose()
    },
  })

  const ocupado = aprobar.isPending || rechazar.isPending
  const bloqueoAprobar = !isSuperAdmin ? SOLO_SUPER_ADMIN : (motivoDeAlta(alta) ?? undefined)
  const bloqueoRechazar = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : motivo.trim() === ''
      ? 'Escribe el motivo del rechazo.'
      : undefined

  return (
    <Modal title="Solicitud de afiliación" width="lg" onClose={onClose}>
      <div className="flex flex-col gap-6">
        <p className="type-panel-caption text-on-surface-variant">
          Recibida el {formatDateTime(solicitud.createdAt)}. Revisa los datos y corrige lo que haga falta antes de
          aprobar: al aprobar nace la clínica, activa y con esta cuenta de pago. Si quieres, añade su Pago Móvil.
        </p>

        <CamposDeAlta id={`solicitud-${solicitud.id}`} valor={alta} onChange={setAlta} />

        {aprobar.isError && <ErrorBox title="No se pudo aprobar" detail={describeError(aprobar.error)} />}
        {rechazar.isError && <ErrorBox title="No se pudo rechazar" detail={describeError(rechazar.error)} />}

        {rechazando ? (
          <div className="flex flex-col gap-3">
            <Textarea
              id={`solicitud-motivo-${solicitud.id}`}
              label="Motivo del rechazo (solo lo ve el equipo)"
              value={motivo}
              onChange={setMotivo}
              rows={3}
              maxLength={300}
              placeholder="No es un consultorio de salud, datos falsos…"
            />
            <div className="flex items-start gap-3">
              <Button
                size="md"
                variant="tonal"
                disabled={!!bloqueoRechazar || ocupado}
                motivoApagado={ocupado ? undefined : bloqueoRechazar}
                onClick={() => rechazar.mutate()}
              >
                {rechazar.isPending ? 'Rechazando…' : 'Rechazar la solicitud'}
              </Button>
              <Button variant="text" size="md" onClick={() => setRechazando(false)}>
                Volver
              </Button>
            </div>
          </div>
        ) : (
          <div className="flex flex-wrap items-start gap-3">
            <Button
              size="md"
              disabled={!!bloqueoAprobar || ocupado}
              motivoApagado={ocupado ? undefined : bloqueoAprobar}
              onClick={() => aprobar.mutate()}
            >
              {aprobar.isPending ? 'Aprobando…' : 'Aprobar y crear la clínica'}
            </Button>
            <Button
              variant="text"
              size="md"
              disabled={!isSuperAdmin || ocupado}
              title={isSuperAdmin ? undefined : SOLO_SUPER_ADMIN}
              onClick={() => setRechazando(true)}
            >
              Rechazar…
            </Button>
          </div>
        )}
      </div>
    </Modal>
  )
}
