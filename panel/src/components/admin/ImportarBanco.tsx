import { useRef, useState } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import type { UseQueryResult } from '@tanstack/react-query'

import {
  Badge,
  Button,
  Callout,
  Card,
  ConfirmDialog,
  ErrorBox,
  InfoDot,
  NoSePudoLeer,
  Seccion,
  Select,
  SkeletonTable,
  Table,
  Td,
  Tr,
  formatDateTime,
  formatDay,
  formatVes,
} from '@/components/ui'
import { fetchStatementImports, importStatement } from '@/features/admin/api'
import type { StatementImport } from '@/features/admin/api'
import { parseStatementFile } from '@/features/admin/csv'
import type { ParseResult } from '@/features/admin/csv'
import { BANKS, RONDA_BANK } from '@/features/admin/banks'
import { extractoViejo } from '@/features/admin/colaDePagos'
import { useToast } from '@/components/Toast'
import { describeError } from '@/lib/supabase'

/** Cuántas importaciones se enseñan en el historial. */
const LIMITE_HISTORIAL = 30

type Historial = {
  lastImportAt: string | null
  daysSinceLast: number | null
  rows: StatementImport[]
}

/** Todo lo que traía el archivo: abonos, cargos y lo que no se pudo leer. */
function movimientosLeidos(parsed: ParseResult): number {
  return parsed.lines.length + parsed.debits + parsed.skipped.length
}

/** Qué hace esta ventana y qué pasa después, en el `InfoDot` del título. */
const QUE_ES_IMPORTAR =
  'Cotejar con el extracto es lo que convierte una referencia de seis dígitos en una prueba. Sirve el .xls tal como se descarga del banco, y también un TXT o un CSV: se saltan el membrete y los totales, se detectan las columnas y se importan solo los abonos. Lo que encaja con un pago reportado sale cotejado; lo que no reclama nadie cae en Abonos sin dueño. Subir dos veces el mismo archivo con el mismo banco no duplica nada.'

/**
 * Importar el extracto del banco.
 *
 * Es el mismo trabajo que aprobar pagos: comprobar que un pago existió. Sin
 * este paso, aprobar un pago es fiarse de lo que escribió la persona, y con
 * referencias de seis dígitos eso no es una prueba.
 *
 * El import es idempotente dentro de un banco: cada abono se identifica por
 * banco, referencia, fecha y monto, así que subir el mismo archivo dos veces
 * no duplica nada. Subirlo bajo OTRO banco sí lo duplica (banks.ts), y por
 * eso cambiar de banco respecto al último import pide confirmación.
 */
