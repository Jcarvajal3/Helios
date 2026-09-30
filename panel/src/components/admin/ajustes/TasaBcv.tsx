import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Callout,
  Card,
  ConfirmDialog,
  ErrorBox,
  Input,
  Seccion,
  SkeletonCard,
  SkeletonTable,
  Stat,
  StatGrid,
  Table,
  Td,
  Tr,
  formatDateTime,
  formatDay,
} from '@/components/ui'
import type { SenalDeCifra } from '@/components/ui'
import { formatTasa, formatVariacion, variacionPct } from '@/features/admin/ajustesReglas'
import { fetchFxHistory, fetchFxStatus, setFxRate, syncFxRate } from '@/features/admin/fx'
import type { FxStatus } from '@/features/admin/fx'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { leerMonto } from '@/lib/montos'
import { describeError } from '@/lib/supabase'

const SYNC_STATUS_LABEL: Record<string, string | undefined> = {
  ok: 'Traída',
  manual: 'A mano',
  skipped: 'Ya estaba',
  network_error: 'Sin respuesta',
  http_error: 'Error de la fuente',
  parse_error: 'Respuesta ilegible',
  rejected: 'Rechazada',
  no_source: 'Sin fuentes',
}

/** Los intentos que no fallaron: la traída, la carga a mano y la que ya estaba. */
const INTENTOS_BUENOS: ReadonlyArray<string> = ['ok', 'manual', 'skipped']

/** Días hábiles con la tasa sin cambiar, dichos en palabras. */
function antiguedad(s: FxStatus): string {
  if (s.businessDaysBehind === null) {
    return s.ageHours === null ? '—' : `${s.ageHours.toLocaleString('es-VE')} h`
  }
  if (s.businessDaysBehind === 0) return 'Hoy'
  return `${s.businessDaysBehind} ${s.businessDaysBehind === 1 ? 'día hábil' : 'días hábiles'}`
}

/** Si el último intento de traer la tasa falló. Sin intento todavía no hay fallo. */
function falloElUltimoIntento(s: FxStatus): boolean {
  return s.lastSyncStatus !== null && !INTENTOS_BUENOS.includes(s.lastSyncStatus)
}

function senalDeLaTasa(s: FxStatus): SenalDeCifra | undefined {
  if (s.rate === null) return { tone: 'error', texto: 'Sin tasa' }
  if (s.isStale) return { tone: 'warning', texto: 'Desactualizada' }
  return undefined
}

/**
 * Cuentan los días hábiles, no las horas: un puente largo son cuatro días de
 * reloj y cero días hábiles. Desde dos, el aviso sale también en Inicio.
 */
function senalDeLaAntiguedad(s: FxStatus): SenalDeCifra | undefined {
  if (s.businessDaysBehind !== null && s.businessDaysBehind >= 2) {
    return { tone: 'error', texto: 'Crítico · desde 2 días hábiles' }
  }
  return undefined
}

/**
 * La tasa BCV del euro: la que está en vigor, la búsqueda automática y la
 * carga a mano.
 *
 * Cargarla a mano decide cuánto paga en bolívares todo el que pague hoy, así
 * que pasa por el diálogo crítico con la tasa vigente al lado de la nueva.
 */
