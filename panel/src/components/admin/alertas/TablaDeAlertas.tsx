import { useState } from 'react'
import type { ReactNode } from 'react'
import { Link, useNavigate } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'

import { Badge, Button, ConfirmDialog, formatDateTime } from '@/components/ui'
import { DataTable, ENLACE_EN_CELDA } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { EstadoBadge } from '@/components/admin/EstadoBadge'
import { useToast } from '@/components/Toast'
import {
  GRAVEDAD,
  ROTULO_TIPO_ALERTA,
  describirAlerta,
} from '@/features/admin/riesgo/alertas'
import type { Alerta, TipoAlerta } from '@/features/admin/riesgo/alertas'
import { CLAVES_RIESGO, revisarAlerta } from '@/features/admin/riesgo/consultas'
import { csvInstante } from '@/lib/csv'
import { describeError } from '@/lib/supabase'

/** La pestaña de la ficha donde se ve lo que dispara cada alerta. */
const PESTANA: Record<TipoAlerta, 'resumen' | 'consumos'> = {
  cuenta_relacionada: 'resumen',
  consumo_sobre_cupo: 'consumos',
}

function QuePaso({ alerta }: { alerta: Alerta }) {
  const d = alerta.detalle
  return (
    <span className="block max-w-md whitespace-normal">
      {describirAlerta(d)}
      {/* La otra cuenta, enlazada: la alerta se revisa mirando las dos. */}
      {d.tipo === 'cuenta_relacionada' && (
        <>
          {' '}
          <Link
            to="/admin/pacientes/$id"
            params={{ id: d.otraPersona }}
            search={{ tab: 'resumen' }}
            className={ENLACE_EN_CELDA}
          >
            Ver a {d.otroNombre ?? 'la otra cuenta'}
          </Link>
        </>
      )}
    </span>
  )
}

function columnas(onRevisar: (a: Alerta) => void): Array<Column<Alerta>> {
  return [
    {
      key: 'persona',
      header: 'Paciente',
      identity: true,
      cell: (a) => (
        <Link
          to="/admin/pacientes/$id"
          params={{ id: a.personaId }}
          search={{ tab: PESTANA[a.tipo] }}
          className={ENLACE_EN_CELDA}
        >
          {a.nombre ?? 'Sin nombre'}
        </Link>
      ),
      sort: (a) => a.nombre ?? '',
      csv: (a) => a.nombre ?? '',
    },
    {
      key: 'tipo',
      header: 'Tipo',
      cell: (a) => ROTULO_TIPO_ALERTA[a.tipo],
      sort: (a) => ROTULO_TIPO_ALERTA[a.tipo],
      csv: (a) => ROTULO_TIPO_ALERTA[a.tipo],
    },
    {
      key: 'gravedad',
      header: 'Gravedad',
      cell: (a) => (
        <Badge tone={GRAVEDAD[a.gravedad].tono} icono>
          {GRAVEDAD[a.gravedad].rotulo}
        </Badge>
      ),
      sort: (a) => (a.gravedad === 'alta' ? 0 : 1),
      csv: (a) => GRAVEDAD[a.gravedad].rotulo,
    },
    {
      key: 'que',
      header: 'Qué pasó',
      cell: (a) => <QuePaso alerta={a} />,
      csv: (a) => describirAlerta(a.detalle),
    },
    {
      key: 'estado-persona',
      header: 'Estado de la cuenta',
      hidden: true,
      cell: (a) => <EstadoBadge tipo="persona" valor={a.estadoPersona} />,
      csv: (a) => a.estadoPersona,
    },
    {
      key: 'detectada',
      header: 'Detectada',
      cell: (a) => formatDateTime(a.detectadaEn),
      sort: (a) => a.detectadaEn,
      sortDir: 'desc',
      csv: (a) => csvInstante(a.detectadaEn),
    },
    {
      key: 'revision',
      header: 'Revisión',
      cell: (a) =>
        a.revisada ? (
          <span className="block max-w-xs whitespace-normal type-panel-caption text-on-surface-variant">
            Revisada el {formatDateTime(a.revisadaEn)}
            {a.revisadaPor ? ` por ${a.revisadaPor}` : ''}
            {a.nota ? `. ${a.nota}` : ''}
          </span>
        ) : (
          <Button size="sm" variant="tonal" onClick={() => onRevisar(a)}>
            Marcar como revisada
          </Button>
        ),
      sort: (a) => (a.revisada ? 1 : 0),
      csv: (a) => (a.revisada ? `Revisada ${csvInstante(a.revisadaEn)}` : 'Pendiente'),
    },
  ]
}

/**
 * Las alertas en una tabla. La fila abre a la persona en la pestaña donde se
 * ve lo que disparó la alerta; «Marcar como revisada» pide una nota, porque
 * quien la mire después necesita saber por qué se dio por buena.
 */
export function TablaDeAlertas({
  alertas,
  resumen,
}: {
  alertas: Alerta[]
  resumen: ReactNode
}) {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const avisar = useToast()
  const [revisando, setRevisando] = useState<Alerta | null>(null)

  const revisar = useMutation({
    mutationFn: ({ clave, nota }: { clave: string; nota: string }) => revisarAlerta(clave, nota),
    onSuccess: () => {
      avisar('Alerta marcada como revisada')
      setRevisando(null)
      void queryClient.invalidateQueries({ queryKey: CLAVES_RIESGO.alertas })
    },
  })

  return (
    <>
      <DataTable
        rows={alertas}
        rowKey={(a) => a.clave}
        columns={columnas(setRevisando)}
        noun={['alerta', 'alertas']}
        summary={resumen}
        exportar={{ archivo: 'alertas-de-riesgo' }}
        rowTone={(a) => (!a.revisada && a.gravedad === 'alta' ? 'error' : undefined)}
        onRowClick={(a) =>
          void navigate({
            to: '/admin/pacientes/$id',
            params: { id: a.personaId },
            search: { tab: PESTANA[a.tipo] },
          })
        }
      />

      {revisando && (
        <ConfirmDialog
          title="Marcar la alerta como revisada"
          summary={`${ROTULO_TIPO_ALERTA[revisando.tipo]} de ${
            revisando.nombre ?? 'un paciente sin nombre'
          }. ${describirAlerta(revisando.detalle)}`}
          nivel="sensible"
          reasonLabel="Qué se comprobó"
          reasonPlaceholder="Son hermanos y comparten el teléfono de la casa"
          confirmLabel="Marcar como revisada"
          busy={revisar.isPending}
          error={revisar.isError ? describeError(revisar.error) : undefined}
          onConfirm={(nota) => revisar.mutate({ clave: revisando.clave, nota })}
          onClose={() => {
            setRevisando(null)
            revisar.reset()
          }}
        />
      )}
    </>
  )
}