export function ImportarBanco() {
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const avisar = useToast()
  const fileRef = useRef<HTMLInputElement>(null)

  const [bank, setBank] = useState<string>(RONDA_BANK)
  const [parsed, setParsed] = useState<ParseResult | null>(null)
  const [parseError, setParseError] = useState<string | null>(null)
  const [fileName, setFileName] = useState<string | null>(null)
  const [confirmandoBanco, setConfirmandoBanco] = useState(false)

  const historial = useQuery({
    queryKey: ['statement-imports', LIMITE_HISTORIAL],
    queryFn: () => fetchStatementImports(LIMITE_HISTORIAL),
  })
  const ultimoBanco = historial.data?.rows[0]?.bank ?? null
  const otroBanco = ultimoBanco !== null && ultimoBanco !== bank

  const mutation = useMutation({
    mutationFn: () =>
      importStatement(
        bank,
        parsed!.lines,
        fileName ?? undefined,
        // Lo leído, no lo importado: los cargos y las filas descartadas
        // cuentan. Es lo que deja ver después que un archivo de 300
        // movimientos solo trajo 4 abonos porque el banco cambió las
        // columnas.
        movimientosLeidos(parsed!),
      ),
    onSuccess: () => {
      const leidas = movimientosLeidos(parsed!)
      avisar(
        `Importados ${parsed!.lines.length} ${parsed!.lines.length === 1 ? 'abono' : 'abonos'} de ${leidas} ${leidas === 1 ? 'movimiento' : 'movimientos'}`,
      )
      // El cotejo de la cola sale de estos abonos: hay que recalcularla.
      void queryClient.invalidateQueries({ queryKey: ['payment-queue'] })
      void queryClient.invalidateQueries({ queryKey: ['payment-report'] })
      void queryClient.invalidateQueries({ queryKey: ['statement-matches'] })
      void queryClient.invalidateQueries({ queryKey: ['statement-imports'] })
      void queryClient.invalidateQueries({ queryKey: ['unmatched-deposits'] })
      void queryClient.invalidateQueries({ queryKey: ['reconciliation-health'] })
    },
  })

  /** Importar, o preguntar antes si el banco no es el de la última vez. */
  function importar() {
    if (otroBanco) setConfirmandoBanco(true)
    else mutation.mutate()
  }

  async function handleFile(file: File) {
    setParseError(null)
    setParsed(null)
    mutation.reset()
    setFileName(file.name)

    try {
      // El formato se decide por la firma del archivo y no por la extensión:
      // el .xls del BNC es un documento OLE de verdad, y su .txt es un CSV
      // con otro nombre.
      setParsed(parseStatementFile(new Uint8Array(await file.arrayBuffer())))
    } catch (error) {
      setParseError(describeError(error) ?? 'No pudimos leer el archivo.')
    }
  }

  function reset() {
    setParsed(null)
    setParseError(null)
    setFileName(null)
    mutation.reset()
    if (fileRef.current) fileRef.current.value = ''
  }

  return (
    <div className="flex max-w-3xl flex-col gap-6">
      <Card>
        <Seccion as="div" titulo="Subir el extracto del banco" info={QUE_ES_IMPORTAR}>
          <p className="type-panel-caption text-on-surface-variant">
            Sirve el .xls del banco, un TXT o un CSV.
          </p>

          <Select
            id="bank"
            label="Banco"
            value={bank}
            options={BANKS.map((b) => ({ value: b.name, label: `${b.code} · ${b.name}` }))}
            onChange={setBank}
          />

          {/* Se queda escrito: importar con otro banco duplica los movimientos,
              y eso no se deshace. */}
          {otroBanco && (
            <Callout tone="warning" titulo={`El último extracto se importó como «${ultimoBanco}»`}>
              Si es la misma cuenta, importarlo como «{bank}» repite sus movimientos.
            </Callout>
          )}

          <input
            ref={fileRef}
            type="file"
            accept=".xls,.csv,.txt,application/vnd.ms-excel,text/csv,text/plain"
            onChange={(e) => {
              const file = e.target.files?.[0]
              if (file) void handleFile(file)
            }}
            className="block w-full type-panel-body text-on-surface-variant file:mr-4 file:h-panel-control-sm file:rounded-panel-control file:border-0 file:bg-panel-control file:px-4 file:font-semibold file:text-on-surface hover:file:bg-shell-inset"
          />

          {parseError && <ErrorBox title="No pudimos leer el archivo" detail={parseError} />}
        </Seccion>
      </Card>

      {parsed && (
        <Card>
          <Seccion
            as="div"
            titulo="Revisa antes de importar"
            controles={
              <Badge tone={parsed.lines.length > 0 ? 'success' : 'warning'} icono>
                {parsed.lines.length} abonos
              </Badge>
            }
          >
            <p className="flex flex-wrap items-center gap-x-1.5 type-panel-caption text-on-surface-variant">
              <span className="text-on-surface">{fileName}</span>· {movimientosLeidos(parsed)}{' '}
              movimientos leídos · {parsed.debits === 1 ? '1 cargo' : `${parsed.debits} cargos`} que
              no se importan
              <InfoDot
                title="Cómo se leyó el archivo"
                what={`Cabecera en la fila ${parsed.headerRow}. Columnas: ${parsed.detectedColumns.date}, ${parsed.detectedColumns.reference} y ${parsed.detectedColumns.amount}.`}
              />
            </p>

            {parsed.skipped.length > 0 && (
              <Callout
                tone="warning"
                titulo={`${parsed.skipped.length} ${
                  parsed.skipped.length === 1 ? 'fila descartada' : 'filas descartadas'
                }`}
                detalles={
                  <ul className="flex flex-col gap-1">
                    {parsed.skipped.slice(0, 8).map((s) => (
                      <li key={s.row}>
                        Fila {s.row}: {s.reason}
                      </li>
                    ))}
                    {parsed.skipped.length > 8 && <li>…y {parsed.skipped.length - 8} más</li>}
                  </ul>
                }
              />
            )}

            {parsed.lines.length > 0 && <MuestraDeAbonos parsed={parsed} />}

            {mutation.isError && (
              <ErrorBox title="No se pudo importar" detail={describeError(mutation.error)} />
            )}

            {mutation.isSuccess ? (
              <div className="flex flex-col gap-4">
                <Callout tone="success" titulo="Importado">
                  {movimientosLeidos(parsed)} movimientos leídos · {mutation.data.received} abonos ·{' '}
                  {mutation.data.duplicates} ya estaban · {mutation.data.inserted} nuevos.
                </Callout>
                <div className="flex flex-wrap gap-3">
                  <Button size="md" onClick={() => void navigate({ to: '/admin/cobros' })}>
                    Ver pagos reportados
                  </Button>
                  <Button
                    variant="tonal"
                    size="md"
                    onClick={() => void navigate({ to: '/admin/cobros', search: { vista: 'abonos' } })}
                  >
                    Ver abonos sin dueño
                  </Button>
                  <Button variant="text" size="md" onClick={reset}>
                    Importar otro archivo
                  </Button>
                </div>
              </div>
            ) : (
              <div className="flex flex-wrap items-start gap-3">
                <Button
                  size="md"
                  disabled={mutation.isPending || parsed.lines.length === 0}
                  motivoApagado={
                    parsed.lines.length === 0 ? 'El archivo no trae ningún abono.' : undefined
                  }
                  onClick={importar}
                >
                  {mutation.isPending ? 'Importando…' : `Importar ${parsed.lines.length} abonos`}
                </Button>
                <Button variant="text" size="md" onClick={reset}>
                  Cancelar
                </Button>
              </div>
            )}
          </Seccion>
        </Card>
      )}

      <HistorialDeImports query={historial} />

      {confirmandoBanco && parsed && (
        <ConfirmDialog
          title="Importar con otro banco"
          summary={`El último extracto se importó como «${ultimoBanco ?? ''}» y este va como «${bank}».`}
          detail={
            <p className="type-panel-body text-on-surface-variant">
              Si el archivo es de la misma cuenta, sus movimientos entran otra vez y los pagos
              salen cotejados dos veces. Confirma solo si es de otra cuenta.
            </p>
          }
          confirmLabel={`Importar como «${bank}»`}
          busy={mutation.isPending}
          onConfirm={() => {
            setConfirmandoBanco(false)
            mutation.mutate()
          }}
          onClose={() => setConfirmandoBanco(false)}
        />
      )}
    </div>
  )
}

