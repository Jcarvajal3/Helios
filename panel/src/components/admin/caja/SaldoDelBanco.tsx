import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Landmark } from 'lucide-react'

import {
  Badge,
  Button,
  Card,
  EmptyState,
  ErrorBox,
  Input,
  Seccion,
  SkeletonTable,
  Table,
  Td,
  Tr,
  escribirFecha,
  formatDateTime,
  formatDay,
  formatUsd,
  formatVes,
  hoyCaracas,
  leerFecha,
} from '@/components/ui'
import { CUADRA_CON_EL_BANCO } from '@/features/admin/cierreMes'
import { fetchBankBalances, recordBankBalance } from '@/features/admin/proyeccionDeCaja'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { useToast } from '@/components/Toast'
import { leerMonto } from '@/lib/montos'
import { describeError } from '@/lib/supabase'

/** Cuántos cortes se leen: medio año de uno por semana. */
const LIMITE_CORTES = 26

/**
 * Apuntar el saldo del banco y compararlo con el libro.
 *
 * Es la comprobación que ningún sistema hace solo: alguien abre la app del
 * banco, mira la cifra y la escribe. La diferencia con el libro es lo que
 * falta por registrar.
 *
 * `corteInicial` rellena la fecha: el cierre de mes enlaza aquí con el último
 * día del mes ya puesto. La fecha se escribe con el día primero (25/09/2026):
 * el campo de fecha del navegador la enseñaba en formato de EE. UU.
 */
