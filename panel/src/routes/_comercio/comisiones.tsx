import { Link, createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQueries, useQuery } from '@tanstack/react-query'
import { ArrowLeft, HandCoins } from 'lucide-react'

import {
  Badge,
  EmptyState,
  ErrorBox,
  Filtro,
  FilterBar,
  Periodo,
  SectionTitle,
  Segmented,
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
  formatDayShort,
  formatUsd,
} from '@/components/ui'
import { canSee } from '@/features/auth/permissions'
import { useStaff } from '@/features/auth/session'
import type { StaffContext } from '@/features/auth/session'
import {
  ESTADO_DE_COMISION,
  MAXIMO_DE_SEMANAS,
  agruparPorSemana,
  atajosDeComisiones,
  lunesDe,
  lunesDePago,
  rangoPorDefecto,
  semanasDelRango,
  totales,
} from '@/features/merchant/comisiones'
import type { ComisionDePersona } from '@/features/merchant/comisiones'
import { fetchComisiones, fetchItemsDeComision } from '@/features/merchant/comisionesApi'
import { comoDia, comoId, unoDe } from '@/lib/busqueda'
import { describeError } from '@/lib/supabase'

type Vista = 'persona' | 'semana'

const VISTAS: Array<{ value: Vista; label: string }> = [
  { value: 'persona', label: 'Por persona' },
  { value: 'semana', label: 'Por semana' },
]

type ComisionesSearch = { desde?: string; hasta?: string; vista?: Vista; persona?: string }

export const Route = createFileRoute('/_comercio/comisiones')({
  staticData: { title: 'Comisiones', width: 'wide' },
  validateSearch: (s: Record<string, unknown>): ComisionesSearch => ({
    desde: comoDia(s.desde),
    hasta: comoDia(s.hasta),
    vista: unoDe(
      VISTAS.map((v) => v.value),
      s.vista,
    ),
    persona: comoId(s.persona),
  }),
  component: ComisionesRoute,
})

function ComisionesRoute() {
  const staff = useStaff()
  if (!staff) return null
  if (!canSee(staff.role, 'comisiones')) return null
  return <Comisiones staff={staff} />
}

/**
 * COMISIONES DEL PERSONAL (plan §6).
 *
 * Por cada financiamiento confirmado, quien lo registró gana una comisión
 * que Helios paga a la clínica en el cierre del lunes siguiente, dentro de
 * la misma transferencia que las consultas. La clínica se la entrega a su
 * personal.
 *
 * El administrador ve las de todo el personal —por persona, para repartir,
 * y por semana, que es como se pagan— y entra al detalle de cada una. La
 * secretaria ve solo las suyas, financiamiento a financiamiento. Ese corte
 * lo hace la base (`merchant_commissions`); aquí solo se decide qué vista
 * tiene sentido para cada rol.
 */
