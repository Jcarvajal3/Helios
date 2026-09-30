import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import type { UseQueryResult } from '@tanstack/react-query'
import { AlertTriangle, CheckCircle2, Clock, Download } from 'lucide-react'

import { Button, NoSePudoLeer, SectionTitle, SkeletonBlock } from '@/components/ui'
import { exportarMesContable, useMesContable } from '@/components/admin/ExportacionContable'
import { fetchSettlementRuns } from '@/features/admin/api'
import {
  puntoAbonos,
  puntoBanco,
  puntoExtracto,
  puntoLibro,
  puntoLocales,
  ultimoDia,
} from '@/features/admin/cierreMes'
import type { Veredicto } from '@/features/admin/cierreMes'
import { LIBRO_CUADRA, descuadreDelLibro } from '@/features/admin/contabilidad'
import { fetchUnmatchedDeposits } from '@/features/admin/deposits'
import { fetchBankBalances } from '@/features/admin/proyeccionDeCaja'
import { useSaludDelMes } from '@/components/admin/caja/SaludConciliacion'

/** Topes de las lecturas: si se alcanzan, no se da nada por hecho. */
const LIMITE_ABONOS = 500
const LIMITE_CORTES = 200

/**
 * La lista de comprobación del cierre de un mes.
 *
 * Cada punto sale de una función que ya existía y dice si está hecho, si
 * falta o si todavía no toca, con un enlace a donde se arregla. Si su lectura
 * falla, el punto lo dice: un punto sin leer nunca sale como hecho.
 */
export function ListaDelCierre({ mes, hoy }: { mes: string; hoy: string }) {
  const fin = ultimoDia(mes)

  const salud = useSaludDelMes(mes, hoy)
  const abonos = useQuery({
    queryKey: ['unmatched-deposits', LIMITE_ABONOS],
    queryFn: () => fetchUnmatchedDeposits(LIMITE_ABONOS),
  })
  const cortes = useQuery({
    queryKey: ['bank-balances', LIMITE_CORTES],
    queryFn: () => fetchBankBalances(LIMITE_CORTES),
  })
  const libro = useMesContable(mes)
  const cierres = useQuery({ queryKey: ['settlement-runs'], queryFn: fetchSettlementRuns })

  const locales = cierres.data ? puntoLocales(cierres.data, mes) : null

  return (
    <section className="flex flex-col gap-3">
      <SectionTitle>Lista de comprobación</SectionTitle>

      <ul className="flex flex-col gap-2">
        <Punto
          titulo="El extracto del banco está importado hasta final de mes"
          consulta={salud}
          veredicto={salud.data && puntoExtracto(salud.data.statement.lastMovedOn, mes, hoy)}
          accion={
            <Link to="/admin/cobros" search={{ importar: true }} className={ENLACE}>
              Importar el extracto
            </Link>
          }
        />
        <Punto
          titulo="Ningún abono del mes se queda sin dueño"
          consulta={abonos}
          veredicto={abonos.data && puntoAbonos(abonos.data, mes, abonos.data.length >= LIMITE_ABONOS)}
          accion={
            <Link to="/admin/cobros" search={{ vista: 'abonos' }} className={ENLACE}>
              Ver los abonos sin dueño
            </Link>
          }
        />
        <Punto
          titulo="El saldo del banco del último día está apuntado y cuadra con el libro"
          consulta={cortes}
          veredicto={cortes.data && puntoBanco(cortes.data, mes, hoy, cortes.data.length < LIMITE_CORTES)}
          accion={
            <Link to="/admin/metricas" search={{ vista: 'caja', sub: 'proyeccion', corte: fin }} className={ENLACE}>
              Apuntar el saldo del banco
            </Link>
          }
        />
        <Punto
          titulo="El libro cuadra"
          consulta={libro}
          veredicto={libro.data && puntoLibro(descuadreDelLibro(libro.data), libro.data.summary.transactions, LIBRO_CUADRA)}
          accion={
            <Link to="/admin/contabilidad" search={{ vista: 'exportacion', mes }} className={ENLACE}>
              Ver el balance de comprobación
            </Link>
          }
        />
        <Punto
          titulo="Las clínicas tienen transferido lo que tocaba pagar en el mes"
          consulta={cierres}
          veredicto={locales ?? undefined}
          accion={
            <Link
              to="/admin/pagos-clinicas"
              search={locales?.primerPendiente ? { cierre: locales.primerPendiente } : {}}
              className={ENLACE}
            >
              Ver los pagos a clínicas
            </Link>
          }
        />
      </ul>

      <div>
        <Button
          size="md"
          disabled={!libro.data}
          motivoApagado={libro.isError ? 'No se pudo leer el mes.' : 'Leyendo el mes…'}
          onClick={() => libro.data && exportarMesContable(libro.data)}
        >
          <Download size={14} /> Exportar el mes
        </Button>
      </div>
    </section>
  )
}

// Un enlace a donde se arregla el punto: en blanco y subrayado, no en lima.
const ENLACE =
  'type-panel-control text-on-surface underline decoration-panel-muted underline-offset-2 hover:decoration-on-surface'

function Punto({
  titulo,
  consulta,
  veredicto,
  accion,
}: {
  titulo: string
  consulta: Pick<UseQueryResult, 'isPending' | 'isError' | 'refetch'>
  veredicto: Veredicto | undefined
  accion: ReactNode
}) {
  const icono = consulta.isError ? (
    <AlertTriangle size={18} className="text-error" aria-hidden />
  ) : !veredicto ? null : veredicto.estado === 'hecho' ? (
    <CheckCircle2 size={18} className="text-success" aria-hidden />
  ) : veredicto.estado === 'falta' ? (
    <AlertTriangle size={18} className="text-warning" aria-hidden />
  ) : (
    <Clock size={18} className="text-on-surface-variant" aria-hidden />
  )

  const etiqueta = consulta.isError
    ? 'No se pudo leer'
    : !veredicto
      ? ''
      : { hecho: 'Hecho', falta: 'Falta', todavia_no: 'Todavía no' }[veredicto.estado]

  return (
    <li className="flex items-start gap-3 rounded-panel-control border border-panel-hairline bg-panel-card p-3">
      <span className="mt-0.5 flex size-5 shrink-0 items-center justify-center">{icono}</span>
      <div className="flex min-w-0 flex-1 flex-col gap-1">
        <p className="type-panel-body font-semibold text-on-surface">
          {titulo}
          {etiqueta && <span className="sr-only">: {etiqueta}</span>}
        </p>
        {consulta.isPending && <SkeletonBlock className="h-4 w-64" />}
        {consulta.isError && <NoSePudoLeer onReintentar={() => void consulta.refetch()} />}
        {veredicto && !consulta.isError && (
          <p className="type-panel-body text-on-surface-variant">{veredicto.detalle}</p>
        )}
      </div>
      {veredicto && veredicto.estado !== 'hecho' && <span className="shrink-0">{accion}</span>}
    </li>
  )
}
