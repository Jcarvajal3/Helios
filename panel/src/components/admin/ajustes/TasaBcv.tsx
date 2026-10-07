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
  Segmented,
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
import type { Moneda, SenalDeCifra } from '@/components/ui'
import { formatTasa, formatVariacion, variacionPct } from '@/features/admin/ajustesReglas'
import { fetchFxHistory, fetchFxStatus, setFxRate, syncFxRate } from '@/features/admin/fx'
import type { FxStatus, FxSyncResult } from '@/features/admin/fx'
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

/** «la tasa del dólar», «la tasa del euro». */
const DE_LA_MONEDA: Record<Moneda, string> = { USD: 'del dólar', EUR: 'del euro' }

const MONEDAS: Array<{ value: Moneda; label: string }> = [
  { value: 'USD', label: 'Dólar' },
  { value: 'EUR', label: 'Euro' },
]

/**
 * Las claves de cada moneda. La del dólar sigue siendo `['fx-status']` a
 * secas: es la que leen Inicio, la cartera y la cobranza, y comparten caché.
 */
function claveDelEstado(moneda: Moneda): readonly unknown[] {
  return moneda === 'USD' ? ['fx-status'] : ['fx-status', 'EUR']
}

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

/** Lo que se dice al terminar la búsqueda, con las dos monedas en una frase. */
function fraseDeLaBusqueda(traida: FxSyncResult): string {
  const partes = [
    traida.rate === undefined ? null : `dólar ${formatTasa(traida.rate, 'USD')}`,
    traida.eur?.rate === undefined ? null : `euro ${formatTasa(traida.eur.rate, 'EUR')}`,
  ].filter((p): p is string => p !== null)
  // La llamada puede salir bien y no traer tasa: fin de semana, feriado o el
  // BCV todavía no ha publicado. Decir «traída» ahí sería falso.
  return partes.length === 0
    ? 'El BCV no ha publicado tasas nuevas. Siguen en vigor las últimas.'
    : `Tasas del BCV traídas: ${partes.join(' · ')}`
}

/**
 * Las tasas BCV del dólar y del euro: las que están en vigor, la búsqueda
 * automática y la carga a mano.
 *
 * Desde el 2026-10-07 una orden puede cobrarse en euros, y el paciente la paga
 * en bolívares a la tasa del euro del día en que paga; todo lo demás, a la del
 * dólar. Las dos entran juntas con la misma búsqueda y se cargan a mano por
 * separado. Cargar una decide cuánto paga en bolívares todo el que pague hoy,
 * así que pasa por el diálogo crítico con la tasa vigente al lado de la nueva.
 */