function Comisiones({ staff }: { staff: StaffContext }) {
  const navigate = useNavigate({ from: '/comisiones' })
  const search = Route.useSearch()
  const hoy = diaOperativo()

  const porDefecto = rangoPorDefecto(hoy)
  const rango = { from: search.desde ?? porDefecto.from, to: search.hasta ?? porDefecto.to }
  const deTodos = canSee(staff.role, 'comisiones-de-todos')
  const vista: Vista = deTodos ? (search.vista ?? 'persona') : 'persona'

  const resumen = useQuery({
    queryKey: ['comisiones', rango.from, rango.to],
    queryFn: () => fetchComisiones(rango),
  })

  const t = resumen.data ? totales(resumen.data) : null
  const estado = estadoDeConsulta(resumen)
  const reintentar = () => void resumen.refetch()

  const personaElegida = deTodos
    ? (resumen.data?.find((r) => r.staffUserId === search.persona) ?? null)
    : null

  return (
    <>
      <FilterBar>
        <Filtro label="Periodo">
          <Periodo
            rango={rango}
            hoy={hoy}
            atajos={atajosDeComisiones(hoy)}
            onChange={(r) =>
              void navigate({ search: (s) => ({ ...s, desde: r.from, hasta: r.to }), replace: true })
            }
          />
        </Filtro>
        {deTodos && !search.persona && (
          <Filtro label="Ver">
            <Segmented
              options={VISTAS}
              value={vista}
              onChange={(v) =>
                void navigate({
                  search: (s) => ({ ...s, vista: v === 'persona' ? undefined : v }),
                  replace: true,
                })
              }
            />
          </Filtro>
        )}
      </FilterBar>

      <StatGrid className="mb-3">
        <Stat
          label={deTodos ? 'Comisiones del personal' : 'Lo que ganaste'}
          value={formatUsd(t?.amountUsd ?? 0)}
          info="Lo devengado en el rango: una comisión por cada financiamiento confirmado."
          estado={estado}
          onReintentar={reintentar}
        />
        <Stat
          label="Ya pagado"
          value={formatUsd(t?.paidUsd ?? 0)}
          hint="Incluido en una transferencia a la clínica"
          estado={estado}
          onReintentar={reintentar}
        />
        <Stat
          label="Por pagar"
          value={formatUsd(t?.pendingUsd ?? 0)}
          hint="Entra en el próximo cierre de los lunes"
          estado={estado}
          onReintentar={reintentar}
        />
        <Stat
          label="Financiamientos"
          value={String(t?.chargeCount ?? 0)}
          estado={estado}
          onReintentar={reintentar}
        />
      </StatGrid>

      <p className="mb-6 type-panel-caption leading-5 text-panel-muted">
        {deTodos
          ? 'Helios paga las comisiones a la clínica en el cierre del lunes siguiente a cada semana, junto con las consultas. La clínica se las entrega a su personal.'
          : 'Ves solo tus comisiones. Helios se las paga a la clínica el lunes siguiente a cada semana, y la clínica te las entrega.'}
        {canSee(staff.role, 'pagos') && (
          <>
            {' '}
            <Link to="/pagos" className="underline underline-offset-2 hover:text-on-surface">
              Ver los pagos a la clínica
            </Link>
          </>
        )}
      </p>

      {resumen.isError && (
        <ErrorBox title="No pudimos cargar las comisiones" detail={describeError(resumen.error)} />
      )}

      {/* La secretaria: directamente sus comisiones, una por financiamiento. */}
      {!deTodos && resumen.isSuccess && <DetalleDePersona rango={rango} persona={null} />}

      {deTodos && search.persona && (
        <>
          <Link
            from="/comisiones"
            to="/comisiones"
            search={(s) => ({ ...s, persona: undefined })}
            className="mb-4 inline-flex items-center gap-1 type-panel-control text-on-surface-variant hover:text-on-surface"
          >
            <ArrowLeft size={14} aria-hidden /> Todo el personal
          </Link>
          <DetalleDePersona
            rango={rango}
            persona={{ id: search.persona, nombre: personaElegida?.staffName ?? null }}
          />
        </>
      )}

      {deTodos && !search.persona && vista === 'persona' && (
        <>
          {resumen.isLoading && <SkeletonTable rows={4} columns={5} />}
          {resumen.data && resumen.data.length === 0 && <SinComisiones />}
          {resumen.data && resumen.data.length > 0 && (
            <TablaPorPersona
              rows={resumen.data}
              onElegir={(id) =>
                void navigate({ search: (s) => ({ ...s, persona: id }) })
              }
            />
          )}
        </>
      )}

      {deTodos && !search.persona && vista === 'semana' && (
        <PorSemana
          rango={rango}
          onElegir={(id) => void navigate({ search: (s) => ({ ...s, persona: id }) })}
        />
      )}
    </>
  )
}

function SinComisiones() {
  return (
    <EmptyState
      icon={<HandCoins size={40} />}
      title="Sin comisiones en estas fechas"
      description="Cada financiamiento confirmado le da una comisión a quien lo registró. Prueba a ampliar el periodo."
    />
  )
}

