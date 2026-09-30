import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Mail, RotateCw } from 'lucide-react'

import { DataTable, ENLACE_EN_CELDA } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { BuscadorEnUrl } from '@/components/FiltrosDeLista'
import { Paginacion } from '@/components/Paginacion'
import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Card,
  EmptyState,
  ErrorBox,
  FilterBar,
  Filtro,
  Input,
  Modal,
  NoSePudoLeer,
  Segmented,
  SkeletonTable,
  Textarea,
  formatDateTime,
} from '@/components/ui'
import {
  CLAVE_AVISOS,
  consultaCorreosRecientes,
  consultaHistorialDeAvisos,
  reenviarComprobante,
} from '@/features/admin/avisos/api'
import { correoValido, estadoDeCorreo, rebotadosSinCorregir } from '@/features/admin/avisos/avisos'
import type { Aviso } from '@/features/admin/avisos/avisos'
import { actualizarContactoDelPaciente } from '@/features/admin/pacientes/api'
import { csvInstante } from '@/lib/csv'
import { describeError } from '@/lib/supabase'

export type FiltroDeCorreos = 'rebotados' | 'pendiente' | 'enviado' | 'fallido'
export const FILTROS_DE_CORREOS: readonly FiltroDeCorreos[] = ['rebotados', 'pendiente', 'enviado', 'fallido']

const POR_PAGINA = 50

/**
 * «Correos»: el historial de lo que salió por correo (el comprobante de cada
 * financiamiento y el recordatorio de la víspera), con lo último que dijo el
 * proveedor. «Rebotados» son los que no llegaron y nadie ha corregido:
 * se reenvían desde aquí, corrigiendo el correo si hace falta.
 */
export function Correos({
  filtro,
  q,
  pagina,
  onCambiar,
}: {
  filtro: FiltroDeCorreos | undefined
  q: string | undefined
  pagina: number
  onCambiar: (patch: { estado?: FiltroDeCorreos; q?: string; pagina?: number }) => void
}) {
  const [reenviando, setReenviando] = useState<Aviso | null>(null)

  // Los rebotados sin corregir salen de los últimos correos: no hay filtro
  // por evento en la base, y un rebote corregido es el que tiene otro
  // correo después.
  const rebotados = useQuery({ ...consultaCorreosRecientes(), enabled: filtro === 'rebotados' })
  const historial = useQuery({
    ...consultaHistorialDeAvisos({
      canal: 'email',
      estado: filtro === 'rebotados' ? null : (filtro ?? null),
      q: q ?? null,
      limite: POR_PAGINA,
      desde: (pagina - 1) * POR_PAGINA,
    }),
    enabled: filtro !== 'rebotados',
    placeholderData: keepPreviousData,
  })

  const q_ = (q ?? '').toLowerCase()
  const filas =
    filtro === 'rebotados'
      ? rebotadosSinCorregir(rebotados.data?.filas ?? []).filter(
          (c) => !q_ || `${c.patientName ?? ''} ${c.email ?? ''}`.toLowerCase().includes(q_),
        )
      : (historial.data?.filas ?? [])
  const consulta = filtro === 'rebotados' ? rebotados : historial
  const total =
    filtro === 'rebotados'
      ? filas.length
      : (historial.data?.total ?? (filas.length === POR_PAGINA ? pagina * POR_PAGINA + 1 : (pagina - 1) * POR_PAGINA + filas.length))

  return (
    <>
      <FilterBar>
        <Filtro label="Estado">
          <Segmented
            options={[
              { value: 'todos', label: 'Todos' },
              { value: 'rebotados', label: 'Rebotados' },
              { value: 'pendiente', label: 'En cola' },
              { value: 'enviado', label: 'Enviados' },
              { value: 'fallido', label: 'Fallidos' },
            ]}
            value={filtro ?? 'todos'}
            onChange={(v) => onCambiar({ estado: FILTROS_DE_CORREOS.find((f) => f === v), pagina: undefined })}
          />
        </Filtro>
        <BuscadorEnUrl
          id="correos-buscar"
          valor={q}
          onBuscar={(texto) => onCambiar({ q: texto, pagina: undefined })}
          placeholder="Paciente o correo"
          className="w-72"
        />
      </FilterBar>

      {consulta.isPending && <SkeletonTable rows={6} columns={5} />}
      {consulta.isError && (
        <Card>
          <NoSePudoLeer onReintentar={() => void consulta.refetch()} />
        </Card>
      )}

      {consulta.isSuccess && filas.length === 0 && (
        <EmptyState
          icon={<Mail size={40} />}
          title={filtro === 'rebotados' ? 'Ningún correo rebotado sin corregir' : 'Ningún correo con estos filtros'}
          description="Cada financiamiento confirmado manda el comprobante al correo del paciente, y la víspera de cada cuota, un recordatorio."
        />
      )}

      {consulta.isSuccess && filas.length > 0 && (
        <DataTable
          rows={filas}
          rowKey={(c) => c.id}
          columns={columnas(setReenviando)}
          noun={['correo', 'correos']}
          summary={filtro === 'rebotados' ? 'rebotados y sin reenviar a un correo que funcione' : undefined}
          exportar={{ archivo: `correos-${filtro ?? 'todos'}` }}
          rowTone={(c) => (c.lastEvent === 'bounced' || c.lastEvent === 'complained' ? 'error' : undefined)}
        />
      )}

      {filtro !== 'rebotados' && historial.isSuccess && (
        <Paginacion pagina={pagina} porPagina={POR_PAGINA} total={total} onPagina={(p) => onCambiar({ pagina: p })} />
      )}

      {reenviando && <ReenviarComprobante correo={reenviando} onClose={() => setReenviando(null)} />}
    </>
  )
}