export function TasaBcv() {
  const avisar = useToast()
  const client = useQueryClient()
  const isSuperAdmin = useIsSuperAdmin()

  const dolar = useQuery({ queryKey: claveDelEstado('USD'), queryFn: () => fetchFxStatus('USD') })
  const euro = useQuery({ queryKey: claveDelEstado('EUR'), queryFn: () => fetchFxStatus('EUR') })

  const [monedaDelHistorial, setMonedaDelHistorial] = useState<Moneda>('USD')
  const history = useQuery({
    queryKey: ['fx-history', monedaDelHistorial, 30],
    queryFn: () => fetchFxHistory(30, monedaDelHistorial),
  })

  const refresh = () => {
    // `['fx-status']` y `['fx-history']` son prefijo de las dos monedas.
    void client.invalidateQueries({ queryKey: ['fx-status'] })
    void client.invalidateQueries({ queryKey: ['fx-history'] })
    void client.invalidateQueries({ queryKey: ['admin-overview'] })
  }

  const sync = useMutation({
    mutationFn: syncFxRate,
    onSuccess: (traida) => {
      avisar(fraseDeLaBusqueda(traida))
      refresh()
    },
  })

  if (dolar.isLoading) return <SkeletonCard />
  if (dolar.isError || !dolar.data) {
    return <ErrorBox title="No se pudo leer la tasa del dólar" detail={describeError(dolar.error)} />
  }

  const fallos = sync.data
    ? [
        !sync.data.ok ? { moneda: 'dólar', serie: sync.data } : null,
        sync.data.eur && !sync.data.eur.ok ? { moneda: 'euro', serie: sync.data.eur } : null,
      ].filter((f) => f !== null)
    : []

  return (
    <div className="flex flex-col gap-shell-gap-block">
      <Seccion
        titulo="Las tasas del día"
        info="El precio se pacta en dólares o en euros, según la orden, y el paciente lo paga en bolívares a la tasa BCV de esa moneda del día del pago; a la clínica se le paga igual. La base busca las dos cada día, antes de que corran los cargos por atraso y las liquidaciones. Los fines de semana y los feriados el BCV no publica, y seguir con la última tasa es lo correcto. Si pasan más de dos días hábiles sin una tasa nueva del dólar, el aviso aparece también en Inicio."
        controles={
          <Button size="sm" variant="tonal" disabled={sync.isPending} onClick={() => sync.mutate()}>
            {sync.isPending ? 'Buscando…' : 'Buscar las tasas ahora'}
          </Button>
        }
      >
        {fallos.map((f) => (
          <Callout key={f.moneda} tone="warning" titulo={`Ninguna fuente devolvió una tasa válida del ${f.moneda}`}>
            {f.serie.error ?? `Fuentes consultadas: ${f.serie.sourcesTried ?? 0}.`} Sigue en vigor la tasa
            anterior.
          </Callout>
        ))}

        {sync.isError && (
          <ErrorBox title="No se pudieron buscar las tasas" detail={describeError(sync.error)} />
        )}

        <EstadoDeLaTasa moneda="USD" s={dolar.data} />

        {euro.isLoading && <SkeletonCard />}
        {euro.isError && (
          <ErrorBox title="No se pudo leer la tasa del euro" detail={describeError(euro.error)} />
        )}
        {euro.data && <EstadoDeLaTasa moneda="EUR" s={euro.data} />}
      </Seccion>

      <CargarTasaAMano
        vigentes={{ USD: dolar.data, EUR: euro.data ?? null }}
        isSuperAdmin={isSuperAdmin}
        onGuardada={(tasa, moneda) => {
          avisar(
            `Tasa ${DE_LA_MONEDA[moneda]} cargada a mano: ${formatTasa(tasa, moneda)}. Rige para los pagos de hoy.`,
          )
          refresh()
        }}
      />

      <Seccion
        titulo="Historial"
        controles={
          <Segmented
            etiqueta="Moneda del historial"
            options={MONEDAS}
            value={monedaDelHistorial}
            onChange={setMonedaDelHistorial}
          />
        }
      >
        {history.isLoading && <SkeletonTable rows={5} columns={5} />}
        {history.isError && (
          <ErrorBox
            title={`No se pudo leer el historial de la tasa ${DE_LA_MONEDA[monedaDelHistorial]}`}
            detail={describeError(history.error)}
          />
        )}
        {history.data && history.data.length === 0 && (
          <p className="type-panel-body text-on-surface-variant">
            Todavía no ha entrado ninguna tasa {DE_LA_MONEDA[monedaDelHistorial]}.
          </p>
        )}
        {history.data && history.data.length > 0 && (
          <Table headers={['Vigencia', 'Tasa', 'Variación', 'Origen', 'Entró']}>
            {history.data.map((row, i) => {
              // La tabla va de nueva a vieja: la fila siguiente es el día anterior.
              const anterior = history.data.at(i + 1)
              return (
                <Tr key={row.effectiveDate}>
                  <Td className="whitespace-nowrap font-medium">{formatDay(row.effectiveDate)}</Td>
                  <Td className="tabular-nums">{formatTasa(row.rate, monedaDelHistorial)}</Td>
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

/** La tasa de una moneda: la vigente, desde cuándo y cómo fue el último intento. */
function EstadoDeLaTasa({ moneda, s }: { moneda: Moneda; s: FxStatus }) {
  // Un solo aviso para las dos razones de que la tasa no sea la de hoy: el
  // feriado ya explica por qué sigue la del día anterior.
  const arrastrada = s.todayIsHoliday || (!s.isCurrent && s.rate !== null)

  return (
    <div className="flex flex-col gap-3">
      <h3 className="type-panel-label text-on-surface-variant">La tasa {DE_LA_MONEDA[moneda]}</h3>

      {arrastrada && (
        <Callout
          tone="info"
          titulo={
            s.todayIsHoliday
              ? `Hoy es feriado${s.holidayName ? ` (${s.holidayName})` : ''}`
              : `Sigue en vigor la tasa ${DE_LA_MONEDA[moneda]} del ${formatDay(s.effectiveDate)}`
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
          value={s.rate === null ? 'Ninguna' : formatTasa(s.rate, moneda)}
          senal={senalDeLaTasa(s)}
          hint={s.effectiveDate ? `Vigencia ${formatDay(s.effectiveDate)}` : 'No hay ninguna cargada'}
        />
        <Stat label="Día operativo" value={formatDay(s.businessDate)} hint="Cambia a medianoche de Caracas" />
        <Stat
          label="Entró hace"
          value={antiguedad(s)}
          senal={senalDeLaAntiguedad(s)}
          hint={s.fetchedAt ? formatDateTime(s.fetchedAt) : undefined}
        />
        <Stat
          label="Último intento"
          value={s.lastSyncStatus ? (SYNC_STATUS_LABEL[s.lastSyncStatus] ?? s.lastSyncStatus) : '—'}
          senal={falloElUltimoIntento(s) ? { tone: 'warning', texto: 'Falló la sincronización' } : undefined}
          hint={s.lastSyncAt ? formatDateTime(s.lastSyncAt) : 'Todavía no se ha intentado'}
        />
      </StatGrid>

      {s.lastSyncDetail && falloElUltimoIntento(s) && (
        <Callout tone="warning" titulo={`La última búsqueda no trajo la tasa ${DE_LA_MONEDA[moneda]}`}>
          {s.lastSyncDetail}
        </Callout>
      )}
    </div>
  )
}

/**
 * Cargar una tasa a mano, eligiendo de qué moneda. Solo para cuando las
 * fuentes estén caídas o el BCV publique un salto que la búsqueda automática
 * rechace.
 */
function CargarTasaAMano({
  vigentes,
  isSuperAdmin,
  onGuardada,
}: {
  /** El estado de cada moneda; el del euro, `null` si no se pudo leer. */
  vigentes: Record<Moneda, FxStatus | null>
  isSuperAdmin: boolean
  onGuardada: (tasa: number, moneda: Moneda) => void
}) {
  const [moneda, setMoneda] = useState<Moneda>('USD')
  const [texto, setTexto] = useState('')
  const [revisando, setRevisando] = useState(false)

  const vigente = vigentes[moneda]?.rate ?? null
  const vigenteDesde = vigentes[moneda]?.effectiveDate ?? null
  const otra: Moneda = moneda === 'USD' ? 'EUR' : 'USD'
  const tasaDeLaOtra = vigentes[otra]?.rate ?? null

  const tasa = leerMonto(texto)
  const valida = tasa !== null && tasa > 0
  const variacion = valida ? variacionPct(vigente, tasa) : null
  // La confusión cara: escribir la del dólar en la casilla del euro (o al
  // revés). Si la nueva se parece más a la vigente de la OTRA moneda que a la
  // suya, se avisa antes de abrir el diálogo.
  const pareceDeLaOtra =
    valida &&
    vigente !== null &&
    tasaDeLaOtra !== null &&
    Math.abs(tasa - tasaDeLaOtra) < Math.abs(tasa - vigente)

  const save = useMutation({
    mutationFn: (params: { rate: number; moneda: Moneda; note: string }) => setFxRate(params),
    onSuccess: (_data, params) => {
      setTexto('')
      setRevisando(false)
      onGuardada(params.rate, params.moneda)
    },
  })

  const motivoApagado = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : texto.trim() === ''
      ? `Escribe la tasa ${DE_LA_MONEDA[moneda]} en bolívares.`
      : !valida
        ? 'La tasa no se entiende. Escríbela con coma decimal, por ejemplo 954,0244.'
        : undefined

  return (
    <Seccion
      titulo="Cargar una tasa a mano"
      info="Solo cuando las fuentes estén caídas o la búsqueda rechace la publicada. Se elige la moneda: la del dólar y la del euro son dos tasas distintas. Queda en la bitácora con tu nombre."
    >
      <Card className="flex flex-col items-start gap-3">
        <Segmented
          etiqueta="Moneda de la tasa"
          options={MONEDAS}
          value={moneda}
          onChange={(m) => {
            setMoneda(m)
            setRevisando(false)
          }}
        />
        <Input
          id="fx-rate"
          label={`Tasa (Bs. por ${moneda === 'EUR' ? 'euro' : 'dólar'})`}
          value={texto}
          onChange={setTexto}
          inputMode="decimal"
          placeholder={vigente === null ? '954,0244' : vigente.toLocaleString('es-VE', { maximumFractionDigits: 4 })}
          error={texto.trim() !== '' && !valida}
          className="w-56"
        />
        {/* Escrito y no en el tooltip: las dos cifras se parecen, y cargar
            una en la casilla de la otra cobra mal todo el día. */}
        <p className={`type-panel-caption ${pareceDeLaOtra ? 'text-warning' : 'text-on-surface-variant'}`}>
          {pareceDeLaOtra
            ? `Ojo: se parece más a la tasa ${DE_LA_MONEDA[otra]} (${formatTasa(tasaDeLaOtra, otra)}) que a la ${DE_LA_MONEDA[moneda]}.`
            : `Es la tasa ${DE_LA_MONEDA[moneda]}, no la ${DE_LA_MONEDA[otra]}.`}
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
          title={`Cargar la tasa ${DE_LA_MONEDA[moneda]} a mano`}
          summary={
            moneda === 'EUR'
              ? 'Esta tasa decide cuántos bolívares paga hoy quien pague una orden cobrada en euros, y a qué tasa se cotiza lo que se les paga en euros a las clínicas.'
              : 'Esta tasa decide cuánto paga en bolívares todo el que pague hoy una orden en dólares o un cargo por atraso, y a qué tasa se cotizan las liquidaciones en dólares a las clínicas.'
          }
          detail={
            <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 type-panel-body">
              <dt className="text-on-surface-variant">Moneda</dt>
              <dd className="text-on-surface">{moneda === 'EUR' ? 'Euro' : 'Dólar'}</dd>
              <dt className="text-on-surface-variant">Vigente</dt>
              <dd className="tabular-nums text-on-surface">
                {vigente === null ? 'Ninguna' : formatTasa(vigente, moneda)}
                {vigenteDesde ? ` (desde el ${formatDay(vigenteDesde)})` : ''}
              </dd>
              <dt className="text-on-surface-variant">Nueva</dt>
              <dd className="tabular-nums font-semibold text-on-surface">{formatTasa(tasa, moneda)}</dd>
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
          confirmLabel={`Usar ${formatTasa(tasa, moneda)} hoy`}
          busy={save.isPending}
          error={save.isError ? describeError(save.error) : undefined}
          onConfirm={(motivo) => save.mutate({ rate: tasa, moneda, note: motivo })}
          onClose={() => setRevisando(false)}
        />
      )}
    </Seccion>
  )
}
