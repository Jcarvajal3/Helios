import { useState } from 'react'
import { Link, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { Banknote } from 'lucide-react'

import { usePageTitle } from '@/components/layouts/PageAction'
import { useToast } from '@/components/Toast'
import {
  Callout,
  Card,
  DataLabel,
  ErrorBox,
  IconoDeArea,
  Modal,
  Seccion,
  SkeletonList,
  formatDateTime,
  formatDay,
  formatDocument,
  formatUsd,
  formatPhone,
  formatVes,
  formatWaiting,
} from '@/components/ui'
import { BarraDeCola, useCola } from '@/components/admin/ModoCola'
import { EstadoBadge } from '@/components/admin/EstadoBadge'
import { ImportarBanco } from '@/components/admin/ImportarBanco'
import { CabeceraDeFicha, MarcoDeFicha, VolverA, useVolverDeFicha } from '@/components/admin/ficha'
import {
  CotejoBanco,
  MovimientoQueLoRespaldo,
  movimientoQueRespalda,
  useCotejo,
} from '@/components/admin/caja/CotejoBanco'
import type { Cotejo } from '@/components/admin/caja/CotejoBanco'
import { DecisionDelPago, cuotaMasVieja } from '@/components/admin/caja/DecisionDelPago'
import { AvisoDelBnc } from '@/components/admin/caja/AvisoDelBnc'
import { DesgloseDelPago } from '@/components/admin/caja/DesgloseDelPago'
import { LigarDesdeElPago } from '@/components/admin/caja/LigarMovimiento'
import { VerCaptura } from '@/components/admin/caja/VerCaptura'
import type { QueueItem, StatementMatch } from '@/features/admin/api'
import { avisoQueRespalda, fetchAvisosDelPago, motivoConElAviso } from '@/features/admin/avisoDelPago'
import type { FiltrosPagos } from '@/features/admin/colaDePagos'
import type { Lectura } from '@/features/admin/lectorComprobantes'
import { fetchLecturaDelPago } from '@/features/admin/lectorComprobantesApi'
import { nombreDelMedio } from '@/features/admin/liquidaciones'
import { fetchPaymentReport } from '@/features/admin/pagosReportados'
import { lineaDeSumandos, sumandosDelPago } from '@/features/admin/sumandosDelPago'
import { describeError } from '@/lib/supabase'

/** El nombre de la cola que apunta la lista al abrir un pago. */
export const COLA_PAGOS_REPORTADOS = 'pagos-reportados'

/**
 * La página de un pago reportado.
 *
 * Se lee con `admin_payment_report`, que devuelve este pago y nada más. Antes
 * se pedía la cola entera en sus cinco estados para quedarse con uno.
 *
 * Si se llegó desde la lista, arriba va la barra de la cola («3 de 12»): tras
 * aprobar o rechazar se salta al siguiente, y tras el último se vuelve a la
 * lista. Los filtros de la lista viajan en la URL de la ficha, así que volver
 * la deja como estaba.
 */
export function PaginaCobro({
  reportId,
  filtros,
  importar,
}: {
  reportId: string
  filtros: FiltrosPagos
  /** Abre la ventana de importar el extracto encima de la ficha. */
  importar: boolean
}) {
  const navigate = useNavigate()
  const avisar = useToast()
  const cola = useCola(COLA_PAGOS_REPORTADOS, reportId)
  const origen = useVolverDeFicha()

  const query = useQuery({
    queryKey: ['payment-report', reportId],
    queryFn: () => fetchPaymentReport(reportId),
  })

  const item = query.data ?? null

  usePageTitle(item ? `${formatUsd(item.amountUsd)} de ${item.fullName ?? 'sin nombre'}` : null)

  function ir(otro: string) {
    void navigate({ to: '/admin/cobros/$id', params: { id: otro }, search: filtros })
  }

  /** A la pantalla desde la que se abrió; sin ella, a Pagos reportados con sus filtros. */
  function volver() {
    if (origen.volver) origen.volver()
    else void navigate({ to: '/admin/cobros', search: filtros })
  }

  function abrirImportar(abierto: boolean) {
    void navigate({
      to: '/admin/cobros/$id',
      params: { id: reportId },
      search: { ...filtros, importar: abierto ? true : undefined },
      replace: !abierto,
    })
  }

  /** Tras decidir: al siguiente de la cola, o a la lista si era el último. */
  function alResolver(aviso: string) {
    if (cola.siguiente) {
      avisar(`${aviso}. Siguiente pago`)
      ir(cola.siguiente)
    } else if (cola.total > 0) {
      avisar(`${aviso}. Cola terminada`)
      volver()
    } else {
      avisar(aviso)
    }
  }

  return (
    <>
      {cola.total > 0 ? (
        <BarraDeCola
          cola={cola}
          onIr={ir}
          onVolver={volver}
          rotulo={origen.origen?.titulo ?? 'Pagos reportados'}
        />
      ) : (
        <VolverA link={{ to: '/admin/cobros', search: filtros }}>Pagos reportados</VolverA>
      )}

      {query.isPending && <SkeletonList rows={3} />}

      {query.isError && (
        <ErrorBox title="No se pudo leer el pago" detail={describeError(query.error)} />
      )}

      {query.isSuccess && !item && (
        <ErrorBox
          title="Este pago no existe"
          detail="Puede que el enlace sea viejo, que el identificador esté mal escrito o que el pago sea de una cuenta de prueba."
        />
      )}

      {item && (
        <FichaDelPago
          key={item.reportId}
          item={item}
          onImportar={() => abrirImportar(true)}
          onResuelto={alResolver}
        />
      )}

      {importar && (
        <Modal title="Importar el extracto del banco" width="lg" onClose={() => abrirImportar(false)}>
          <ImportarBanco />
        </Modal>
      )}
    </>
  )
}

// ── La ficha de un pago ────────────────────────────────────────────────────

/**
 * A la izquierda, la evidencia: lo que reportó frente a lo que debía, qué
 * dice el extracto y qué salda. A la derecha, la decisión, fija al desplazar:
 * se baja leyendo la evidencia y el botón sigue ahí.
 */
function FichaDelPago({
  item,
  onImportar,
  onResuelto,
}: {
  item: QueueItem
  onImportar: () => void
  onResuelto: (aviso: string) => void
}) {
  const resuelto = item.status !== 'reported' && item.status !== 'in_review'
  const cotejo = useCotejo(item)
  // Entre varios movimientos que encajan, el que marca quien aprueba.
  const [elegido, setElegido] = useState<string | null>(null)
  const movimiento = movimientoQueRespalda(cotejo, elegido)
  const [ligando, setLigando] = useState(false)
  // El SMS del BNC de este pago, si llegó: respalda la aprobación mientras el
  // extracto de ese día no esté importado.
  const avisos = useQuery({
    queryKey: ['payment-report', item.reportId, 'avisos-bnc'],
    queryFn: () => fetchAvisosDelPago(item.reportId),
    enabled: !resuelto,
    staleTime: 60_000,
  })
  const respaldo = avisos.data ? avisoQueRespalda(avisos.data) : null
  // Si lo registró el lector de comprobantes (docs/03), y desde qué. Solo
  // los pagos del bot no traen quién los registró.
  const lectura = useQuery({
    queryKey: ['payment-report', item.reportId, 'lectura'],
    queryFn: () => fetchLecturaDelPago(item.reportId),
    enabled: item.registeredByName === null,
    staleTime: 5 * 60_000,
  })

  return (
    <MarcoDeFicha
      carrilFijo
      etiquetaDelCarril="La decisión"
      cabecera={<CabeceraDelPago item={item} />}
      carril={
        <Decision
          item={item}
          resuelto={resuelto}
          movimiento={movimiento}
          sinCotejo={porQueSinCotejo(cotejo, movimiento)}
          motivoConAviso={respaldo ? motivoConElAviso(respaldo) : null}
          onResuelto={onResuelto}
        />
      }
    >
      <FrenteAFrente item={item} lectura={lectura.data ?? null} />

      {!resuelto && (
        <CotejoBanco cotejo={cotejo} elegido={elegido} onElegir={setElegido} onImportar={onImportar} />
      )}
      {!resuelto && <AvisoDelBnc avisos={avisos.data} cargando={avisos.isPending} error={avisos.isError} />}
      {item.status === 'reconciled' && (
        <MovimientoQueLoRespaldo movimiento={item.statementLine} onLigar={() => setLigando(true)} />
      )}
      {ligando && <LigarDesdeElPago item={item} onClose={() => setLigando(false)} />}

      {item.referenceCollisions > 0 && (
        <Callout
          tone="warning"
          titulo={`Esta referencia aparece en ${item.referenceCollisions} ${
            item.referenceCollisions === 1 ? 'reporte más' : 'reportes más'
          }`}
          detalles="Con seis dígitos, dos pagos legítimos pueden coincidir por azar."
        >
          Contrasta la referencia con el extracto antes de decidir.
        </Callout>
      )}

      <DesgloseDelPago item={item} />
    </MarcoDeFicha>
  )
}

/**
 * Quién pagó, con lo que dice de esa persona su cuenta: un pago de alguien
 * congelado o recién subido de nivel se mira distinto.
 */
function CabeceraDelPago({ item }: { item: QueueItem }) {
  return (
    <CabeceraDeFicha
      identidad={<IconoDeArea icon={Banknote} tamano="md" />}
      nombre={
        <Link to="/admin/pacientes/$id" params={{ id: item.userId }} className="hover:underline">
          {item.fullName ?? 'Sin nombre'}
        </Link>
      }
      insignias={<EstadoBadge tipo="pago" valor={item.status} />}
      datos={[
        item.phone ? formatPhone(item.phone) : null,
        item.userDocument ? formatDocument(item.userDocument) : null,
        item.userLevel === null ? 'Sin nivel' : `Nivel ${item.userLevel}`,
      ]}
    >
      <span className="inline-flex flex-wrap items-center gap-2 type-panel-caption text-on-surface-variant">
        Su cuenta: <EstadoBadge tipo="persona" valor={item.userStatus} />
      </span>
    </CabeceraDeFicha>
  )
}

/**
 * Lo que reportó frente a lo que debía pagar: las dos cifras juntas o no se
 * pueden comparar.
 *
 * Lo que debía son TODAS las cuotas del pago más sus cargos por atraso, con
 * sus sumandos: antes se enseñaba solo la cuota más antigua, que frente a un
 * pago de cuatro cuotas parecía un pago de más.
 */
function FrenteAFrente({ item, lectura }: { item: QueueItem; lectura: Lectura | null }) {
  const cuota = cuotaMasVieja(item)
  const sumandos = sumandosDelPago(item)
  const linea = lineaDeSumandos(sumandos, formatUsd)
  const saldaAlgo = item.installmentCount > 0 || sumandos.cargosUsd > 0.005

  return (
    <Seccion titulo="Lo que reportó y lo que debía">
      <div className="grid gap-4 md:grid-cols-2">
        <Card className="flex flex-col gap-3">
          <DataLabel>Lo que reportó</DataLabel>
          <dl className="grid grid-cols-2 gap-x-4 gap-y-3 type-panel-body">
            <Dato label="Monto en bolívares" value={formatVes(item.amountVes)} />
            <Dato label="Referencia" value={item.reference ?? '—'} mono />
            <Dato label="Medio" value={nombreDelMedio(item.method)} />
            <Dato label="Banco" value={item.bank ?? '—'} />
            <Dato label="Cédula del pagador" value={formatDocument(item.payerDocument)} />
            <Dato label="Teléfono del pagador" value={formatPhone(item.payerPhone)} />
            {item.registeredByName && <Dato label="Lo registró" value={item.registeredByName} />}
            {lectura && (
              <Dato
                label="Lo registró"
                value={lectura.tipo === 'captura' ? 'El bot, leyendo la captura' : 'El bot, con los datos que escribió el paciente'}
              />
            )}
          </dl>
          {item.receiptPath && <VerCaptura ruta={item.receiptPath} />}
        </Card>

        <Card className="flex flex-col gap-3">
          <DataLabel>Lo que debía pagar (cuotas con comisión + cargos por atraso)</DataLabel>
          {saldaAlgo ? (
            <>
              <p className="type-panel-figure text-on-surface">{formatUsd(sumandos.totalUsd)}</p>
              {linea && <p className="type-panel-body text-on-surface-variant">{linea}</p>}
              <p className="type-panel-caption text-on-surface-variant">
                {formatVes(sumandos.totalUsd * item.fxRate)} · {item.installmentCount}{' '}
                {item.installmentCount === 1 ? 'cuota' : 'cuotas'}
                {cuota &&
                  `; la más antigua sin pagar vence el ${formatDay(cuota.dueDate)}${
                    cuota.daysOverdue > 0 ? `, con ${cuota.daysOverdue} días de atraso` : ''
                  }`}
              </p>
              {item.status === 'reconciled' && (
                <p className="type-panel-caption text-on-surface-variant">
                  Ya saldó sus cuotas: están abajo, en «Qué salda este pago».
                </p>
              )}
            </>
          ) : (
            <p className="type-panel-body text-on-surface-variant">
              {item.status === 'reconciled'
                ? 'Ya saldó sus cuotas: están abajo, en «Qué salda este pago».'
                : 'Este pago no salda ninguna cuota pendiente.'}
            </p>
          )}
        </Card>
      </div>
    </Seccion>
  )
}

/**
 * El carril: cuánto, en qué punto está y los botones que lo cierran. Un pago
 * ya resuelto dice quién lo resolvió y cuándo, y no ofrece nada.
 */
function Decision({
  item,
  resuelto,
  movimiento,
  sinCotejo,
  motivoConAviso,
  onResuelto,
}: {
  item: QueueItem
  resuelto: boolean
  movimiento: StatementMatch | null
  sinCotejo: string | null
  motivoConAviso: string | null
  onResuelto: (aviso: string) => void
}) {
  const espera = formatWaiting((Date.now() - new Date(item.createdAt).getTime()) / 1000)

  return (
    <Card as="section" className="flex flex-col gap-4">
      <div className="flex flex-col gap-1.5">
        <DataLabel>Reportó (con comisión)</DataLabel>
        <p className="type-panel-figure text-on-surface">{formatUsd(item.amountUsd)}</p>
        <p className="type-panel-caption text-panel-muted">
          {formatVes(item.amountVes)} a {item.fxRate.toLocaleString('es-VE')} Bs/$, la tasa BCV del día de
          su cotización
        </p>
      </div>

      <p className="type-panel-caption text-on-surface-variant">
        Reportado el {formatDateTime(item.createdAt)}
        {!resuelto && `. Espera desde hace ${espera}`}
        {!resuelto && item.status === 'in_review' && item.reviewedByName &&
          `. En revisión por ${item.reviewedByName}`}
        {resuelto &&
          item.reviewedAt &&
          `. ${item.status === 'reconciled' ? 'Aprobado' : 'Rechazado'} el ${formatDateTime(item.reviewedAt)}${
            item.reviewedByName ? ` por ${item.reviewedByName}` : ''
          }`}
        .
      </p>

      {item.note && (
        <div className="flex flex-col gap-1 border-t border-panel-hairline pt-3">
          <DataLabel>{item.status === 'in_review' ? 'Nota de la revisión' : 'Motivo'}</DataLabel>
          <p className="type-panel-body text-on-surface">{item.note}</p>
        </div>
      )}

      {!resuelto && (
        <div className="border-t border-panel-hairline pt-4">
          <DecisionDelPago
            item={item}
            movimiento={movimiento}
            sinCotejo={sinCotejo}
            motivoConAviso={motivoConAviso}
            onResuelto={onResuelto}
          />
        </div>
      )}
    </Card>
  )
}

/**
 * Por qué aprobar sería hacerlo sin respaldo del extracto, o `null` si hay un
 * movimiento que lo respalda (o la referencia está por otro monto, que se
 * decide mirando). Sin poder leer el extracto también es a ciegas.
 */
function porQueSinCotejo(cotejo: Cotejo, movimiento: StatementMatch | null): string | null {
  switch (cotejo.tipo) {
    case 'encontrado':
    case 'monto_distinto':
      return null
    case 'varios':
      return movimiento ? null : 'Varios movimientos del extracto encajan y no has elegido ninguno.'
    case 'ya_usado':
      return 'El movimiento que encaja ya respalda otro pago.'
    case 'no_encontrado':
      return 'Este pago no aparece en el extracto.'
    case 'cargando':
    case 'error':
      return 'No se pudo cotejar con el extracto.'
  }
}

function Dato({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    // `min-w-0` y cortar donde sea: en el teléfono cada columna mide 150 px y
    // una referencia larga en monoespaciada empujaba la de al lado.
    <div className="min-w-0">
      <dt className="type-panel-label text-on-surface-variant">{label}</dt>
      <dd className={`mt-0.5 text-on-surface [overflow-wrap:anywhere] ${mono ? 'font-mono tracking-wider' : ''}`}>{value}</dd>
    </div>
  )
}