export function SaldoDelBanco({ corteInicial }: { corteInicial?: string }) {
  const queryClient = useQueryClient()
  const isSuperAdmin = useIsSuperAdmin()
  const avisar = useToast()

  const [bolivares, setBolivares] = useState('')
  const [euros, setEuros] = useState('')
  const [fechaTexto, setFechaTexto] = useState(() => escribirFecha(corteInicial ?? hoyCaracas()))
  const [nota, setNota] = useState('')

  const query = useQuery({
    queryKey: ['bank-balances', LIMITE_CORTES],
    queryFn: () => fetchBankBalances(LIMITE_CORTES),
  })

  // «1.250.400,00» es lo que se copia de la app del banco.
  const saldoVes = leerMonto(bolivares)
  const saldoEur = leerMonto(euros)
  const fecha = leerFecha(fechaTexto)

  const guardar = useMutation({
    mutationFn: (dia: string) =>
      recordBankBalance({
        balanceVes: saldoVes ?? undefined,
        balanceUsd: saldoEur ?? undefined,
        checkedOn: dia,
        note: nota.trim() || undefined,
      }),
    onSuccess: (_, dia) => {
      avisar(`Corte del ${formatDay(dia)} apuntado. La diferencia con el libro ya está en la tabla`)
      setBolivares('')
      setEuros('')
      setNota('')
      void queryClient.invalidateQueries({ queryKey: ['bank-balances'] })
    },
  })

  const hayCifra = bolivares.trim() !== '' || euros.trim() !== ''
  const bsIlegible = bolivares.trim() !== '' && saldoVes === null
  const eurIlegible = euros.trim() !== '' && saldoEur === null
  const bloqueo = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : !hayCifra
      ? 'Escribe el saldo en bolívares o en dólares.'
      : bsIlegible || eurIlegible
        ? `El saldo en ${bsIlegible ? 'bolívares' : 'dólares'} no es una cifra válida. Escríbelo como 1.250.400,00.`
        : fecha === null
          ? 'Escribe la fecha con el día primero, como 25/09/2026.'
          : fecha > hoyCaracas()
            ? 'La fecha no puede ser futura.'
            : undefined

  return (
    <Seccion
      titulo="Saldo del banco"
      info="El saldo que dice la cuenta del banco en un día, para compararlo con el libro. En bolívares se convierte a la tasa BCV de ese día. Hay un corte por fecha: apuntar otro el mismo día reemplaza el anterior."
    >
      <Card className="flex flex-col gap-4">
        <div className="grid gap-3 md:grid-cols-4">
          <Input
            id="banco-bs"
            label="Saldo en bolívares"
            value={bolivares}
            onChange={setBolivares}
            inputMode="decimal"
            placeholder="1.250.400,00"
            error={bsIlegible}
          />
          <Input
            id="banco-eur"
            label="O en dólares"
            value={euros}
            onChange={setEuros}
            inputMode="decimal"
            placeholder="1.310,25"
            error={eurIlegible}
          />
          <Input
            id="banco-fecha"
            label="Fecha del corte"
            value={fechaTexto}
            onChange={setFechaTexto}
            placeholder="25/09/2026"
            error={fechaTexto.trim() !== '' && fecha === null}
          />
          <Input
            id="banco-nota"
            label="Nota (opcional)"
            value={nota}
            onChange={setNota}
            placeholder="BNC, cuenta principal"
          />
        </div>

        <div className="flex flex-wrap items-start gap-4">
          <Button
            size="md"
            disabled={bloqueo !== undefined || guardar.isPending}
            motivoApagado={bloqueo}
            onClick={() => fecha && guardar.mutate(fecha)}
          >
            {guardar.isPending ? 'Guardando…' : 'Apuntar el saldo'}
          </Button>
        </div>

        {guardar.isError && (
          <ErrorBox title="No se pudo apuntar" detail={describeError(guardar.error)} />
        )}
      </Card>

      {query.isPending && <SkeletonTable rows={4} columns={5} />}

      {query.isError && (
        <ErrorBox title="No se pudieron leer los cortes del banco" detail={describeError(query.error)} />
      )}

      {query.data?.length === 0 && (
        <EmptyState
          icon={<Landmark size={40} />}
          title="Todavía no se ha apuntado ningún saldo"
          description="Una vez por semana basta: la diferencia con el libro es lo que falta por registrar."
          action={
            <Button size="md" variant="tonal" onClick={() => document.getElementById('banco-bs')?.focus()}>
              Apuntar el primer saldo
            </Button>
          }
        />
      )}

      {query.data && query.data.length > 0 && (
        <Table
          headers={[
            'Corte',
            'Saldo en el banco',
            {
              label: 'Caja según el libro contable',
              info: 'El dinero en caja que dice el libro contable al cierre de ese día.',
            },
            {
              label: 'Diferencia',
              info: 'En positivo (hay más en el banco que en el libro) suele ser un pago que llegó y no se aprobó: se busca en Abonos sin dueño. En negativo suele ser una salida no registrada, como una comisión bancaria o una transferencia a una clínica que no se apuntó.',
            },
            'Quién',
          ]}
        >
          {query.data.map((b) => {
            const cuadra = Math.abs(b.differenceUsd) < CUADRA_CON_EL_BANCO
            return (
              <Tr key={b.checkedOn}>
                <Td className="whitespace-nowrap">
                  {formatDay(b.checkedOn)}
                  {b.note && (
                    <span className="block max-w-xs type-panel-caption text-panel-muted">{b.note}</span>
                  )}
                </Td>
                <Td className="whitespace-nowrap tabular-nums">
                  {formatUsd(b.balanceUsd)}
                  {b.balanceVes !== null && (
                    <span className="block type-panel-caption text-panel-muted">
                      {formatVes(b.balanceVes)}
                    </span>
                  )}
                </Td>
                <Td className="tabular-nums text-on-surface-variant">{formatUsd(b.ledgerUsd)}</Td>
                <Td className="tabular-nums">
                  {cuadra ? (
                    <Badge tone="success" icono>
                      Cuadra
                    </Badge>
                  ) : b.differenceUsd > 0 ? (
                    <Link to="/admin/cobros" search={{ vista: 'abonos' }} className="inline-flex">
                      <Badge tone="warning" icono>
                        +{formatUsd(b.differenceUsd)}
                      </Badge>
                    </Link>
                  ) : (
                    <Link
                      to="/admin/contabilidad"
                      search={{ vista: 'libro', hasta: b.checkedOn }}
                      className="inline-flex"
                    >
                      <Badge tone="warning" icono>
                        {formatUsd(b.differenceUsd)}
                      </Badge>
                    </Link>
                  )}
                </Td>
                <Td className="text-on-surface-variant">
                  {b.recordedByName}
                  <span className="block type-panel-caption text-panel-muted">
                    {formatDateTime(b.createdAt)}
                  </span>
                </Td>
              </Tr>
            )
          })}
        </Table>
      )}
    </Seccion>
  )
}
