import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { FileImage } from 'lucide-react'

import { VerCaptura } from '@/components/admin/caja/VerCaptura'
import { FiltroFechas } from '@/components/FiltrosDeLista'
import { DataTable, ENLACE_EN_CELDA } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import {
  Badge,
  Callout,
  ConfirmDialog,
  EmptyState,
  ErrorBox,
  FilterBar,
  Filtro,
  Segmented,
  SkeletonTable,
  Stat,
  StatGrid,
  formatDateTime,
  formatDay,
  formatPhone,
  formatVes,
  hoyCaracas,
} from '@/components/ui'
import type { BadgeTone } from '@/components/ui'
import { ESTADO_DE_LA_LECTURA, motivoDeLaLectura } from '@/features/admin/lectorComprobantes'
import type { EstadoLectura, Lectura, ModoLector } from '@/features/admin/lectorComprobantes'
import { cambiarModoLector, fetchRevisionLector } from '@/features/admin/lectorComprobantesApi'
import { nombreDelMedio } from '@/features/admin/liquidaciones'
import { useIsSuperAdmin } from '@/features/admin/role'
import { csvDinero, csvInstante } from '@/lib/csv'
import { describeError } from '@/lib/supabase'

/** La clave de la consulta: la usa también la insignia de la pestaña. */
export const CLAVE_LECTURAS = 'receipt-reads'

/** Sin fechas, los últimos 7 días. */
export function haceUnaSemana(): string {
  const d = new Date(`${hoyCaracas()}T12:00:00Z`)
  d.setUTCDate(d.getUTCDate() - 7)
  return d.toISOString().slice(0, 10)
}

type Mostrar = 'todas' | 'equipo'

const OPCIONES_MOSTRAR: Array<{ value: Mostrar; label: string }> = [
  { value: 'todas', label: 'Todas' },
  { value: 'equipo', label: 'Para el equipo' },
]

const MODOS: Array<{ value: ModoLector; label: string }> = [
  { value: 'apagado', label: 'Apagado' },
  { value: 'sombra', label: 'Sombra' },
  { value: 'activo', label: 'Activo' },
]

const QUE_HACE: Record<ModoLector, string> = {
  apagado: 'No lee nada: las capturas las registra el equipo, como siempre.',
  sombra: 'Lee cada captura y anota lo que haría, sin registrar pagos. «Registrar pago» llega relleno con lo que leyó.',
  activo: 'Registra los pagos que lee (o que el paciente escribe) y el aviso del BNC los coteja. Lo que no cuadra queda para el equipo.',
}

const TONO: Record<EstadoLectura, BadgeTone> = {
  pendiente: 'neutral',
  leyendo: 'neutral',
  esperando_referencia: 'warning',
  esperando_aviso: 'warning',
  registrado: 'success',
  duplicado: 'neutral',
  para_el_equipo: 'error',
  descartado: 'neutral',
  sombra: 'brand',
}

/**
 * La pestaña «Comprobantes» de Pagos reportados: lo que hizo el lector con
 * cada captura (o datos escritos) que mandaron los pacientes por WhatsApp
 * (docs/03). En sombra es la prueba para activarlo: lo que «habría
 * registrado» tiene que coincidir con lo que registró el equipo.
 */