function columnas(onReenviar: (c: Aviso) => void): Array<Column<Aviso>> {
  return [
    {
      key: 'paciente',
      header: 'Paciente',
      identity: true,
      sort: (c) => c.patientName,
      csv: (c) => c.patientName,
      cell: (c) => (
        <>
          {c.profileId ? (
            <Link to="/admin/pacientes/$id" params={{ id: c.profileId }} search={{ tab: 'datos' }} className={ENLACE_EN_CELDA}>
              {c.patientName ?? 'Sin nombre'}
            </Link>
          ) : (
            (c.patientName ?? 'Sin nombre')
          )}
          <span className="mt-0.5 block type-panel-caption text-on-surface-variant">{c.email ?? 'Sin correo'}</span>
        </>
      ),
    },
    {
      key: 'plantilla',
      header: 'Qué',
      sort: (c) => c.templateLabel,
      csv: (c) => c.templateLabel,
      cell: (c) => (
        <>
          {c.templateLabel}
          {c.orderNumber !== null && (
            <span className="mt-0.5 block type-panel-caption text-on-surface-variant">#{c.orderNumber}</span>
          )}
        </>
      ),
    },
    {
      key: 'creado',
      header: 'Encolado',
      sort: (c) => c.createdAt,
      sortDir: 'desc',
      csv: (c) => csvInstante(c.createdAt),
      cell: (c) => <span className="whitespace-nowrap">{formatDateTime(c.createdAt)}</span>,
    },
    {
      key: 'estado',
      header: 'Estado',
      info: 'Lo último que dijo el proveedor de correo: enviado, entregado, rebotado o marcado como spam. Sin nada, sigue en la cola (o falta configurar el envío).',
      sort: (c) => estadoDeCorreo(c).label,
      csv: (c) => estadoDeCorreo(c).label,
      cell: (c) => {
        const e = estadoDeCorreo(c)
        return (
          <>
            <Badge tone={e.tone} icono={e.tone !== 'neutral'}>
              {e.label}
            </Badge>
            {c.attempts > 1 && (
              <span className="mt-0.5 block type-panel-caption text-on-surface-variant">{c.attempts} intentos</span>
            )}
          </>
        )
      },
    },
    {
      key: 'proveedor',
      header: 'Id del proveedor',
      hidden: true,
      csv: (c) => c.providerId,
      cell: (c) => <span className="font-mono type-panel-caption">{c.providerId ?? '—'}</span>,
    },
    {
      key: 'reenviar',
      header: '',
      cell: (c) =>
        c.chargeId && c.templateKey === 'comprobante_financiamiento' ? (
          <Button size="sm" variant="tonal" onClick={() => onReenviar(c)}>
            <RotateCw size={13} aria-hidden /> Reenviar
          </Button>
        ) : null,
    },
  ]
}

