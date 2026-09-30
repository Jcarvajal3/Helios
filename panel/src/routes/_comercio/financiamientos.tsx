import { useState } from 'react'
import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { FileText, Lock } from 'lucide-react'

import {
  Badge,
  Button,
  CampoDeRango,
  EmptyState,
  ErrorBox,
  SectionTitle,
  SkeletonStats,
  SkeletonTable,
  Stat,
  StatGrid,
  Table,
  Td,
  Tr,
  formatDateTime,
  formatDay,
  formatTime,
  formatUsd,
} from '@/components/ui'
import { DescargarVentas } from '@/components/DescargarVentas'
import { canSee } from '@/features/auth/permissions'
// El nombre de cada rol sale de `staff.ts`, que es donde lo lee la pantalla de
// Personal: una segunda tabla de etiquetas aquí acabaría diciendo «Encargado»
// donde la otra dice «Gerente».
import { ROL } from '@/features/merchant/staff'
import { useStaff } from '@/features/auth/session'
import type { StaffContext } from '@/features/auth/session'
import {
  TRANSACTIONS_LIMIT,
  fetchBusinessDate,
  fetchSalesByStaff,
  fetchTransactionsInRange,
  fetchTransactionsSummary,
} from '@/features/charges/api'
import type {
  DayTransaction,
  SalesByStaff,
  TransactionInstallment,
} from '@/features/charges/api'
import { describeError } from '@/lib/supabase'

export const Route = createFileRoute('/_comercio/financiamientos')({
  // `wide`: siete columnas de dinero y fechas. Con el tope de 960 de una
  // pantalla de lectura, la tabla desbordaba y se leía arrastrando incluso en
  // un monitor grande.
  staticData: { title: 'Financiamientos', width: 'wide' },
  component: TransaccionesRoute,
})

function TransaccionesRoute() {
  const staff = useStaff()

  if (!staff) return null

  if (!canSee(staff.role, 'financiamientos')) {
    return (
      <EmptyState
        icon={<Lock size={48} />}
        title="Esto lo ve el administrador"
        description="Lo que financia la clínica entera es información del administrador. Tu pantalla es Nuevo financiamiento."
      />
    )
  }

  return <Transacciones staff={staff} />
}

/**
 * Mueve un día operativo (`YYYY-MM-DD`) N días.
 *
 * La aritmética va en UTC a propósito. Un `date` no tiene hora, y construir
 * la fecha con el constructor local haría que la tablet del local —o la de
 * cualquiera que la mire desde otro huso— saltara de día al formatearla de
 * vuelta.
 */
function shiftDay(day: string, days: number): string {
  const [y = '1970', m = '01', d = '01'] = day.split('-')
  const at = new Date(Date.UTC(Number(y), Number(m) - 1, Number(d) + days))
  return at.toISOString().slice(0, 10)
}

type Range = { from: string; to: string }

/** Atajos del rango. En una tablet, teclear dos fechas para ver lo de anoche
 *  es fricción pura, y esta pantalla se mira de pie detrás de una barra. */
const PRESETS: Array<{ label: string; days: number }> = [
  { label: 'Hoy', days: 0 },
  { label: '7 días', days: 6 },
  { label: '30 días', days: 29 },
]

/**
 * Historial de ventas del local.
 *
 * Va por **día operativo** (10 AM a 10 AM, docs/00-BASES §2.2) y no por hora
 * real: una venta de las 2 AM pertenece a la noche anterior. Filtrar por
 * `confirmed_at` partiría cada madrugada en dos y haría que este panel y el
 * de Ronda no cuadraran nunca.
 */
