import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { FileText } from 'lucide-react'

import { DescargarVentas } from '@/components/DescargarVentas'
import {
  Badge,
  Button,
  CampoDeRango,
  EmptyState,
  ErrorBox,
  SectionTitle,
  SkeletonTable,
  Stat,
  StatGrid,
  Table,
  Td,
  Tr,
  diaOperativo,
  estadoDeConsulta,
  formatDateTime,
  formatDay,
  formatTime,
  formatUsd,
  sumarDias,
} from '@/components/ui'
import { canSee } from '@/features/auth/permissions'
import { useStaff } from '@/features/auth/session'
import type { StaffContext } from '@/features/auth/session'
import { LIMITE_DE_FILAS } from '@/features/merchant/financiamientos'
import type {
  CuotaDeLaClinica,
  FilaDeFinanciamiento,
  PorPersona,
} from '@/features/merchant/financiamientos'
import {
  fetchFinanciamientos,
  fetchPorPersona,
  fetchResumen,
} from '@/features/merchant/financiamientosApi'
import { COMPROBANTE } from '@/features/merchant/registro'
import { ROL } from '@/features/merchant/staff'
import { comoDia } from '@/lib/busqueda'
import { describeError } from '@/lib/supabase'

type FinanciamientosSearch = { desde?: string; hasta?: string }

export const Route = createFileRoute('/_comercio/financiamientos')({
  // `wide`: nueve columnas de nombres, dinero y fechas.
  staticData: { title: 'Financiamientos', width: 'wide' },
  validateSearch: (s: Record<string, unknown>): FinanciamientosSearch => ({
    desde: comoDia(s.desde),
    hasta: comoDia(s.hasta),
  }),
  component: FinanciamientosRoute,
})

function FinanciamientosRoute() {
  const staff = useStaff()
  if (!staff) return null
  // Los dos roles entran: la secretaria ve los que registró ella. Lo recorta
  // la base, no esta pantalla.
  if (!canSee(staff.role, 'financiamientos')) return null
  return <Financiamientos staff={staff} />
}

/** Atajos del rango: teclear dos fechas para ver lo de ayer es fricción pura. */
const ATAJOS: Array<{ label: string; dias: number }> = [
  { label: 'Hoy', dias: 0 },
  { label: '7 días', dias: 6 },
  { label: '30 días', dias: 29 },
]

/**
 * FINANCIAMIENTOS: lo que se registró en la clínica, por día operativo.
 *
 * El administrador ve la clínica entera, quién registró cada uno y puede
 * descargar el libro para contabilidad. La secretaria ve solo los suyos
 * —la lista, las cifras y la ficha—; ese corte lo hace la base
 * (`scope = 'self'`), y la pantalla lo dice para que «3 financiamientos»
 * no se lea como los de toda la clínica.
 *
 * De cada uno: el paciente (solo el nombre), a quién se atendió, el
 * concepto, la consulta, la comisión de quien lo registró, si le llegó el
 * comprobante al paciente y cuándo le paga Helios cada mitad a la clínica.
 * Nunca el estado de pago del paciente: eso es entre él y Helios.
 */