export function TasaBcv() {
  const avisar = useToast()
  const client = useQueryClient()
  const isSuperAdmin = useIsSuperAdmin()

  const status = useQuery({ queryKey: ['fx-status'], queryFn: fetchFxStatus })
  const history = useQuery({ queryKey: ['fx-history'], queryFn: () => fetchFxHistory(30) })

  const refresh = () => {
    void client.invalidateQueries({ queryKey: ['fx-status'] })
    void client.invalidateQueries({ queryKey: ['fx-history'] })
    void client.invalidateQueries({ queryKey: ['admin-overview'] })
  }

  const sync = useMutation({
    mutationFn: syncFxRate,
    onSuccess: (traida) => {
      // La llamada puede salir bien y no traer tasa: fin de semana, feriado o
      // el BCV todavía no ha publicado. Decir «traída» ahí sería falso.
      avisar(
        traida.rate === undefined
          ? 'El BCV no ha publicado una tasa nueva. Sigue en vigor la última.'
          : `Tasa del BCV traída: ${formatTasa(traida.rate)}`,
      )
      refresh()
    },
  })

  if (status.isLoading) return <SkeletonCard />
  if (status.isError || !status.data) {
    return <ErrorBox title="No se pudo leer la tasa" detail={describeError(status.error)} />
  }

  const s = status.data
  // Un solo aviso para las dos razones de que la tasa no sea la de hoy: el
  // feriado ya explica por qué sigue la del día anterior.
  const arrastrada = s.todayIsHoliday || (!s.isCurrent && s.rate !== null)

  return (
    <div className="flex flex-col gap-shell-gap-block">
      <Seccion
        titulo="La tasa del día"
        info="El precio se pacta en dólares y se cobra en bolívares a la tasa BCV del dólar del día del pago. La base la busca sola cada día a las 10:00, al cerrar el día operativo y antes de que corran los cargos por atraso y las liquidaciones. Los fines de semana y los feriados el BCV no publica, y seguir con la última tasa es lo correcto. Si pasan más de dos días hábiles sin una tasa nueva, el aviso aparece también en Inicio."
        controles={
          <>
            {sync.data?.ok && !sync.data.skipped && (
              <span className="type-panel-caption text-on-surface-variant">
                {sync.data.rate !== undefined ? formatTasa(sync.data.rate) : 'Actualizada'}
                {sync.data.source ? ` · ${sync.data.source}` : ''}
              </span>
            )}
            <Button size="sm" variant="tonal" disabled={sync.isPending} onClick={() => sync.mutate()}>
              {sync.isPending ? 'Buscando…' : 'Buscar la tasa ahora'}
            </Button>
          </>
        }
      >
        {arrastrada && (
          <Callout
            tone="info"
            titulo={
              s.todayIsHoliday
                ? `Hoy es feriado${s.holidayName ? ` (${s.holidayName})` : ''}`
                : `Sigue en vigor la tasa del ${formatDay(s.effectiveDate)}`
            }
          >
            {s.todayIsHoliday
              ? 'El BCV no publica, y que la tasa sea la del día anterior es lo normal.'
              : 'Es normal en fin de semana o feriado; cualquier otro día conviene buscarla ahora.'}
          </Callout>
        )}

        <StatGrid cols={4}>
          <Stat
            label="Tasa vigente"
            value={s.rate === null ? 'Ninguna' : formatTasa(s.rate)}
            senal={senalDeLaTasa(s)}
            hint={s.effectiveDate ? `Vigencia ${formatDay(s.effectiveDate)}` : 'No hay ninguna cargada'}
          />
          <Stat
            label="Día operativo"
            value={formatDay(s.businessDate)}
            hint="Cambia a las 10:00 de Caracas"
          />
          <Stat
            label="Entró hace"
            value={antiguedad(s)}
            senal={senalDeLaAntiguedad(s)}
            hint={s.fetchedAt ? formatDateTime(s.fetchedAt) : undefined}
          />
          <Stat
            label="Último intento"
            value={
              s.lastSyncStatus ? (SYNC_STATUS_LABEL[s.lastSyncStatus] ?? s.lastSyncStatus) : '—'
            }
            senal={
              falloElUltimoIntento(s)
                ? { tone: 'warning', texto: 'Falló la sincronización' }
                : undefined
            }
            hint={s.lastSyncAt ? formatDateTime(s.lastSyncAt) : 'Todavía no se ha intentado'}
          />
        </StatGrid>

        {s.lastSyncDetail && falloElUltimoIntento(s) && (
          <Callout tone="warning" titulo="La última búsqueda no trajo la tasa">
            {s.lastSyncDetail}
          </Callout>
        )}

        {sync.data && !sync.data.ok && (
          <Callout tone="warning" titulo="Ninguna fuente devolvió una tasa válida">
            Fuentes consultadas: {sync.data.sourcesTried ?? 0}. Sigue en vigor la tasa anterior.
          </Callout>
        )}

        {sync.isError && (
          <ErrorBox title="No se pudo buscar la tasa" detail={describeError(sync.error)} />
        )}
      </Seccion>

      <CargarTasaAMano
        vigente={s.rate}
        vigenteDesde={s.effectiveDate}
        isSuperAdmin={isSuperAdmin}
        onGuardada={(tasa) => {
          avisar(`Tasa cargada a mano: ${formatTasa(tasa)}. Rige para los pagos de hoy.`)
          refresh()
        }}
      />

      <Seccion titulo="Historial">
        {history.isLoading && <SkeletonTable rows={5} columns={5} />}
        {history.isError && (
          <ErrorBox title="No se pudo leer el historial de la tasa" detail={describeError(history.error)} />
        )}
        {history.data && history.data.length > 0 && (
          <Table headers={['Vigencia', 'Tasa', 'Variación', 'Origen', 'Entró']}>
            {history.data.map((row, i) => {
              // La tabla va de nueva a vieja: la fila siguiente es el día anterior.
              const anterior = history.data.at(i + 1)
              return (
                <Tr key={row.effectiveDate}>
                  <Td className="whitespace-nowrap font-medium">{formatDay(row.effectiveDate)}</Td>
                  <Td className="tabular-nums">{formatTasa(row.rate)}</Td>
                  <Td className="tabular-nums text-on-surface-variant">
                    {formatVariacion(anterior ? variacionPct(anterior.rate, row.rate) : null)}
                  </Td>
                  <Td>
                    {row.sourceKey === 'manual' ? (
                      <Badge>A mano</Badge>
                    ) : (
                      <span className="type-panel-caption text-on-surface-variant">
                        {row.sourceKey ?? '—'}
                      </span>
                    )}
                  </Td>
                  <Td className="whitespace-nowrap type-panel-caption text-on-surface-variant">
                    {formatDateTime(row.fetchedAt)}
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

/**
 * Cargar la tasa a mano. Solo para cuando las fuentes estén caídas o el BCV
 * publique un salto que la búsqueda automática rechace.
 */
function CargarTasaAMano({
  vigente,
  vigenteDesde,
  isSuperAdmin,
  onGuardada,
}: {
  vigente: number | null
  vigenteDesde: string | null
  isSuperAdmin: boolean
  onGuardada: (tasa: number) => void
}) {
  const [texto, setTexto] = useState('')
  const [revisando, setRevisando] = useState(false)

  const tasa = leerMonto(texto)
  const valida = tasa !== null && tasa > 0
  const variacion = valida ? variacionPct(vigente, tasa) : null

  const save = useMutation({
    mutationFn: (params: { rate: number; note: string }) => setFxRate(params),
    onSuccess: (_data, params) => {
      setTexto('')
      setRevisando(false)
      onGuardada(params.rate)
    },
  })

  const motivoApagado = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : texto.trim() === ''
      ? 'Escribe la tasa del dólar en bolívares.'
      : !valida
        ? 'La tasa no se entiende. Escríbela con coma decimal, por ejemplo 954,0244.'
        : undefined

  return (
    <Seccion
      titulo="Cargar la tasa a mano"
      info="Solo cuando las fuentes estén caídas o la búsqueda rechace la publicada. Queda en la bitácora con tu nombre."
    >
      <Card className="flex flex-col items-start gap-3">
        <Input
          id="fx-rate"
          label="Tasa (Bs. por dólar)"
          value={texto}
          onChange={setTexto}
          inputMode="decimal"
          placeholder="954,0244"
          error={texto.trim() !== '' && !valida}
          className="w-56"
        />
        {/* Escrito y no en el tooltip: la del dólar es la que se sabe de
            memoria, y cargarla por error cobra mal todo el día. */}
        <p className="type-panel-caption text-on-surface-variant">
          Es la tasa del dólar, no la del dólar.
        </p>
        <Button
          size="md"
          disabled={motivoApagado !== undefined}
          motivoApagado={motivoApagado}
          onClick={() => setRevisando(true)}
        >
          Revisar la tasa nueva
        </Button>
      </Card>

      {revisando && tasa !== null && (
        <ConfirmDialog
          nivel="critico"
          title="Cargar la tasa a mano"
          summary="Esta tasa decide cuánto paga en bolívares todo el que pague hoy, y a qué tasa se cotizan las liquidaciones a las clínicas."
          detail={
            <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 type-panel-body">
              <dt className="text-on-surface-variant">Vigente</dt>
              <dd className="tabular-nums text-on-surface">
                {vigente === null ? 'Ninguna' : formatTasa(vigente)}
                {vigenteDesde ? ` (desde el ${formatDay(vigenteDesde)})` : ''}
              </dd>
              <dt className="text-on-surface-variant">Nueva</dt>
              <dd className="tabular-nums font-semibold text-on-surface">{formatTasa(tasa)}</dd>
              <dt className="text-on-surface-variant">Diferencia</dt>
              <dd
                className={`tabular-nums ${
                  variacion !== null && Math.abs(variacion) >= 5 ? 'text-warning' : 'text-on-surface'
                }`}
              >
                {formatVariacion(variacion)}
              </dd>
            </dl>
          }
          reasonLabel="Motivo"
          reasonPlaceholder="Las fuentes no responden; tasa tomada de bcv.org.ve"
          confirmLabel={`Usar ${formatTasa(tasa)} hoy`}
          busy={save.isPending}
          error={save.isError ? describeError(save.error) : undefined}
          onConfirm={(motivo) => save.mutate({ rate: tasa, note: motivo })}
          onClose={() => setRevisando(false)}
        />
      )}
    </Seccion>
  )
}