export function PestanaComprobantes({
  desde,
  hasta,
  onFechas,
}: {
  desde: string | undefined
  hasta: string | undefined
  onFechas: (rango: { desde: string | undefined; hasta: string | undefined }) => void
}) {
  const [mostrar, setMostrar] = useState<Mostrar>('todas')
  const [modoNuevo, setModoNuevo] = useState<ModoLector | null>(null)
  const esSuperAdmin = useIsSuperAdmin()
  const queryClient = useQueryClient()

  const p = { desde: desde ?? haceUnaSemana(), hasta: hasta ?? hoyCaracas() }
  const query = useQuery({
    queryKey: [CLAVE_LECTURAS, p.desde, p.hasta],
    queryFn: () => fetchRevisionLector(p.desde, p.hasta),
  })

  const modo = useMutation({
    mutationFn: ({ nuevo, motivo }: { nuevo: ModoLector; motivo: string }) => cambiarModoLector(nuevo, motivo),
    onSuccess: async () => {
      setModoNuevo(null)
      await queryClient.invalidateQueries({ queryKey: [CLAVE_LECTURAS] })
    },
  })

  const filtros = (
    <FilterBar>
      <FiltroFechas id="lecturas-fechas" label="Llegaron" desde={desde} hasta={hasta} onChange={onFechas} />
      <Filtro label="Mostrar">
        <Segmented options={OPCIONES_MOSTRAR} value={mostrar} onChange={setMostrar} />
      </Filtro>
      {query.data && esSuperAdmin && (
        <div className="ml-auto">
          <Filtro label="Modo del lector">
            <Segmented
              options={MODOS}
              value={query.data.modo}
              onChange={(m) => {
                if (m === query.data.modo) return
                modo.reset()
                setModoNuevo(m)
              }}
            />
          </Filtro>
        </div>
      )}
    </FilterBar>
  )

  if (query.isPending) {
    return (
      <>
        {filtros}
        <SkeletonTable rows={6} />
      </>
    )
  }

  if (query.isError) {
    return (
      <>
        {filtros}
        <ErrorBox title="No se pudieron cargar los comprobantes" detail={describeError(query.error)} />
      </>
    )
  }

  const d = query.data
  const filas = mostrar === 'todas' ? d.lecturas : d.lecturas.filter((l) => l.estado === 'para_el_equipo')
  const registradas = d.lecturas.filter((l) => l.estado === 'registrado').length
  const habria = d.lecturas.filter((l) => l.estado === 'sombra' && l.motivo === 'registraria').length
  const alEquipo = d.lecturas.filter((l) => l.estado === 'para_el_equipo').length
  const esperando = d.lecturas.filter((l) => l.estado === 'esperando_aviso' || l.estado === 'esperando_referencia').length

  return (
    <>
      {filtros}

      <Callout
        tone={d.modo === 'activo' ? 'success' : 'info'}
        titulo={`El lector está ${rotuloModo(d.modo)}`}
        detalles={
          [
            d.modoDesde && `Desde el ${formatDateTime(d.modoDesde)}${d.modoPor ? `, por ${d.modoPor}` : ''}.`,
            d.modo !== 'apagado' && `Como mucho ${d.topeDiario} comprobantes por teléfono y día; los demás, al equipo.`,
          ]
            .filter(Boolean)
            .join(' ') || undefined
        }
      >
        {QUE_HACE[d.modo]}
      </Callout>

      {d.paraRevisar > 0 && (
        <Callout
          tone="warning"
          titulo={`${d.paraRevisar} ${d.paraRevisar === 1 ? 'comprobante espera' : 'comprobantes esperan'} al equipo`}
          detalles="De los últimos 7 días, sin un pago registrado después. «Registrar pago» desde la ficha del paciente llega relleno con lo que leyó."
        >
          El bot no pudo registrarlos solo: míralos con «Para el equipo».
        </Callout>
      )}

      <StatGrid cols={4}>
        <Stat label="Comprobantes recibidos" value={String(d.lecturas.length)} hint="Capturas y datos escritos" />
        <Stat
          label={d.modo === 'sombra' ? 'Habría registrado' : 'Registró el bot'}
          value={String(d.modo === 'sombra' ? habria : registradas)}
          info="Pagos cuyo monto salda cuotas completas al céntimo, con su referencia. Después los coteja el aviso del BNC, como los del equipo."
        />
        <Stat label="Para el equipo" value={String(alEquipo)} hint="No cuadraron o no se pudieron leer" />
        <Stat label="Esperando" value={String(esperando)} hint="La referencia o el SMS del BNC (24 h)" />
      </StatGrid>

      {filas.length === 0 ? (
        <EmptyState
          icon={<FileImage size={40} />}
          title={d.lecturas.length === 0 ? 'Todavía no ha llegado ningún comprobante' : 'Nada para el equipo'}
          description={
            d.lecturas.length === 0
              ? d.modo === 'apagado'
                ? 'Con el lector apagado no se lee ninguna captura.'
                : 'Cada captura de pago que manden los pacientes por WhatsApp aparecerá aquí.'
              : 'El bot resolvió todos los comprobantes de estas fechas.'
          }
        />
      ) : (
        <DataTable
          rows={filas}
          rowKey={(l) => l.id}
          columns={COLUMNAS}
          noun={['comprobante', 'comprobantes']}
          exportar={{ archivo: `comprobantes-whatsapp-${hoyCaracas()}` }}
        />
      )}

      {modoNuevo && (
        <ConfirmDialog
          nivel={modoNuevo === 'activo' ? 'critico' : 'sensible'}
          title={`Poner el lector ${rotuloModo(modoNuevo)}`}
          summary={
            modoNuevo === 'activo'
              ? 'Desde que confirmes, el bot registra los pagos que lee y deja de callarse tras una captura. Aprobarlos sigue dependiendo del modo del aviso del BNC.'
              : QUE_HACE[modoNuevo]
          }
          reasonPlaceholder={modoNuevo === 'activo' ? 'La sombra coincidió con el equipo' : 'Pausa mientras se revisa'}
          confirmLabel={`Poner ${rotuloModo(modoNuevo)}`}
          danger={modoNuevo === 'activo'}
          busy={modo.isPending}
          error={modo.isError ? describeError(modo.error) : undefined}
          onConfirm={(motivo) => modo.mutate({ nuevo: modoNuevo, motivo })}
          onClose={() => setModoNuevo(null)}
        />
      )}
    </>
  )
}

