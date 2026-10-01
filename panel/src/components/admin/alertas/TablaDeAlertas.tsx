import { useState } from 'react'
import type { ReactNode } from 'react'
import { Link, useNavigate } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'

import { Badge, Button, ConfirmDialog, InfoDot, formatDateTime } from '@/components/ui'
import { DataTable, ENLACE_EN_CELDA } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { EstadoBadge } from '@/components/admin/EstadoBadge'
import { useToast } from '@/components/Toast'
import {
  GRAVEDAD,
  ROTULO_SUJETO,
  ROTULO_TIPO_ALERTA,
  TIPOS,
  clinicaDeLaAlerta,
  describirAlerta,
} from '@/features/admin/riesgo/alertas'
import type { Alerta, TipoAlerta } from '@/features/admin/riesgo/alertas'
import { CLAVES_RIESGO, revisarAlerta } from '@/features/admin/riesgo/consultas'
import { csvInstante } from '@/lib/csv'
import { describeError } from '@/lib/supabase'

/** La pestaña de la ficha del paciente donde se ve lo que dispara cada alerta. */
const PESTANA_PACIENTE: Partial<
  Record<TipoAlerta, 'resumen' | 'datos' | 'consumos' | 'pagos'>
> = {
  cuenta_relacionada: 'resumen',
  consumo_sobre_cupo: 'consumos',
  telefono_repetido: 'datos',
  correo_repetido: 'datos',
  correo_rebotado: 'datos',
  referencia_repetida: 'pagos',
  cupo_al_limite_al_estrenar: 'consumos',
}

/**
 * Adónde lleva una alerta: al paciente en la pestaña que la explica, a la
 * clínica en sus alertas o —si es de alguien del personal— a su clínica en
 * la pestaña Personal. `null` si la alerta no dice de quién es.
 */
export function destinoDeAlerta(a: Alerta) {
  if (a.personaId) {
    return {
      to: '/admin/pacientes/$id',
      params: { id: a.personaId },
      search: { tab: PESTANA_PACIENTE[a.tipo] ?? 'resumen' },
    } as const
  }
  const clinica = clinicaDeLaAlerta(a)
  if (!clinica) return null
  return {
    to: '/admin/clinicas/$id',
    params: { id: clinica },
    search: { tab: a.sujeto.tipo === 'personal' ? 'personal' : 'alertas' },
  } as const
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

function Sujeto({ alerta }: { alerta: Alerta }) {
  const destino = destinoDeAlerta(alerta)
  const nombre = alerta.nombre ?? 'Sin nombre'
  return (
    <>
      {destino?.to === '/admin/pacientes/$id' ? (
        <Link to={destino.to} params={destino.params} search={destino.search} className={ENLACE_EN_CELDA}>
          {nombre}
        </Link>
      ) : destino?.to === '/admin/clinicas/$id' ? (
        <Link to={destino.to} params={destino.params} search={destino.search} className={ENLACE_EN_CELDA}>
          {nombre}
        </Link>
      ) : (
        <span className="text-on-surface">{nombre}</span>
      )}
      <span className="mt-0.5 block type-panel-caption text-on-surface-variant">
        {ROTULO_SUJETO[alerta.sujeto.tipo]}
      </span>
    </>
  )
}

function columnas(onRevisar: (a: Alerta) => void, conSujeto: boolean): Array<Column<Alerta>> {
  const todas: Array<Column<Alerta>> = [
    {
      key: 'sujeto',
      header: 'De quién',
      identity: true,
      cell: (a) => <Sujeto alerta={a} />,
      sort: (a) => a.nombre ?? '',
      csv: (a) => a.nombre ?? '',
    },
    {
      key: 'tipo',
      header: 'Tipo',
      cell: (a) => (
        <span className="inline-flex items-center gap-1">
          {ROTULO_TIPO_ALERTA[a.tipo]}
          <InfoDot title={ROTULO_TIPO_ALERTA[a.tipo]} what={TIPOS[a.tipo].descripcion} />
        </span>
      ),
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
      cell: (a) => (a.personaId ? <EstadoBadge tipo="persona" valor={a.estadoPersona} /> : '—'),
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
  return conSujeto ? todas : todas.filter((c) => c.key !== 'sujeto')
}

/**
 * Las alertas en una tabla. La fila abre a quien la disparó: el paciente en
 * la pestaña donde se ve, o la clínica. «Marcar como revisada» pide una nota,
 * porque quien la mire después necesita saber por qué se dio por buena.
 *
 * `conSujeto` en falso quita la columna «De quién»: en la ficha de una
 * clínica todas son de ella o de su personal.
 */
export function TablaDeAlertas({
  alertas,
  resumen,
  conSujeto = true,
}: {
  alertas: Alerta[]
  resumen: ReactNode
  conSujeto?: boolean
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
        columns={columnas(setRevisando, conSujeto)}
        noun={['alerta', 'alertas']}
        summary={resumen}
        exportar={{ archivo: 'alertas-de-riesgo' }}
        rowTone={(a) => (!a.revisada && a.gravedad === 'alta' ? 'error' : undefined)}
        onRowClick={(a) => {
          const destino = destinoDeAlerta(a)
          // Una rama por ruta: cada una con la búsqueda de la suya.
          if (destino?.to === '/admin/pacientes/$id') void navigate(destino)
          else if (destino) void navigate(destino)
        }}
      />

      {revisando && (
        <ConfirmDialog
          title="Marcar la alerta como revisada"
          summary={`${ROTULO_TIPO_ALERTA[revisando.tipo]} de ${
            revisando.nombre ?? 'alguien sin nombre'
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