function Financiamientos({ staff }: { staff: StaffContext }) {
  const navigate = useNavigate({ from: '/financiamientos' })
  const search = Route.useSearch()

  // El día operativo de Helios va de medianoche a medianoche en Caracas: el
  // de calendario. Se calcula aquí y no se pide a la base, para que el rango
  // no dependa de una consulta más que pueda fallar.
  const hoy = diaOperativo()
  const rango = {
    from: search.desde ?? sumarDias(hoy, -6),
    to: search.hasta ?? hoy,
  }
  const alReves = rango.from > rango.to
  const incluyeHoy = rango.to >= hoy

  function cambiarRango(r: { from: string; to: string }) {
    void navigate({ search: { desde: r.from, hasta: r.to }, replace: true })
  }

  // Mientras el rango llega hasta hoy la lista se refresca sola: se está
  // registrando en la recepción. Un rango cerrado ya no cambia.
  const vivo = { refetchInterval: incluyeHoy ? 30_000 : (false as const) }

  const lista = useQuery({
    queryKey: ['merchant-transactions', rango.from, rango.to],
    queryFn: () => fetchFinanciamientos(rango),
    enabled: !alReves,
    ...vivo,
  })

  const resumen = useQuery({
    queryKey: ['merchant-transactions-summary', rango.from, rango.to],
    queryFn: () => fetchResumen(rango),
    enabled: !alReves,
    ...vivo,
  })

  const propios = resumen.data?.scope === 'self'
  const deTodos = resumen.data?.scope === 'gerente'

  const porPersona = useQuery({
    queryKey: ['merchant-sales-by-staff', rango.from, rango.to],
    queryFn: () => fetchPorPersona(rango),
    enabled: !alReves && deTodos,
    ...vivo,
  })

  const filas = lista.data?.rows ?? []
  const conComision = filas.some((f) => f.staffCommissionUsd !== null)
  const conComprobante = filas.some((f) => f.receipt !== null)
  const estadoCifras = estadoDeConsulta(resumen)

  return (
    <>
      <div className="mb-4 flex flex-wrap items-center gap-2">
        {ATAJOS.map((a) => {
          const valor = { from: sumarDias(hoy, -a.dias), to: hoy }
          const activo = valor.from === rango.from && valor.to === rango.to
          return (
            <Button
              key={a.label}
              variant={activo ? 'tonal' : 'text'}
              size="sm"
              onClick={() => cambiarRango(valor)}
            >
              {a.label}
            </Button>
          )
        })}

        {/* La descarga es del administrador: lleva el neto y lo transferido,
            que es la misma clase de dato que Pagos. La base lo vuelve a
            comprobar en `merchant_sales_export`. */}
        {canSee(staff.role, 'contabilidad') && (
          <div className="ml-auto">
            <DescargarVentas
              from={rango.from}
              to={rango.to}
              merchantName={staff.merchantName}
              onRange={cambiarRango}
            />
          </div>
        )}
      </div>

      <CampoDeRango
        id="financiamientos-fechas"
        label="Fechas"
        rango={rango}
        onChange={cambiarRango}
        maximo={hoy}
        hoy={hoy}
        error={alReves}
        className="mb-6 w-full max-w-xs"
      />

      {alReves ? (
        <ErrorBox title="El rango está al revés" detail="La fecha de inicio es posterior a la final." />
      ) : (
        <>
          {/* Las cifras de arriba las recorta la base: al administrador le
              llegan las de la clínica y a la secretaria las suyas. Nunca un
              cero que no se leyó: con error, «No se pudo leer». */}
          <StatGrid className="mb-3">
            <Stat
              label={propios ? 'Lo que registraste' : 'Financiado en el rango'}
              value={formatUsd(resumen.data?.saleUsd ?? 0)}
              info="La suma de las consultas, lo que cobra la clínica. Sin el servicio Helios, que paga el paciente."
              estado={estadoCifras}
              onReintentar={() => void resumen.refetch()}
            />
            <Stat
              label="Financiamientos"
              value={String(resumen.data?.count ?? 0)}
              estado={estadoCifras}
              onReintentar={() => void resumen.refetch()}
            />
            {!propios && (
              <Stat
                label="Consulta promedio"
                value={formatUsd(resumen.data?.avgTicketUsd ?? 0)}
                hint="Financiado ÷ financiamientos"
                estado={estadoCifras}
                onReintentar={() => void resumen.refetch()}
              />
            )}
            <Stat
              label="Días con financiamientos"
              value={String(resumen.data?.activeDays ?? 0)}
              estado={estadoCifras}
              onReintentar={() => void resumen.refetch()}
            />
          </StatGrid>

          <p className="mb-6 type-panel-caption text-panel-muted">
            {propios
              ? 'Ves solo los financiamientos que registraste tú. '
              : ''}
            El día de Helios va de medianoche a medianoche, hora de Caracas.
          </p>

          {deTodos && (
            <QuienRegistro
              data={porPersona.data}
              isLoading={porPersona.isLoading}
              error={porPersona.error}
            />
          )}

          {lista.isLoading && <SkeletonTable rows={8} columns={8} />}

          {lista.isError && (
            <ErrorBox
              title="No pudimos cargar los financiamientos"
              detail={describeError(lista.error)}
            />
          )}

          {lista.data?.truncated && (
            <ErrorBox
              title={`Se muestran los ${LIMITE_DE_FILAS} financiamientos más recientes`}
              detail="El rango tiene más. Las cifras de arriba sí los cuentan todos; para ver los que faltan, acorta las fechas."
            />
          )}

          {lista.data && filas.length === 0 && (
            <EmptyState
              icon={<FileText size={40} />}
              title="Sin financiamientos en estas fechas"
              description={
                propios
                  ? 'Aquí aparecen los que registres tú. Prueba a ampliar el rango de fechas.'
                  : 'Prueba a ampliar el rango de fechas.'
              }
            />
          )}

          {filas.length > 0 && (
            <Table
              headers={[
                'Fecha',
                '# Orden',
                'Paciente',
                'Concepto',
                ...(deTodos
                  ? [
                      {
                        label: 'Registró',
                        info: 'La cuenta de la clínica que registró el financiamiento. Es quien gana su comisión.',
                      } as const,
                    ]
                  : []),
                'Consulta',
                ...(conComision
                  ? [
                      {
                        label: 'Comisión',
                        info: 'Lo que gana quien lo registró. Helios la paga dentro de la transferencia del lunes a la clínica.',
                      } as const,
                    ]
                  : []),
                ...(conComprobante
                  ? [
                      {
                        label: 'Comprobante',
                        info: 'Si al paciente le llegó el correo con sus cuotas. «Rebotado» quiere decir que el correo no existe: avisa a Helios.',
                      } as const,
                    ]
                  : []),
                {
                  label: 'Te pagamos',
                  info: 'El lunes en que Helios le transfiere a la clínica cada mitad (cuota 1 y cuota 2), haya pagado o no el paciente.',
                },
              ]}
            >
              {filas.map((f) => (
                <Tr
                  key={f.id}
                  onClick={() => void navigate({ to: '/financiamientos/$id', params: { id: f.id } })}
                >
                  <Td className="whitespace-nowrap">
                    {formatDay(f.businessDate)}
                    <span className="block type-panel-caption text-panel-muted">
                      {formatTime(f.confirmedAt)}
                    </span>
                  </Td>
                  <Td className="font-semibold">#{f.orderNumber}</Td>
                  <Td>
                    {f.patientName ?? <span className="text-on-surface-variant">Sin nombre</span>}
                    {f.beneficiaryName && (
                      <span className="block type-panel-caption text-panel-muted">
                        Atendido: {f.beneficiaryName}
                      </span>
                    )}
                  </Td>
                  <Td className="max-w-56 truncate text-on-surface-variant">
                    {f.concept ?? '—'}
                  </Td>
                  {deTodos && (
                    <Td>{f.registeredBy ?? <span className="text-on-surface-variant">—</span>}</Td>
                  )}
                  <Td className="font-semibold tabular-nums">{formatUsd(f.merchantSaleUsd)}</Td>
                  {conComision && (
                    <Td className="tabular-nums text-on-surface-variant">
                      {f.staffCommissionUsd === null ? '—' : formatUsd(f.staffCommissionUsd)}
                    </Td>
                  )}
                  {conComprobante && (
                    <Td>
                      {f.receipt ? (
                        <Badge tone={COMPROBANTE[f.receipt].tone} icono>
                          {COMPROBANTE[f.receipt].texto}
                        </Badge>
                      ) : (
                        <span className="text-on-surface-variant">—</span>
                      )}
                    </Td>
                  )}
                  <Td className="whitespace-nowrap tabular-nums">
                    <Mitades cuotas={f.cuotas} />
                  </Td>
                </Tr>
              ))}
            </Table>
          )}

          {filas.length > 0 && (
            <p className="mt-4 type-panel-caption leading-5 text-panel-muted">
              Pulsa una fila para ver el detalle y reenviar el comprobante. Helios cierra caja
              los lunes a las 10:00 y ese día transfiere lo que venció en la semana,{' '}
              <strong>haya pagado o no el paciente</strong>.
            </p>
          )}
        </>
      )}
    </>
  )
}