/** Los cinco primeros abonos del archivo, para ver que las columnas cuadran. */
function MuestraDeAbonos({ parsed }: { parsed: ParseResult }) {
  return (
    <div className="overflow-x-auto rounded-panel-control border border-panel-hairline">
      <table className="w-full type-panel-body">
        <thead>
          <tr className="border-b border-panel-hairline text-left type-panel-caption font-semibold text-panel-muted">
            <th className="px-3 py-2.5">Fecha</th>
            <th className="px-3 py-2.5">Referencia</th>
            <th className="px-3 py-2.5 text-right">Monto</th>
          </tr>
        </thead>
        <tbody>
          {parsed.lines.slice(0, 5).map((line, i) => (
            <tr key={i} className="border-b border-panel-hairline last:border-0">
              <td className="px-3 py-2.5 text-on-surface-variant">{formatDay(line.moved_on)}</td>
              <td className="px-3 py-2.5 font-mono text-on-surface">{line.reference}</td>
              <td className="px-3 py-2.5 text-right tabular-nums text-on-surface">
                {formatVes(line.amount_ves)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {parsed.lines.length > 5 && (
        <p className="border-t border-panel-hairline px-3 py-2.5 type-panel-caption text-on-surface-variant">
          …y {parsed.lines.length - 5} abonos más
        </p>
      )}
    </div>
  )
}

/**
 * Quién subió qué archivo y cuándo.
 *
 * El import es la única tarea del panel que nadie recuerda haber hecho: se
 * sube un archivo, la cola se cuadra y se olvida. Dos semanas después medio
 * panel miente (los pagos no se cotejan, los abonos sin dueño no aparecen) y
 * no hay ningún error en pantalla que lo diga.
 */
function HistorialDeImports({ query }: { query: UseQueryResult<Historial> }) {
  if (query.isPending) return <SkeletonTable rows={3} columns={4} />

  // Un historial que no se pudo leer no es un historial vacío: dicho así, se
  // leería como «nunca se ha importado nada».
  if (query.isError) {
    return (
      <Seccion as="div" titulo="Lo que se ha importado">
        <Card tone="inset">
          <NoSePudoLeer onReintentar={() => void query.refetch()} />
        </Card>
      </Seccion>
    )
  }

  const d = query.data
  const atrasado = extractoViejo(d.daysSinceLast)

  return (
    <Seccion as="div" titulo="Lo que se ha importado">
      {atrasado && (
        <Callout
          tone="warning"
          titulo={
            d.daysSinceLast === null
              ? 'Nunca se ha importado un extracto del banco'
              : `Hace ${d.daysSinceLast} días que no se importa el extracto del banco`
          }
        >
          Mientras tanto, aprobar un pago es fiarse de la referencia que escribió el paciente.
        </Callout>
      )}

      {d.rows.length > 0 && (
        <Table headers={['Cuándo', 'Archivo', 'Lo que trajo', 'Quién']}>
          {d.rows.map((i) => (
            <Tr key={i.id}>
              <Td className="whitespace-nowrap text-on-surface-variant">
                {formatDateTime(i.importedAt)}
              </Td>
              <Td>
                <p className="text-on-surface">{i.fileName ?? 'Sin nombre'}</p>
                <p className="type-panel-caption text-on-surface-variant">{i.bank}</p>
              </Td>
              <Td className="whitespace-nowrap type-panel-caption text-on-surface-variant">
                {i.rowsRead} movimientos · {i.deposits} abonos
                <span className="block">
                  {i.inserted} nuevos · {i.duplicates} ya estaban
                </span>
              </Td>
              <Td className="text-on-surface-variant">{i.importedByName}</Td>
            </Tr>
          ))}
        </Table>
      )}
    </Seccion>
  )
}
