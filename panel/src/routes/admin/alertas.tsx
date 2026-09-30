import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { ShieldCheck } from 'lucide-react'

import {
  Badge,
  EmptyState,
  FilterBar,
  Filtro,
  NoSePudoLeer,
  Card,
  Segmented,
  Select,
  SkeletonTable,
} from '@/components/ui'
import { TablaDeAlertas } from '@/components/admin/alertas/TablaDeAlertas'
import {
  GRAVEDAD,
  GRAVEDADES,
  ROTULO_TIPO_ALERTA,
  TIPOS_ALERTA,
  filtrarAlertas,
} from '@/features/admin/riesgo/alertas'
import type { Alertas, EstadoRevision, Gravedad, TipoAlerta } from '@/features/admin/riesgo/alertas'
import { CLAVES_RIESGO, fetchAlertas } from '@/features/admin/riesgo/consultas'
import { unoDe } from '@/lib/busqueda'

/** Cuántas alertas se piden. Si hay más, la pantalla lo dice. */
const TOPE = 500

const ESTADOS: ReadonlyArray<{ value: EstadoRevision; label: string }> = [
  { value: 'pendientes', label: 'Pendientes' },
  { value: 'revisadas', label: 'Revisadas' },
  { value: 'todas', label: 'Todas' },
]

type AlertasSearch = {
  tipo?: TipoAlerta
  gravedad?: Gravedad
  estado?: EstadoRevision
}

export const Route = createFileRoute('/admin/alertas')({
  staticData: { title: 'Alertas', width: 'wide' },
  component: AlertasPage,
  validateSearch: (s: Record<string, unknown>): AlertasSearch => ({
    tipo: unoDe(TIPOS_ALERTA, s.tipo),
    gravedad: unoDe(GRAVEDADES, s.gravedad),
    estado: unoDe(
      ESTADOS.map((e) => e.value),
      s.estado,
    ),
  }),
})

/**
 * Alertas de riesgo: las señales que piden que alguien mire una cuenta.
 *
 * La base no las guarda, las deduce de los datos cada vez (cuentas que
 * comparten aparato o cédula, verificaciones desde una VPN, un consumo por
 * encima del cupo, que la app nunca debería dejar pasar). Lo único que se
 * guarda es que alguien la revisó, con su nota. Por defecto se ven las
 * pendientes: es una cola.
 */
function AlertasPage() {
  const navigate = useNavigate({ from: '/admin/alertas' })
  const { tipo, gravedad, estado = 'pendientes' } = Route.useSearch()

  const consulta = useQuery({
    queryKey: [...CLAVES_RIESGO.alertas, TOPE, tipo ?? 'todas'],
    queryFn: () => fetchAlertas({ limite: TOPE, tipos: tipo ? [tipo] : null }),
    refetchInterval: 60_000,
  })

  function cambiar(parcial: AlertasSearch) {
    void navigate({ search: (previa) => ({ ...previa, ...parcial }), replace: true })
  }

  const recuentos = consulta.data?.recuentos

  return (
    <>
      <FilterBar>
        <Select
          id="alertas-tipo"
          label="Tipo"
          value={tipo ?? ''}
          placeholder="Todos los tipos"
          options={TIPOS_ALERTA.map((t) => ({
            value: t,
            label: recuentos
              ? `${ROTULO_TIPO_ALERTA[t]} (${recuentos[t].pendientes} sin revisar)`
              : ROTULO_TIPO_ALERTA[t],
          }))}
          onChange={(v) => cambiar({ tipo: unoDe(TIPOS_ALERTA, v) })}
          className="min-w-64"
        />
        <Filtro label="Gravedad">
          <Segmented
            options={[
              { value: 'todas', label: 'Todas' },
              ...GRAVEDADES.map((g) => ({ value: g, label: GRAVEDAD[g].rotulo })),
            ]}
            value={gravedad ?? 'todas'}
            onChange={(v) => cambiar({ gravedad: unoDe(GRAVEDADES, v) })}
          />
        </Filtro>
        <Filtro label="Revisión">
          <Segmented
            options={[...ESTADOS]}
            value={estado}
            onChange={(v) => cambiar({ estado: v === 'pendientes' ? undefined : v })}
          />
        </Filtro>
      </FilterBar>

      {consulta.isError ? (
        <Card>
          <NoSePudoLeer onReintentar={() => void consulta.refetch()} />
        </Card>
      ) : !consulta.data ? (
        <SkeletonTable />
      ) : (
        <Lista datos={consulta.data} gravedad={gravedad} estado={estado} />
      )}
    </>
  )
}

function Lista({
  datos,
  gravedad,
  estado,
}: {
  datos: Alertas
  gravedad: Gravedad | undefined
  estado: EstadoRevision
}) {
  const filas = filtrarAlertas(datos.filas, { gravedad, estado })
  const pendientes = filas.filter((a) => !a.revisada)
  const altas = pendientes.filter((a) => a.gravedad === 'alta').length

  if (datos.filas.length === 0) {
    return (
      <EmptyState
        icon={<ShieldCheck size={40} />}
        title="No hay alertas de riesgo"
        description={`Ninguna cuenta ha disparado una alerta. Las de financiamientos miran los últimos ${datos.ventanaDias} días.`}
      />
    )
  }

  if (filas.length === 0) {
    return (
      <EmptyState
        icon={<ShieldCheck size={40} />}
        title={
          estado === 'pendientes'
            ? 'No queda ninguna alerta sin revisar con estos filtros'
            : 'Ninguna alerta coincide con estos filtros'
        }
      />
    )
  }

  return (
    <>
      {datos.truncada && (
        <Badge tone="warning" icono className="mb-3">
          Solo se ven las primeras {TOPE} de {datos.total}: filtra por tipo para ver el resto.
        </Badge>
      )}
      <TablaDeAlertas
        alertas={filas}
        resumen={
          pendientes.length > 0 ? (
            <>
              {pendientes.length} sin revisar
              {altas > 0 && `, ${altas} de gravedad alta`}
            </>
          ) : (
            'ninguna sin revisar'
          )
        }
      />
    </>
  )
}
