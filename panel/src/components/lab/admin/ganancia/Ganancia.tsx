import { useQuery } from '@tanstack/react-query'

import {
  EmptyState,
  ErrorBox,
  Periodo,
  Seccion,
  SkeletonStats,
  SkeletonTable,
  Stat,
  StatGrid,
  Table,
  Td,
  Tr,
  formatDay,
  formatUsd,
  hoyCaracas,
} from '@/components/ui'
import type { Rango } from '@/components/ui'
import { consultaGanancia, mensajeDeError } from '@/features/lab/admin'

const CABECERAS = ['Muestra', 'Fecha', 'Médico', 'Examen', 'Laboratorio', 'Cobrado', 'Base', 'Comisión del médico', 'Cargo Helios']

export function Ganancia({ rango, onRango }: { rango: Rango; onRango: (r: Rango) => void }) {
  const q = useQuery(consultaGanancia(rango.from, rango.to))

  return (
    <Seccion
      titulo="Ganancia"
      info="Muestras con el pago verificado y no anuladas. La ganancia de Helios es el Cargo Helios; la base es de los laboratorios y la comisión, del médico."
      controles={<Periodo rango={rango} hoy={hoyCaracas()} onChange={onRango} />}
    >
      {q.isPending && (
        <>
          <SkeletonStats />
          <SkeletonTable rows={6} />
        </>
      )}
      {q.isError && <ErrorBox title="No se pudo leer la ganancia" detail={mensajeDeError(q.error)} />}
      {q.data && (
        <>
          <StatGrid>
            <Stat label="Muestras" value={q.data.muestras.toLocaleString('es-VE')} />
            <Stat label="Cobrado" value={formatUsd(q.data.cobradoUsd)} />
            <Stat label="Base de los laboratorios" value={formatUsd(q.data.baseUsd)} />
            <Stat label="Comisión de los médicos" value={formatUsd(q.data.comisionUsd)} />
            <Stat label="Cargo Helios (ganancia)" value={formatUsd(q.data.cargoUsd)} variant="hero" />
          </StatGrid>

          {q.data.filas.length === 0 ? (
            <EmptyState title="Sin muestras cobradas en esas fechas" />
          ) : (
            <Table headers={CABECERAS}>
              {q.data.filas.map((f, i) => (
                <Tr key={f.id || i}>
                  <Td className="font-semibold">{f.codigo}</Td>
                  <Td className="whitespace-nowrap">{formatDay(f.fecha)}</Td>
                  <Td>{f.medico}</Td>
                  <Td>{f.examen}</Td>
                  <Td>{f.laboratorio}</Td>
                  <Td className="whitespace-nowrap tabular-nums">{formatUsd(f.cobradoUsd)}</Td>
                  <Td className="whitespace-nowrap tabular-nums">{formatUsd(f.baseUsd)}</Td>
                  <Td className="whitespace-nowrap tabular-nums">{formatUsd(f.comisionUsd)}</Td>
                  <Td className="whitespace-nowrap font-semibold tabular-nums">{formatUsd(f.cargoUsd)}</Td>
                </Tr>
              ))}
            </Table>
          )}
        </>
      )}
    </Seccion>
  )
}
