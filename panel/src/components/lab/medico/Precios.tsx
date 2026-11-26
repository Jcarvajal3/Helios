import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { FlaskConical } from 'lucide-react'

import { Button, Card, EmptyState, ErrorBox, Input, SearchInput, SkeletonList, formatUsd } from '@/components/ui'
import { explicarErrorLab, fijarComision, preciosLabOptions } from '@/features/lab/medico'
import type { PrecioLab } from '@/features/lab/medico'
import { ROTULOS_PRECIO, ROTULO_KIT } from '@/features/lab/tipos'

type Props = {
  merchantId: string
  /** Solo el administrador edita su comisión. */
  puedeEditar: boolean
  onRegistrar: (examenId: string, laboratorioId: string) => void
}

function sinTildes(s: string): string {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
}

export function Precios({ merchantId, puedeEditar, onRegistrar }: Props) {
  const [q, setQ] = useState('')
  const precios = useQuery(preciosLabOptions(merchantId))

  if (precios.isPending) return <SkeletonList />
  if (precios.isError) return <ErrorBox title="No se pudieron cargar los precios" detail={explicarErrorLab(precios.error)} />

  const aguja = sinTildes(q.trim())
  const lista = precios.data.filter(
    (p) => !aguja || sinTildes(`${p.nombre} ${p.codigo} ${p.laboratorioNombre}`).includes(aguja),
  )

  return (
    <div className="flex flex-col gap-4">
      <SearchInput id="lab-buscar" value={q} onChange={setQ} placeholder="Buscar examen o laboratorio" />
      {lista.length === 0 ? (
        <EmptyState
          icon={<FlaskConical size={28} />}
          title={precios.data.length === 0 ? 'Todavía no hay exámenes con precio' : 'Ningún examen coincide'}
          description={
            precios.data.length === 0 ? 'Cuando Helios cargue la lista de exámenes, aparecerá aquí.' : undefined
          }
        />
      ) : (
        <ul className="flex flex-col gap-3">
          {lista.map((p) => (
            <li key={`${p.examenId}:${p.laboratorioId}`}>
              <FilaDePrecio
                precio={p}
                merchantId={merchantId}
                puedeEditar={puedeEditar}
                onRegistrar={() => onRegistrar(p.examenId, p.laboratorioId)}
              />
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

function FilaDePrecio({
  precio: p,
  merchantId,
  puedeEditar,
  onRegistrar,
}: {
  precio: PrecioLab
  merchantId: string
  puedeEditar: boolean
  onRegistrar: () => void
}) {
  return (
    <Card>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="type-panel-body font-semibold text-on-surface">{p.nombre}</p>
          <p className="type-panel-caption text-on-surface-variant">
            {p.laboratorioNombre}
            {p.kitTipo ? ` · Kit de ${ROTULO_KIT[p.kitTipo].toLowerCase()}` : ''}
          </p>
          {p.indicaciones && <p className="mt-1 type-panel-caption text-on-surface-variant">{p.indicaciones}</p>}
        </div>
        <div className="text-right">
          <p className="type-panel-caption text-on-surface-variant">{ROTULOS_PRECIO.precio}</p>
          <p className="text-3xl font-bold tabular-nums text-on-surface">{formatUsd(p.precioUsd)}</p>
        </div>
      </div>

      <dl className="mt-3 grid grid-cols-1 gap-2 sm:grid-cols-3">
        <Dato rotulo={ROTULOS_PRECIO.base} valor={formatUsd(p.baseUsd)} />
        <Dato rotulo={ROTULOS_PRECIO.cargo} valor={formatUsd(p.cargoHeliosUsd)} />
        {puedeEditar ? (
          <ComisionEditable precio={p} merchantId={merchantId} />
        ) : (
          <Dato rotulo={ROTULOS_PRECIO.comision} valor={formatUsd(p.comisionUsd)} />
        )}
      </dl>

      <div className="mt-3">
        <Button variant="tonal" size="md" onClick={onRegistrar}>
          Registrar muestra
        </Button>
      </div>
    </Card>
  )
}

function Dato({ rotulo, valor }: { rotulo: string; valor: string }) {
  return (
    <div>
      <dt className="type-panel-caption text-on-surface-variant">{rotulo}</dt>
      <dd className="type-panel-body font-semibold tabular-nums text-on-surface">{valor}</dd>
    </div>
  )
}

function ComisionEditable({ precio: p, merchantId }: { precio: PrecioLab; merchantId: string }) {
  const queryClient = useQueryClient()
  const [texto, setTexto] = useState<string | null>(null)
  const valor = texto ?? String(p.comisionUsd)
  const numero = Number(valor.replace(',', '.'))
  const valido = valor.trim() !== '' && Number.isFinite(numero) && numero >= 0 && numero <= 10_000
  const cambio = valido && Math.round(numero * 100) !== Math.round(p.comisionUsd * 100)

  const guardar = useMutation({
    mutationFn: () => fijarComision({ merchantId, examenId: p.examenId, comisionUsd: Math.round(numero * 100) / 100 }),
    onSuccess: () => {
      setTexto(null)
      return queryClient.invalidateQueries({ queryKey: ['lab-medico', 'precios'] })
    },
  })

  return (
    <div>
      <Input
        id={`comision-${p.examenId}-${p.laboratorioId}`}
        label={ROTULOS_PRECIO.comision}
        value={valor}
        onChange={setTexto}
        inputMode="decimal"
        error={!valido}
        hint={guardar.isError ? explicarErrorLab(guardar.error) : !valido ? 'Un monto en dólares, como 5 o 7,50.' : undefined}
      />
      {cambio && (
        <div className="mt-1">
          <Button size="sm" onClick={() => guardar.mutate()} disabled={guardar.isPending}>
            {guardar.isPending ? 'Guardando…' : 'Guardar'}
          </Button>
        </div>
      )}
    </div>
  )
}