function rotuloModo(m: ModoLector): string {
  return m === 'apagado' ? 'apagado' : m === 'sombra' ? 'en sombra' : 'activo'
}

const COLUMNAS: Array<Column<Lectura>> = [
  {
    key: 'llego',
    header: 'Llegó',
    identity: true,
    sort: (l) => l.llego,
    sortDir: 'desc',
    csv: (l) => csvInstante(l.llego),
    cell: (l) => (
      <span className="block whitespace-nowrap">
        {formatDateTime(l.llego)}
        <span className="block type-panel-caption text-on-surface-variant">
          {l.tipo === 'captura' ? 'Captura' : 'Datos escritos'}
          {l.modo === 'sombra' && ' · en sombra'}
        </span>
      </span>
    ),
  },
  {
    key: 'paciente',
    header: 'Paciente',
    sort: (l) => l.persona,
    csv: (l) => l.persona,
    cell: (l) => (
      <span className="block">
        <Link to="/admin/pacientes/$id" params={{ id: l.userId }} className={ENLACE_EN_CELDA}>
          {l.persona}
        </Link>
        <span className="block type-panel-caption text-on-surface-variant">{formatPhone(l.telefono)}</span>
      </span>
    ),
  },
  {
    key: 'leyo',
    header: 'Lo que leyó',
    csv: (l) => [l.montoVes === null ? null : csvDinero(l.montoVes), l.referencia, l.banco].filter(Boolean).join(' · '),
    cell: (l) => (
      <span className="block">
        <span className="font-semibold">{l.montoVes === null ? 'Sin monto' : formatVes(l.montoVes)}</span>
        <span className="block font-mono type-panel-caption">{l.referencia ?? 'Sin referencia'}</span>
        <span className="block type-panel-caption text-on-surface-variant">
          {[l.metodo ? nombreDelMedio(l.metodo) : null, l.banco, l.pagadoEl ? formatDay(l.pagadoEl) : null]
            .filter(Boolean)
            .join(' · ')}
          {l.telefonoPagador && ` · desde ${formatPhone(l.telefonoPagador)}`}
        </span>
        {l.rutaCaptura && (
          <span className="mt-1 block">
            <VerCaptura ruta={l.rutaCaptura} rotulo="Ver la captura" />
          </span>
        )}
      </span>
    ),
  },
  {
    key: 'bot',
    header: 'El bot',
    sort: (l) => l.estado,
    csv: (l) => `${ESTADO_DE_LA_LECTURA[l.estado]}${l.motivo ? ` (${motivoDeLaLectura(l.motivo)})` : ''}`,
    cell: (l) => (
      <span className="block max-w-60">
        <Badge tone={TONO[l.estado]}>{ESTADO_DE_LA_LECTURA[l.estado]}</Badge>
        {l.motivo && (
          <span className="mt-1 block type-panel-caption text-on-surface-variant">{motivoDeLaLectura(l.motivo)}</span>
        )}
        {l.error && <span className="mt-1 block type-panel-caption text-on-surface-variant">{l.error}</span>}
      </span>
    ),
  },
  {
    key: 'pago',
    header: 'El pago',
    csv: (l) => l.reportId,
    cell: (l) =>
      l.reportId ? (
        <Link to="/admin/cobros/$id" params={{ id: l.reportId }} className={ENLACE_EN_CELDA}>
          Ver el pago
        </Link>
      ) : (
        <span className="text-on-surface-variant">—</span>
      ),
  },
]
