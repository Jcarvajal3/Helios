import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { MessageSquareText } from 'lucide-react'

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
  SectionTitle,
  SkeletonTable,
  Stat,
  StatGrid,
  formatDateTime,
  formatUsd,
  formatVes,
  formatWaiting,
  hoyCaracas,
} from '@/components/ui'
import type { BadgeTone } from '@/components/ui'
import { comparar, resumir } from '@/features/admin/avisosBnc'
import type { AvisoBnc, Comparacion, DecisionBot, ModoBot, PagoSinAviso } from '@/features/admin/avisosBnc'
import { cambiarModoBot, fetchRevisionBot } from '@/features/admin/avisosBncApi'
import { useIsSuperAdmin } from '@/features/admin/role'
import { csvDinero, csvInstante } from '@/lib/csv'
import { describeError } from '@/lib/supabase'

/** Sin fechas, desde el primer aviso. */
const DESDE_SIEMPRE = '2026-01-01'

type Mostrar = 'todos' | 'revisar'

const OPCIONES_MOSTRAR: Array<{ value: Mostrar; label: string }> = [
  { value: 'todos', label: 'Todos' },
  { value: 'revisar', label: 'Lo que no cuadra' },
]

/** Lo que no cuadra: lo que hay que mirar antes de activar el bot. */
const A_REVISAR: ReadonlySet<Comparacion> = new Set(['equipo_rechazo', 'para_equipo', 'ilegible'])

const MODOS: Array<{ value: ModoBot; label: string }> = [
  { value: 'apagado', label: 'Apagado' },
  { value: 'sombra', label: 'Sombra' },
  { value: 'activo', label: 'Activo' },
]

const QUE_HACE: Record<ModoBot, string> = {
  apagado: 'Guarda los avisos y no los coteja.',
  sombra: 'Anota lo que aprobaría y no aprueba nada.',
  activo: 'Aprueba los pagos que encajan exactos con su aviso.',
}

const COMPARACION: Record<Comparacion, { texto: string; tone: BadgeTone }> = {
  coinciden: { texto: 'Coinciden', tone: 'success' },
  equipo_rechazo: { texto: 'El equipo lo rechazó', tone: 'error' },
  falta_equipo: { texto: 'Falta el equipo', tone: 'warning' },
  equipo_antes: { texto: 'El equipo fue antes', tone: 'neutral' },
  bot_aprobo: { texto: 'Aprobado por el bot', tone: 'brand' },
  para_equipo: { texto: 'Para el equipo', tone: 'neutral' },
  sin_reporte: { texto: 'Sin reporte', tone: 'neutral' },
  ilegible: { texto: 'Ilegible', tone: 'warning' },
}

const DECISION: Record<DecisionBot, string> = {
  aprobaria: 'Lo aprobaría',
  aprobado: 'Lo aprobó',
  ya_aprobado: 'Ya estaba aprobado',
  varios: 'Encaja con varios',
  telefono_distinto: 'Teléfono distinto',
  remitente_ajeno: 'No lo mandó el BNC',
  esperando: 'Esperando el reporte',
  ilegible: 'No pudo leer el SMS',
  error: 'Falló al aprobar',
}

const ESTADO_DEL_PAGO: Record<string, string> = {
  reported: 'Por aprobar',
  in_review: 'En revisión',
  reconciled: 'Aprobado',
  rejected: 'Rechazado',
  duplicate: 'Duplicado',
}

/**
 * La pestaña «Avisos del BNC» de Pagos reportados: lo que hizo el bot con
 * cada SMS de pago móvil frente a lo que hizo el equipo con el mismo pago.
 *
 * En sombra es la prueba para activarlo: «El equipo lo rechazó» tiene que ser cero.
 */
