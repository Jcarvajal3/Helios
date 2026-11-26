import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'

import {
  Button,
  Checkbox,
  ConfirmDialog,
  EmptyState,
  ErrorBox,
  Seccion,
  SkeletonTable,
  Table,
  Td,
  Tr,
  formatUsd,
} from '@/components/ui'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { consultaPorPagar, marcarPagado, mensajeDeError, sumarUsd } from '@/features/lab/admin'

import { useEscritura } from '../muestras/comun'

type Grupo = { clave: string; nombre: string; usd: number; muestras: number; ids: string[] }

/** Lo que Helios debe: la comisión de cada médico y la base de cada laboratorio. */
export function PorPagar() {
  const q = useQuery(consultaPorPagar())

  return (
    <Seccion
      titulo="Por pagar"
      info="Solo cuentan las muestras con el pago verificado y no anuladas. Aquí solo se registra: el pago se hace por fuera y se anota su referencia."
    >
      {q.isPending && <SkeletonTable rows={4} />}
      {q.isError && <ErrorBox title="No se pudo leer lo que hay por pagar" detail={mensajeDeError(q.error)} />}
      {q.data && (
        <div className="grid gap-6 xl:grid-cols-2">
          <Bloque
            titulo="Comisión de los médicos"
            columna="Médico"
            tipo="comision"
            grupos={q.data.medicos.map((m) => ({
              clave: m.merchantId,
              nombre: m.medico,
              usd: m.comisionUsd,
              muestras: m.muestras,
              ids: m.muestraIds,
            }))}
          />
          <Bloque
            titulo="Base de los laboratorios"
            columna="Laboratorio"
            tipo="base"
            grupos={q.data.laboratorios.map((l) => ({
              clave: l.laboratorioId,
              nombre: l.nombre,
              usd: l.baseUsd,
              muestras: l.muestras,
              ids: l.muestraIds,
            }))}
          />
        </div>
      )}
    </Seccion>
  )
}

function Bloque({
  titulo,
  columna,
  tipo,
  grupos,
}: {
  titulo: string
  columna: string
  tipo: 'comision' | 'base'
  grupos: Grupo[]
}) {
  const esSuper = useIsSuperAdmin()
  const [marcados, setMarcados] = useState<ReadonlySet<string>>(new Set())
  const [abierto, setAbierto] = useState(false)

  const elegidos = grupos.filter((g) => marcados.has(g.clave))
  const ids = elegidos.flatMap((g) => g.ids)
  const total = sumarUsd(elegidos.map((g) => g.usd))
  const sinIds = elegidos.some((g) => g.ids.length === 0)

  const pagar = useEscritura(
    (referencia: string) => marcarPagado({ tipo, muestraIds: ids, referencia }),
    'Marcado como pagado.',
    () => {
      setAbierto(false)
      setMarcados(new Set())
    },
  )

  function alternar(clave: string, marcada: boolean) {
    setMarcados((prev) => {
      const sig = new Set(prev)
      if (marcada) sig.add(clave)
      else sig.delete(clave)
      return sig
    })
  }

  return (
    <div className="flex min-w-0 flex-col gap-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="type-panel-label font-semibold text-on-surface">{titulo}</h3>
        <Button
          size="sm"
          disabled={!esSuper || elegidos.length === 0}
          motivoApagado={!esSuper ? SOLO_SUPER_ADMIN : undefined}
          onClick={() => setAbierto(true)}
        >
          Marcar pagado{elegidos.length > 0 ? ` (${formatUsd(total)})` : ''}
        </Button>
      </div>

      {grupos.length === 0 ? (
        <EmptyState title="Nada por pagar" />
      ) : (
        <Table headers={['', columna, 'Muestras', 'Monto']}>
          {grupos.map((g) => (
            <Tr key={g.clave}>
              <Td className="w-10">
                <Checkbox
                  id={`pp-${tipo}-${g.clave}`}
                  label={<span className="sr-only">Elegir a {g.nombre}</span>}
                  checked={marcados.has(g.clave)}
                  disabled={!esSuper}
                  onChange={(m) => alternar(g.clave, m)}
                />
              </Td>
              <Td>{g.nombre}</Td>
              <Td className="tabular-nums">{g.muestras}</Td>
              <Td className="whitespace-nowrap font-semibold tabular-nums">{formatUsd(g.usd)}</Td>
            </Tr>
          ))}
        </Table>
      )}

      {abierto && (
        <ConfirmDialog
          title="Marcar como pagado"
          summary={`Vas a marcar como pagado ${formatUsd(total)} (${elegidos.length} ${elegidos.length === 1 ? 'grupo' : 'grupos'}, ${ids.length} muestras). Anota la referencia del pago que hiciste por fuera.`}
          nivel="sensible"
          reasonLabel="Referencia del pago"
          motivoMinimo={2}
          confirmLabel="Marcar pagado"
          bloqueo={sinIds ? 'La lista no trae las muestras de este grupo; no se puede marcar desde aquí.' : undefined}
          busy={pagar.isPending}
          error={pagar.mensaje}
          onConfirm={(referencia) => pagar.mutate(referencia)}
          onClose={() => setAbierto(false)}
        />
      )}
    </div>
  )
}