/** Una fila por persona: cuánto ganó, cuánto se pagó y cuánto falta. */
function TablaPorPersona({
  rows,
  onElegir,
}: {
  rows: ComisionDePersona[]
  onElegir: (staffUserId: string) => void
}) {
  const t = totales(rows)

  return (
    <>
      <Table headers={['Persona', 'Financiamientos', 'Ganado', 'Ya pagado', 'Por pagar']}>
        {rows.map((r) => (
          <Tr key={r.staffUserId} onClick={() => onElegir(r.staffUserId)}>
            <Td className="font-semibold">{r.staffName}</Td>
            <Td className="tabular-nums">{r.chargeCount}</Td>
            <Td className="font-semibold tabular-nums">{formatUsd(r.amountUsd)}</Td>
            <Td className="tabular-nums text-on-surface-variant">{formatUsd(r.paidUsd)}</Td>
            <Td className="tabular-nums">
              {r.pendingUsd > 0 ? formatUsd(r.pendingUsd) : <span className="text-on-surface-variant">—</span>}
            </Td>
          </Tr>
        ))}
        <tr className="border-t border-panel-hairline-strong">
          <Td className="font-semibold">Total</Td>
          <Td className="tabular-nums">{t.chargeCount}</Td>
          <Td className="font-semibold tabular-nums">{formatUsd(t.amountUsd)}</Td>
          <Td className="tabular-nums text-on-surface-variant">{formatUsd(t.paidUsd)}</Td>
          <Td className="font-semibold tabular-nums">{formatUsd(t.pendingUsd)}</Td>
        </tr>
      </Table>
      <p className="mt-3 type-panel-caption text-panel-muted">
        Pulsa una persona para ver sus comisiones financiamiento a financiamiento.
      </p>
    </>
  )
}

/**
 * La vista por semana: cada semana de lunes a domingo, con lo de cada
 * persona y el lunes en que se paga. Es una consulta por semana, así que
 * se acota a las últimas {@link MAXIMO_DE_SEMANAS}.
 */
function PorSemana({
  rango,
  onElegir,
}: {
  rango: { from: string; to: string }
  onElegir: (staffUserId: string) => void
}) {
  const todas = semanasDelRango(rango)
  const semanas = todas.slice(0, MAXIMO_DE_SEMANAS)

  const consultas = useQueries({
    queries: semanas.map((s) => ({
      queryKey: ['comisiones', s.from, s.to],
      queryFn: () => fetchComisiones(s),
    })),
  })

  return (
    <div className="flex flex-col gap-6">
      {todas.length > MAXIMO_DE_SEMANAS && (
        <p className="type-panel-body text-on-surface-variant">
          Se muestran las {MAXIMO_DE_SEMANAS} semanas más recientes del periodo. Para ver las
          anteriores, acorta el periodo.
        </p>
      )}

      {semanas.map((s, i) => {
        const q = consultas[i]
        const lunes = lunesDe(s.from)
        const t = q.data ? totales(q.data) : null
        return (
          <section key={s.from}>
            <div className="mb-3 flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
              <SectionTitle>
                Semana del {formatDayShort(s.from)} al {formatDayShort(s.to)}
              </SectionTitle>
              <span className="type-panel-caption text-panel-muted">
                Se paga el lunes {formatDay(lunesDePago(lunes))}
                {t && ` · ${formatUsd(t.amountUsd)} en ${t.chargeCount} financiamientos`}
              </span>
            </div>

            {q.isLoading && <SkeletonTable rows={2} columns={5} />}
            {q.isError && (
              <ErrorBox title="No pudimos cargar esta semana" detail={describeError(q.error)} />
            )}
            {q.data && q.data.length === 0 && (
              <p className="type-panel-body text-on-surface-variant">Sin comisiones esta semana.</p>
            )}
            {q.data && q.data.length > 0 && (
              <Table headers={['Persona', 'Financiamientos', 'Ganado', 'Estado']}>
                {q.data.map((r) => (
                  <Tr key={r.staffUserId} onClick={() => onElegir(r.staffUserId)}>
                    <Td className="font-semibold">{r.staffName}</Td>
                    <Td className="tabular-nums">{r.chargeCount}</Td>
                    <Td className="font-semibold tabular-nums">{formatUsd(r.amountUsd)}</Td>
                    <Td>
                      {r.pendingUsd > 0 ? (
                        <Badge tone="warning" icono>
                          Por pagar {formatUsd(r.pendingUsd)}
                        </Badge>
                      ) : r.amountUsd > 0 ? (
                        <Badge tone="success" icono>
                          Pagada
                        </Badge>
                      ) : (
                        <span className="text-on-surface-variant">—</span>
                      )}
                    </Td>
                  </Tr>
                ))}
              </Table>
            )}
          </section>
        )
      })}

      {semanas.length === 0 && <SinComisiones />}
    </div>
  )
}