export function PestanaAvisos({
  desde,
  hasta,
  onFechas,
}: {
  desde: string | undefined
  hasta: string | undefined
  onFechas: (rango: { desde: string | undefined; hasta: string | undefined }) => void
}) {
  const [mostrar, setMostrar] = useState<Mostrar>('todos')
  const [modoNuevo, setModoNuevo] = useState<ModoBot | null>(null)
  const esSuperAdmin = useIsSuperAdmin()
  const queryClient = useQueryClient()

  const p = { desde: desde ?? DESDE_SIEMPRE, hasta: hasta ?? hoyCaracas() }
  const query = useQuery({
    queryKey: ['bank-sms-review', p.desde, p.hasta],
    queryFn: () => fetchRevisionBot(p.desde, p.hasta),
  })

  const modo = useMutation({
    mutationFn: ({ nuevo, motivo }: { nuevo: ModoBot; motivo: string }) => cambiarModoBot(nuevo, motivo),
    onSuccess: async () => {
      setModoNuevo(null)
      await queryClient.invalidateQueries({ queryKey: ['bank-sms-review'] })
    },
  })

  const filtros = (
    <FilterBar>
      <FiltroFechas id="avisos-fechas" label="Llegaron" desde={desde} hasta={hasta} onChange={onFechas} />
      <Filtro label="Mostrar">
        <Segmented options={OPCIONES_MOSTRAR} value={mostrar} onChange={setMostrar} />
      </Filtro>
      {/* Solo lo ve quien puede cambiarlo: el modo de todos va en el aviso de abajo. */}
      {query.data && esSuperAdmin && (
        <div className="ml-auto">
          <Filtro label="Modo del bot">
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
        <ErrorBox title="No se pudieron cargar los avisos del BNC" detail={describeError(query.error)} />
      </>
    )
  }

  const d = query.data
  const r = resumir(d.avisos)
  const filas = mostrar === 'todos' ? d.avisos : d.avisos.filter((a) => A_REVISAR.has(comparar(a)))
  const decididosPorEquipo = r.coinciden + r.equipoRechazo

  return (
    <>
      {filtros}

      <Callout tone={d.modo === 'activo' ? 'success' : 'info'} titulo={`El bot está ${rotuloModo(d.modo)}`}>
        {QUE_HACE[d.modo]}
        {d.modoDesde && ` Desde el ${formatDateTime(d.modoDesde)}${d.modoPor ? `, por ${d.modoPor}` : ''}.`}
      </Callout>

      {d.remitenteFijado === null && d.avisos.length > 0 && (
        <Callout tone="warning" titulo="Falta fijar el remitente del BNC">
          Hasta entonces cuenta cualquier SMS con el texto del banco. Antes de activar el bot, se fija con el
          remitente que enseñan los avisos.
        </Callout>
      )}

      {r.equipoRechazo > 0 && (
        <Callout tone="error" titulo={`El equipo rechazó ${r.equipoRechazo} ${r.equipoRechazo === 1 ? 'pago' : 'pagos'} que el bot aprobaría`}>
          Míralos con «Lo que no cuadra» antes de activar el bot.
        </Callout>
      )}

      <StatGrid cols={4}>
        <Stat
          label="Avisos recibidos"
          value={String(r.avisos)}
          hint={r.ilegibles > 0 ? `${r.ilegibles} sin leer` : 'Todos leídos'}
        />
        <Stat
          label="El bot aprobaría"
          value={String(r.aprobaria)}
          hint={`${r.paraEquipo} para el equipo · ${r.sinReporte} sin reporte`}
          info="Avisos que encajan exactos con un solo pago registrado: referencia, monto al céntimo y día del pago. Los pagos de Ronda entran a la misma cuenta y se quedan en «sin reporte»."
        />
        <Stat
          label="Coinciden con el equipo"
          value={decididosPorEquipo === 0 ? '—' : `${r.coinciden} de ${decididosPorEquipo}`}
          senal={r.equipoRechazo > 0 ? { tone: 'error', texto: `${r.equipoRechazo} rechazado por el equipo` } : undefined}
          hint={r.faltaEquipo > 0 ? `${r.faltaEquipo} esperan al equipo` : 'De los que el equipo ya decidió'}
          info="De los pagos que el bot aprobaría y el equipo ya decidió, cuántos aprobó también."
        />
        <Stat
          label="Ventaja del bot"
          value={r.medianaVentaja === null ? '—' : formatWaiting(r.medianaVentaja)}
          hint="Mediana: lo que tardó el equipo después"
          info="Entre el momento en que el bot lo habría aprobado y el momento en que lo aprobó el equipo."
        />
      </StatGrid>

      {filas.length === 0 ? (
        <EmptyState
          icon={<MessageSquareText size={40} />}
          title={d.avisos.length === 0 ? 'Todavía no ha llegado ningún aviso' : 'Todo cuadra'}
          description={
            d.avisos.length === 0
              ? 'Cada SMS de pago móvil del BNC que reenvíe el iPhone aparecerá aquí.'
              : 'Ningún aviso de estas fechas se aparta de lo que hizo el equipo.'
          }
        />
      ) : (
        <DataTable
          rows={filas}
          rowKey={(a) => a.id}
          columns={COLUMNAS}
          noun={['aviso', 'avisos']}
          exportar={{ archivo: `avisos-bnc-${hoyCaracas()}` }}
        />
      )}

      {d.sinAviso.length > 0 && (
        <>
          <SectionTitle className="mt-6">Aprobados sin aviso</SectionTitle>
          <p className="type-panel-caption text-on-surface-variant">
            Pagos móviles que el equipo aprobó y de los que no llegó SMS: el iPhone no lo mandó, o el pago entró a otra cuenta.
          </p>
          <DataTable
            rows={d.sinAviso}
            rowKey={(s) => s.id}
            columns={COLUMNAS_SIN_AVISO}
            noun={['pago', 'pagos']}
            exportar={{ archivo: `aprobados-sin-aviso-${hoyCaracas()}` }}
          />
        </>
      )}

      {modoNuevo && (
        <ConfirmDialog
          nivel={modoNuevo === 'activo' ? 'critico' : 'sensible'}
          title={`Poner el bot ${rotuloModo(modoNuevo)}`}
          summary={
            modoNuevo === 'activo'
              ? 'Desde que confirmes, el bot aprueba solo los pagos que encajan exactos con su aviso, y las aprobaciones salen firmadas con tu nombre.'
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

function rotuloModo(m: ModoBot): string {
  return m === 'apagado' ? 'apagado' : m === 'sombra' ? 'en sombra' : 'activo'
}

const COLUMNAS: Array<Column<AvisoBnc>> = [
  {
    key: 'llego',
    header: 'Llegó',
    identity: true,
    sort: (a) => a.recibidoEn,
    sortDir: 'desc',
    csv: (a) => csvInstante(a.recibidoEn),
    cell: (a) => <span className="whitespace-nowrap">{formatDateTime(a.recibidoEn)}</span>,
  },
  {
    key: 'sms',
    header: 'El SMS',
    csv: (a) => a.texto,
    cell: (a) =>
      a.referencia === null ? (
        <span className="block max-w-64 type-panel-caption text-on-surface-variant">{a.texto}</span>
      ) : (
        <span className="block">
          <span className="font-semibold">{formatVes(a.montoVes ?? 0)}</span>
          <span className="block font-mono type-panel-caption">{a.referencia}</span>
          <span className="block type-panel-caption text-on-surface-variant">
            {a.telefono}
            {a.remitente && ` · de ${a.remitente}`}
          </span>
        </span>
      ),
  },
  {
    key: 'bot',
    header: 'El bot',
    sort: (a) => a.decision,
    csv: (a) => `${DECISION[a.decision]}${a.nota ? ` (${a.nota})` : ''}`,
    cell: (a) => (
      <span className="block max-w-56">
        {DECISION[a.decision]}
        {a.nota && <span className="block type-panel-caption text-on-surface-variant">{a.nota}</span>}
      </span>
    ),
  },
  {
    key: 'pago',
    header: 'El pago',
    csv: (a) => (a.pago ? `${a.pago.persona} ${a.pago.referencia} ${csvDinero(a.pago.montoVes)}` : null),
    cell: (a) =>
      a.pago ? (
        <span className="block">
          <Link to="/admin/cobros/$id" params={{ id: a.pago.id }} className={ENLACE_EN_CELDA}>
            {a.pago.persona}
          </Link>
          <span className="block type-panel-caption text-on-surface-variant">
            {formatUsd(a.pago.montoUsd)} · {formatVes(a.pago.montoVes)}
          </span>
          {!a.emparejadoPorBot && (
            <span className="block type-panel-caption text-on-surface-variant">Misma referencia, no lo eligió el bot</span>
          )}
        </span>
      ) : (
        <span className="text-on-surface-variant">—</span>
      ),
  },
  {
    key: 'lis',
    header: 'El equipo',
    csv: (a) => (a.pago ? `${ESTADO_DEL_PAGO[a.pago.estado]} ${a.pago.revisadoPor ?? ''}` : null),
    cell: (a) =>
      a.pago ? (
        <span className="block whitespace-nowrap">
          {ESTADO_DEL_PAGO[a.pago.estado]}
          {a.pago.revisadoEn && (
            <span className="block type-panel-caption text-on-surface-variant">
              {a.pago.revisadoPor ?? ''} · {formatDateTime(a.pago.revisadoEn)}
            </span>
          )}
          {a.pago.motivoRechazo && a.pago.estado === 'rejected' && (
            <span className="block max-w-56 whitespace-normal type-panel-caption text-on-surface-variant">
              {a.pago.motivoRechazo}
            </span>
          )}
        </span>
      ) : (
        <span className="text-on-surface-variant">—</span>
      ),
  },
  {
    key: 'resultado',
    header: 'Resultado',
    sort: (a) => comparar(a),
    csv: (a) => COMPARACION[comparar(a)].texto,
    cell: (a) => {
      const c = COMPARACION[comparar(a)]
      return <Badge tone={c.tone}>{c.texto}</Badge>
    },
  },
]

const COLUMNAS_SIN_AVISO: Array<Column<PagoSinAviso>> = [
  {
    key: 'persona',
    header: 'Paciente',
    identity: true,
    sort: (s) => s.persona,
    csv: (s) => s.persona,
    cell: (s) => (
      <Link to="/admin/cobros/$id" params={{ id: s.id }} className={ENLACE_EN_CELDA}>
        {s.persona}
      </Link>
    ),
  },
  {
    key: 'referencia',
    header: 'Referencia',
    csv: (s) => s.referencia,
    cell: (s) => <span className="font-mono type-panel-caption">{s.referencia}</span>,
  },
  {
    key: 'monto',
    header: 'Monto',
    type: 'number',
    sort: (s) => s.montoUsd,
    csv: (s) => csvDinero(s.montoVes),
    cell: (s) => (
      <>
        <span className="font-semibold">{formatUsd(s.montoUsd)}</span>
        <span className="mt-0.5 block type-panel-caption font-normal text-on-surface-variant">
          {formatVes(s.montoVes)}
        </span>
      </>
    ),
  },
  {
    key: 'aprobado',
    header: 'Aprobado',
    sort: (s) => s.revisadoEn,
    sortDir: 'desc',
    csv: (s) => (s.revisadoEn ? csvInstante(s.revisadoEn) : null),
    cell: (s) => (
      <span className="block whitespace-nowrap text-on-surface-variant">
        {s.revisadoPor ?? ''}
        {s.revisadoEn && <span className="block type-panel-caption">{formatDateTime(s.revisadoEn)}</span>}
      </span>
    ),
  },
]