/**
 * Reenviar el comprobante (`admin_resend_receipt`). Si el correo estaba mal,
 * se corrige antes en la ficha del paciente (`admin_update_patient_contact`,
 * con motivo: bitácora) y el comprobante sale al correo nuevo.
 */
function ReenviarComprobante({ correo, onClose }: { correo: Aviso; onClose: () => void }) {
  const client = useQueryClient()
  const avisar = useToast()
  const [nuevo, setNuevo] = useState('')
  const [motivo, setMotivo] = useState('')
  const corrige = nuevo.trim() !== '' && nuevo.trim().toLowerCase() !== (correo.email ?? '').toLowerCase()

  const bloqueo = corrige
    ? !correoValido(nuevo)
      ? 'El correo nuevo no parece un correo.'
      : !correo.profileId
        ? 'No se sabe de qué paciente es: corrígelo desde su ficha.'
        : motivo.trim().length < 5
          ? 'Escribe por qué se corrige el correo: queda en la bitácora.'
          : undefined
    : undefined

  const reenviar = useMutation({
    mutationFn: async () => {
      if (!correo.chargeId) throw new Error('Este correo no es de un financiamiento.')
      if (corrige && correo.profileId) {
        await actualizarContactoDelPaciente({
          userId: correo.profileId,
          cambios: { email: nuevo.trim().toLowerCase() },
          motivo,
        })
      }
      return reenviarComprobante({ chargeId: correo.chargeId })
    },
    onSuccess: (r) => {
      avisar(`Comprobante reenviado${r.email ? ` a ${r.email}` : ''}`)
      void client.invalidateQueries({ queryKey: CLAVE_AVISOS })
      if (correo.profileId) void client.invalidateQueries({ queryKey: ['admin-user', correo.profileId] })
      onClose()
    },
  })

  return (
    <Modal title="Reenviar el comprobante" width="sm" onClose={onClose}>
      <div className="flex flex-col gap-4">
        <p className="type-panel-body text-on-surface">
          El comprobante{correo.orderNumber !== null ? ` del financiamiento #${correo.orderNumber}` : ''} de{' '}
          {correo.patientName ?? 'este paciente'} se vuelve a mandar
          {correo.email ? ` a ${correo.email}` : ''}.
        </p>
        <Input
          id="reenviar-correo"
          label="Corregir el correo (opcional)"
          type="email"
          value={nuevo}
          onChange={setNuevo}
          placeholder={correo.email ?? 'correo@ejemplo.com'}
          hint="Vacío, se reenvía al que tiene registrado."
        />
        {corrige && (
          <Textarea
            id="reenviar-motivo"
            label="Por qué se corrige"
            value={motivo}
            onChange={setMotivo}
            rows={2}
            maxLength={300}
            placeholder="El paciente escribió por WhatsApp con su correo correcto"
          />
        )}
        {reenviar.isError && <ErrorBox title="No se pudo reenviar" detail={describeError(reenviar.error)} />}
        <div className="flex flex-wrap items-start gap-3">
          <Button
            size="md"
            disabled={bloqueo !== undefined || reenviar.isPending}
            motivoApagado={bloqueo}
            onClick={() => reenviar.mutate()}
          >
            {reenviar.isPending ? 'Reenviando…' : corrige ? 'Corregir y reenviar' : 'Reenviar'}
          </Button>
          <Button size="md" variant="text" onClick={onClose}>
            Cancelar
          </Button>
        </div>
      </div>
    </Modal>
  )
}