function Transacciones({ staff }: { staff: StaffContext }) {
  const navigate = useNavigate()
  const [range, setRange] = useState<Range | null>(null)

  const today = useQuery({
    queryKey: ['business-date'],
    queryFn: fetchBusinessDate,
    staleTime: 5 * 60 * 1000,
  })

  // Por defecto, la última semana. Abrir en "solo hoy" era el fallo que tenía
  // esta pantalla: a las 11 de la mañana el día operativo ya ha cambiado y lo
  // de anoche desaparecía, que es justo lo que el local viene a mirar.
  const effective: Range | null =
    range ?? (today.data ? { from: shiftDay(today.data, -6), to: today.data } : null)

  const invalid = effective !== null && effective.from > effective.to
  const includesToday = effective !== null && today.data === effective.to

  const query = useQuery({
    queryKey: ['merchant-transactions', effective?.from, effective?.to],
    queryFn: () => fetchTransactionsInRange({ from: effective!.from, to: effective!.to }),
    enabled: effective !== null && !invalid,
    // Solo se sondea si el rango llega hasta hoy: mientras se cobra, la lista
    // tiene que seguir viva aunque la tablet pierda el foco. Un rango cerrado
    // en el pasado ya no cambia, y repreguntarlo cada 15 s es gasto en balde.
    refetchInterval: includesToday ? 15_000 : false,
    refetchIntervalInBackground: true,
  })

  /**
   * 🐛 LOS TOTALES NO SE SUMAN EN ESTA PANTALLA.
   *
   * Se calculaban recorriendo `rows`, que es solo lo que cupo en la consulta:
   * con un rango de más de 500 órdenes, las cifras de arriba eran las de las
   * últimas 500 y nada en pantalla lo decía. Y el ticket promedio salía de una
   * división hecha aquí con OTRO dividendo que el de Métricas —lo que se le
   * paga al local en vez de lo que vendió—, así que las dos pantallas podían
   * enseñar dos números para la misma cuenta.
   *
   * Ahora los da la base sobre el rango ENTERO, y el promedio sale de
   * `helios_avg_ticket_usd`, que es la misma función que pide Métricas.
   */
  const summary = useQuery({
    queryKey: ['merchant-transactions-summary', effective?.from, effective?.to],
    queryFn: () => fetchTransactionsSummary({ from: effective!.from, to: effective!.to }),
    enabled: effective !== null && !invalid,
    refetchInterval: includesToday ? 15_000 : false,
    refetchIntervalInBackground: true,
  })

  /**
   * DE QUIÉN SON LAS CIFRAS. Lo decide la base (20260922180000) y llega en
   * `scope`: el gerente ve el local entero y cualquier otro solo lo que cobró
   * él — la lista, los totales y la ficha de cada orden.
   */
  const propias = summary.data?.scope === 'self'

  /**
   * El cierre por persona y la columna «Cobró» son del gerente. A quien solo
   * ve lo suyo, las dos le repetirían su propio nombre en cada fila.
   */
  const verQuienCobro = summary.data?.scope === 'gerente'

  /**
   * EL CIERRE POR PERSONA: lo que vendió cada quien en el mismo rango.
   *
   * Consulta aparte y no un campo más de `summary` porque son dos preguntas
   * distintas: cuánto vendió el local, y cómo se reparte.
   */
  const porPersona = useQuery({
    queryKey: ['merchant-sales-by-staff', effective?.from, effective?.to],
    queryFn: () => fetchSalesByStaff({ from: effective!.from, to: effective!.to }),
    enabled: effective !== null && !invalid && verQuienCobro,
    refetchInterval: includesToday ? 15_000 : false,
    refetchIntervalInBackground: true,
  })

  const rows = query.data?.rows ?? []
  /** La lista y los totales son dos consultas, pero para quien mira la
   *  pantalla son una sola cosa: basta que falle una para no poder fiarse. */
  const loadError = query.error ?? summary.error

  return (
    <>
      {today.isError && (
        <ErrorBox
          title="No pudimos calcular el día de hoy"
          detail={describeError(today.error)}
        />
      )}

      {effective && (
        <>
          <div className="mb-4 flex flex-wrap items-center gap-2">
            {PRESETS.map((preset) => {
              const value = today.data
                ? { from: shiftDay(today.data, -preset.days), to: today.data }
                : null
              const active =
                value !== null &&
                value.from === effective.from &&
                value.to === effective.to

              return (
                <Button
                  key={preset.label}
                  variant={active ? 'tonal' : 'text'}
                  size="sm"
                  onClick={() => value && setRange(value)}
                >
                  {preset.label}
                </Button>
              )
            })}

            {/* La lista la ven los dos roles; la descarga no. Lleva la
                comisión que Ronda le cobra al local y lo que ya se le ha
                transferido, que es la misma clase de dato que Métricas y
                Pagos. `merchant_sales_export` lo vuelve a comprobar. */}
            {canSee(staff.role, 'contabilidad') && (
              <div className="ml-auto">
                <DescargarVentas
                  from={effective.from}
                  to={effective.to}
                  merchantName={staff.merchantName}
                  onRange={setRange}
                />
              </div>
            )}
          </div>

          {/* Un solo campo que abre el calendario: dos toques en la tablet en
              vez de teclear dos fechas. No pasa de hoy, que es hasta donde
              hay ventas. */}
          <CampoDeRango
            id="transacciones-fechas"
            label="Fechas (día operativo)"
            rango={effective}
            onChange={setRange}
            maximo={today.data}
            hoy={today.data}
            className="mb-6 w-full max-w-xs"
          />
        </>
      )}

      {invalid && (
        <ErrorBox
          title="El rango está al revés"
          detail="La fecha de «Desde» es posterior a la de «Hasta»."
        />
      )}

      {!invalid && (
        <>
          {summary.isLoading && <SkeletonStats className="mb-6" count={4} />}

          {/* Las mismas cifras para los dos roles, recortadas por la base: al
              gerente le llegan las del local y a cualquier otro las suyas. El
              rótulo sigue a `scope` para que «Tu venta» no se lea como la del
              local cuando es la de quien mira. */}
          {summary.data && (
            <StatGrid className="mb-6">
              <Stat
                label={propias ? 'Lo que cobraste' : 'Tu financiamiento en el rango'}
                value={formatUsd(summary.data.saleUsd)}
                tone="success"
              />
              {/* Una cuenta repartida entre cinco es UNA orden: el local hizo
                  una venta y sacó un QR. Se llamaba "Transacciones", que en un
                  cobro de grupo se leía como "cinco". */}
              <Stat label="Nro. de órdenes" value={String(summary.data.orderCount)} />
              {/* Del gerente: es una cifra del negocio, no del turno. */}
              {!propias && (
                <Stat
                  label="Ticket promedio"
                  value={formatUsd(summary.data.avgTicketUsd)}
                  hint="Tu financiamiento ÷ nro. de órdenes"
                />
              )}
              <Stat label="Días con financiamiento" value={String(summary.data.activeDays)} />
            </StatGrid>
          )}

          {verQuienCobro && (
            <QuienCobro
              data={porPersona.data}
              isLoading={porPersona.isLoading}
              error={porPersona.error}
            />
          )}

          <p className="mb-6 type-label-medium leading-5 text-on-surface-variant">
            El día de Helios va de medianoche a medianoche, hora de Caracas.
          </p>

          {query.isLoading && <SkeletonTable rows={8} columns={7} />}

          {loadError && (
            <ErrorBox
              title="No pudimos cargar las transacciones"
              detail={describeError(loadError)}
            />
          )}

          {query.data?.truncated && (
            <ErrorBox
              title={`Se muestran las ${TRANSACTIONS_LIMIT} financiamientos más recientes`}
              detail="El rango tiene más. Los totales de arriba sí las cuentan todas; para ver las que faltan, acorta las fechas."
            />
          )}

          {query.data && rows.length === 0 && (
            <EmptyState
              icon={<FileText size={40} />}
              title="Sin financiamientos en estas fechas"
              description="Prueba a ampliar el rango de fechas."
            />
          )}

          {/* Las dos últimas llevan UNA FECHA Y NADA MÁS: el día en que se le
              paga esa mitad. Antes traían el estado de la cuota —Pendiente / En
              mora / Pagado—, que es la deuda del cliente con Ronda y aquí se
              leía como una amenaza sobre el cobro propio. Ver la nota en
              `TransactionInstallment`. */}
          {rows.length > 0 && (
            <Table
              headers={[
                'Día',
                'Hora',
                '# Orden',
                'Paciente',
                // Las dos columnas de nombres van juntas y en este orden: el
                // cliente y, al lado, quién del local le cobró. Separarlas con
                // las cifras en medio obliga a cruzar la fila entera para
                // contestar «esta orden, ¿de quién era y quién la sacó?».
                ...(verQuienCobro
                  ? [
                      {
                        label: 'Registró',
                        info: 'La cuenta de la clínica que registró ese financiamiento. Es quien lo lleva en el cierre de arriba.',
                      } as const,
                    ]
                  : []),
                'Tu financiamiento',
                'Cuota 1',
                'Cuota 2',
              ]}
            >
              {rows.map((t) => (
                <Tr
                  key={t.id}
                  onClick={() =>
                    void navigate({ to: '/financiamientos/$id', params: { id: t.id } })
                  }
                >
                  <Td>{formatDay(t.businessDate)}</Td>
                  <Td>{formatTime(t.confirmedAt)}</Td>
                  <Td className="font-semibold text-on-surface">#{t.orderNumber}</Td>
                  <ClienteCell venta={t} />
                  {verQuienCobro && (
                    // El guion es para una venta de antes de que el local
                    // tuviera personal con nombre, o de una cuenta que ya no
                    // existe: la orden es real y su importe también, así que
                    // se pinta la fila igual en vez de esconderla.
                    <Td>
                      {t.staffName ?? <span className="text-on-surface-variant">—</span>}
                    </Td>
                  )}
                  <Td className="font-semibold">{formatUsd(t.merchantSaleUsd)}</Td>
                  <CuotaCell installment={t.installments[0]} />
                  <CuotaCell installment={t.installments[1]} />
                </Tr>
              ))}
            </Table>
          )}

          {/* Las columnas llevan la fecha sola, así que aquí va lo que esa
              fecha es. Sin esta línea se puede leer como el vencimiento de la
              cuota, que es el otro día que hay en juego. */}
          {rows.length > 0 && (
            <p className="mt-4 type-label-medium leading-5 text-on-surface-variant">
              Toca una fila para ver <strong>el detalle</strong> de ese financiamiento.
              <br />
              En Cuota 1 y Cuota 2 va <strong>el día en que Helios te paga</strong>{' '}
              esa mitad del financiamiento. Cerramos caja los lunes a las 10:00 y
              transferimos ese mismo día lo que venció durante la semana,{' '}
              <strong>haya pagado o no tu paciente</strong>.
            </p>
          )}
        </>
      )}
    </>
  )
}

