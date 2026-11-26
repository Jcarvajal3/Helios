import { useQuery } from '@tanstack/react-query'

import {
  Badge,
  Button,
  ErrorBox,
  Seccion,
  SkeletonStats,
  Stat,
  StatGrid,
  Table,
  Td,
  Tr,
  formatUsd,
} from '@/components/ui'
import { consultaResumen, mensajeDeError } from '@/features/lab/admin'
import { ROTULO_KIT } from '@/features/lab/tipos'

function enteros(n: number | undefined): string {
  return (n ?? 0).toLocaleString('es-VE')
}

export function Resumen() {
  const q = useQuery(consultaResumen())

  if (q.isPending) return <SkeletonStats />
  if (q.isError) {
    return (
      <ErrorBox title="No se pudo leer el resumen" detail={mensajeDeError(q.error)} />
    )
  }
  const r = q.data

  return (
    <div className="flex flex-col gap-10">
      <Seccion titulo="Hoy">
        <StatGrid>
          <Stat
            label="Muestras de hoy"
            value={enteros(r.muestrasHoy)}
            link={{ to: '/lab/muestras' }}
          />
          <Stat
            label="Por retirar"
            value={enteros(r.porEstado.lista_para_retirar)}
            hint="Listas en el consultorio"
            link={{ to: '/lab/muestras', search: { estado: 'lista_para_retirar' } }}
          />
          <Stat
            label="En el laboratorio"
            value={enteros(r.porEstado.en_laboratorio)}
            link={{ to: '/lab/muestras', search: { estado: 'en_laboratorio' } }}
          />
          <Stat
            label="Resultados por entregar"
            value={enteros(r.porEstado.resultado_recibido)}
            hint="Llegaron y falta enviarlos al paciente"
            link={{ to: '/lab/muestras', search: { estado: 'resultado_recibido' } }}
          />
          <Stat
            label="Pagos por revisar"
            value={enteros(r.pagosPorRevisar)}
            link={{ to: '/lab/cobros' }}
            senal={r.pagosPorRevisar > 0 ? { tone: 'warning', texto: 'Esperan' } : undefined}
          />
          <Stat label="Ganancia de hoy" value={formatUsd(r.gananciaHoyUsd)} link={{ to: '/lab/ganancia' }} />
          <Stat label="Ganancia del mes" value={formatUsd(r.gananciaMesUsd)} link={{ to: '/lab/ganancia' }} />
        </StatGrid>
      </Seccion>

      <Seccion titulo="Kits" info="Lo que Helios tiene en su almacén frente al mínimo. Por debajo del mínimo hay que reponer.">
        {r.kits.length === 0 ? (
          <p className="type-panel-body text-panel-muted">Sin datos de kits todavía.</p>
        ) : (
          <Table headers={['Kit', 'En Helios', 'Mínimo', 'En los médicos', '']}>
            {r.kits.map((k) => {
              const repone = k.stockHelios < k.minimo
              return (
                <Tr key={k.tipo}>
                  <Td className="font-semibold">{ROTULO_KIT[k.tipo]}</Td>
                  <Td className="tabular-nums">{enteros(k.stockHelios)}</Td>
                  <Td className="tabular-nums">{enteros(k.minimo)}</Td>
                  <Td className="tabular-nums">{enteros(k.enMedicos)}</Td>
                  <Td>
                    {repone ? (
                      <div className="flex items-center gap-2">
                        <Badge tone="warning" icono>
                          Bajo el mínimo
                        </Badge>
                        <a href="/lab/inventario" className="inline-flex">
                          <Button size="sm" variant="outlined">
                            Reponer
                          </Button>
                        </a>
                      </div>
                    ) : (
                      <Badge tone="success" icono>
                        Al día
                      </Badge>
                    )}
                  </Td>
                </Tr>
              )
            })}
          </Table>
        )}
      </Seccion>
    </div>
  )
}