/**
 * Las dos fechas en que se le paga a la clínica, una debajo de otra. La
 * fecha es la del cierre (lunes); el vencimiento de la cuota va en el
 * `title`, que es el otro día que hay en juego y no se debe confundir.
 */
function Mitades({ cuotas }: { cuotas: FilaDeFinanciamiento['cuotas'] }) {
  return (
    <span className="flex flex-col">
      {cuotas.map((c: CuotaDeLaClinica, i) =>
        c ? (
          <span key={i} title={`La cuota ${i + 1} del paciente vence el ${formatDay(c.dueDate)}`}>
            <span className="type-panel-caption text-panel-muted">{i + 1}ª </span>
            {formatDay(c.paidToMerchantOn)}
          </span>
        ) : (
          <span key={i} className="text-on-surface-variant">
            —
          </span>
        ),
      )}
    </span>
  )
}

/**
 * QUIÉN REGISTRÓ: lo financiado por cada persona del personal en el rango,
 * con su comisión. Solo para el administrador: a una secretaria la base le
 * devuelve únicamente su fila, que ya son las cifras de arriba.
 */
function QuienRegistro({
  data,
  isLoading,
  error,
}: {
  data: PorPersona | undefined
  isLoading: boolean
  error: unknown
}) {
  if (isLoading) {
    return (
      <div className="mb-6">
        <SkeletonTable rows={3} columns={5} />
      </div>
    )
  }

  if (error) {
    return (
      <div className="mb-6">
        <ErrorBox title="No pudimos repartir los financiamientos por persona" detail={describeError(error)} />
      </div>
    )
  }

  // Sin financiamientos no se pinta un reparto vacío: debajo ya está el
  // «Sin financiamientos en estas fechas».
  if (!data || data.rows.length === 0) return null

  const conComision = data.rows.some((r) => r.commissionUsd !== null)

  return (
    <section className="mb-6">
      <SectionTitle className="mb-3">Quién registró</SectionTitle>
      <Table
        headers={[
          'Persona',
          'Financiamientos',
          'Financiado',
          ...(conComision ? ['Comisión'] : []),
          'Último',
        ]}
      >
        {data.rows.map((fila) => (
          <Tr key={fila.userId}>
            <Td>
              <span className="font-semibold text-on-surface">{fila.name}</span>
              <span className="ml-2 inline-flex gap-1 align-middle">
                {fila.isSelf && <Badge tone="neutral">Tú</Badge>}
                {fila.role === 'gerente' && <Badge tone="neutral">{ROL.gerente.label}</Badge>}
                {!fila.isActive && <Badge tone="warning">De baja</Badge>}
              </span>
            </Td>
            <Td className="tabular-nums">{fila.count}</Td>
            <Td className="font-semibold tabular-nums">{formatUsd(fila.saleUsd)}</Td>
            {conComision && (
              <Td className="tabular-nums">
                {fila.commissionUsd === null ? '—' : formatUsd(fila.commissionUsd)}
              </Td>
            )}
            <Td className="text-on-surface-variant">{formatDateTime(fila.lastAt)}</Td>
          </Tr>
        ))}
      </Table>
      <p className="mt-3 type-panel-caption leading-5 text-panel-muted">
        Lo financiado en el rango, repartido por quien registró cada financiamiento. El detalle
        por semana, pagado y por pagar, está en Comisiones.
      </p>
    </section>
  )
}