/**
 * EL CIERRE POR PERSONA.
 *
 * La pregunta que contesta: *al cerrar la noche, ¿cuánto vendió cada quien?*
 *
 * Existe por la comisión. En un bar, quien está en la barra se lleva un
 * porcentaje de lo que vende, y si cobrar con Ronda no cuenta para esa
 * comisión, la cajera no lo ofrece — y quien decide si Ronda se usa en un
 * local no es el dueño que firmó, es la persona que tiene al cliente delante
 * a las 2 AM.
 *
 * **Ronda no calcula la comisión**, y por eso aquí no hay ningún porcentaje:
 * dice lo que vendió cada quien y cada local aplica su propio trato. La
 * nómina de un tercero no es de este panel.
 *
 * Solo lo pinta el gerente: a cualquier otro la base le devuelve únicamente
 * su propia fila, que ya está en las cifras de arriba.
 */
function QuienCobro({
  data,
  isLoading,
  error,
}: {
  data: SalesByStaff | undefined
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
      <ErrorBox
        title="No pudimos repartir los financiamientos por paciente"
        detail={describeError(error)}
      />
    )
  }

  if (!data) return null

  // Sin ventas en el rango no se pinta un cierre vacío: la pantalla ya tiene
  // un «Sin ventas en estas fechas» debajo, y dos formas de decir lo mismo
  // hacen dudar de si son dos cosas distintas.
  if (data.rows.length === 0) return null

  return (
    <section className="mb-6">
      <SectionTitle className="mb-3">Quién cobró</SectionTitle>

      <Table
        headers={[
          'Paciente',
          'Órdenes',
          'Su financiamiento',
          'Ticket promedio',
          'Último financiamiento',
        ]}
      >
        {data.rows.map((fila) => (
          <Tr key={fila.userId}>
            <Td>
              <span className="font-semibold text-on-surface">{fila.name}</span>
              <span className="ml-2 inline-flex gap-1 align-middle">
                {fila.isSelf && <Badge tone="neutral">Tú</Badge>}
                {/* El rol solo se etiqueta cuando sorprende. En un cierre se
                    esperan cajeros; un gerente o un inventario con ventas es
                    lo que hay que poder explicar. */}
                {fila.role !== null && fila.role !== 'cajero' && (
                  <Badge tone="neutral">{ROL[fila.role].label}</Badge>
                )}
                {/* Una baja no borra sus ventas —se le paga lo que vendió
                    antes de irse— pero el nombre suelto de alguien que ya no
                    está se lee como un error de la lista. */}
                {!fila.isActive && <Badge tone="warning">De baja</Badge>}
              </span>
            </Td>
            <Td className="tabular-nums">{fila.orderCount}</Td>
            <Td className="font-semibold tabular-nums">{formatUsd(fila.saleUsd)}</Td>
            <Td className="tabular-nums text-on-surface-variant">
              {formatUsd(fila.avgTicketUsd)}
            </Td>
            <Td className="text-on-surface-variant">
              {formatDateTime(fila.lastSaleAt)}
            </Td>
          </Tr>
        ))}
      </Table>

      {/* UNA línea, y dice las dos cosas que no se ven en la tabla: que estas
          cifras son el total de arriba repartido, y que el porcentaje que se
          le pague a cada quien no lo pone Ronda. */}
      <p className="mt-3 type-label-medium leading-5 text-on-surface-variant">
        Es lo financiado en el rango, repartido por la cuenta que registró cada
        financiamiento. Las comisiones del personal están en Comisiones.
      </p>
    </section>
  )
}