/**
 * Las comisiones de una persona, financiamiento a financiamiento y
 * agrupadas por la semana en que se pagan. `persona` a null: las de quien
 * mira (la secretaria).
 */
function DetalleDePersona({
  rango,
  persona,
}: {
  rango: { from: string; to: string }
  persona: { id: string; nombre: string | null } | null
}) {
  const items = useQuery({
    queryKey: ['comisiones', 'items', rango.from, rango.to, persona?.id ?? 'yo'],
    queryFn: () =>
      fetchItemsDeComision({ from: rango.from, to: rango.to, staffUserId: persona?.id ?? null }),
  })

  const semanas = items.data ? agruparPorSemana(items.data) : []

  return (
    <section className="flex flex-col gap-5">
      {persona && (
        <SectionTitle>Comisiones de {persona.nombre ?? 'esta persona'}</SectionTitle>
      )}

      {items.isLoading && <SkeletonTable rows={5} columns={4} />}

      {items.isError && (
        <ErrorBox title="No pudimos cargar el detalle" detail={describeError(items.error)} />
      )}

      {items.data && items.data.length === 0 && <SinComisiones />}

      {semanas.map((g) => (
        <div key={g.semana.from}>
          <div className="mb-2 flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <p className="type-panel-body font-semibold text-on-surface">
              Semana del {formatDayShort(g.semana.from)} al {formatDayShort(g.semana.to)}
            </p>
            <span className="type-panel-caption text-panel-muted">
              {formatUsd(g.amountUsd)}
              {g.pendingUsd > 0
                ? ` · ${formatUsd(g.pendingUsd)} por pagar el lunes ${formatDay(lunesDePago(g.semana.from))}`
                : ' · pagada'}
            </span>
          </div>
          <Table headers={['Registrado', '# Orden', 'Comisión', 'Estado', 'Pagada el']}>
            {g.items.map((i) => {
              const e = i.status ? ESTADO_DE_COMISION[i.status] : null
              return (
                <Tr key={i.chargeId}>
                  <Td className="whitespace-nowrap text-on-surface-variant">
                    {formatDateTime(i.createdAt)}
                  </Td>
                  <Td>
                    <Link
                      to="/financiamientos/$id"
                      params={{ id: i.chargeId }}
                      className="font-semibold underline-offset-2 hover:underline"
                    >
                      #{i.orderNumber}
                    </Link>
                  </Td>
                  <Td
                    className={`tabular-nums ${i.status === 'revertida' ? 'text-on-surface-variant line-through' : 'font-semibold'}`}
                  >
                    {formatUsd(i.amountUsd)}
                  </Td>
                  <Td>
                    {e ? (
                      <Badge tone={e.tone} icono>
                        {e.texto}
                      </Badge>
                    ) : (
                      <span className="text-on-surface-variant">—</span>
                    )}
                  </Td>
                  <Td className="whitespace-nowrap text-on-surface-variant">
                    {i.paidOn ? formatDay(i.paidOn) : '—'}
                  </Td>
                </Tr>
              )
            })}
          </Table>
        </div>
      ))}
    </section>
  )
}