/**
 * Quién compró.
 *
 * **Solo el nombre.** Ni teléfono, ni cédula: el local lo necesita para
 * reconocer a quien tuvo delante —«la de €48 de anoche, ¿de quién era?»— y
 * eso se contesta con un nombre. La RPC no manda nada más, así que aquí no
 * hay nada más que enseñar aunque se quisiera.
 */
function ClienteCell({ venta }: { venta: DayTransaction }) {
  return (
    <Td>
      {venta.customerName ?? (
        <span className="text-on-surface-variant">Sin nombre</span>
      )}
    </Td>
  )
}

/**
 * Cuándo cobra el comercio una de las dos mitades de la orden.
 *
 * La fecha es el lunes del cierre que paga esa cuota, y la pone la base. Aquí
 * no se hace aritmética de calendario a propósito: si el cierre se mueve, esta
 * pantalla no puede quedarse con el de antes.
 *
 * En un cobro de grupo la cuota es una POR PERSONA pero todas vencen el mismo
 * día y hablan de la misma venta — al comercio se le paga por consumo y fecha,
 * no por deudor— así que la fecha es una sola por muchos que se repartieran la
 * cuenta. Por eso esta celda ya no necesita saber cuántos pagaron.
 */
function CuotaCell({ installment }: { installment: TransactionInstallment }) {
  // Sin plan de pago no hay nada que enseñar. No debería pasar en un cobro
  // confirmado, pero un guion se lee mejor que una fecha inventada.
  if (!installment) return <Td className="text-on-surface-variant">—</Td>

  return (
    <Td className="tabular-nums">
      <span title={`La cuota vence el ${formatDay(installment.dueDate)}`}>
        {formatDay(installment.paidToMerchantOn)}
      </span>
    </Td>
  )
}
