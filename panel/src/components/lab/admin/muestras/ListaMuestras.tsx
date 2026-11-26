import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { FlaskConical } from 'lucide-react'

import {
  EmptyState,
  ErrorBox,
  FilterBar,
  Filtro,
  Periodo,
  SearchInput,
  Select,
  SkeletonTable,
  Table,
  Td,
  Tr,
  formatDateTime,
  formatUsd,
  hoyCaracas,
} from '@/components/ui'
import { POR_PAGINA, consultaMedicos, consultaMuestras, mensajeDeError } from '@/features/lab/admin'
import type { FiltroMuestras } from '@/features/lab/admin'
import { ROTULO_ESTADO, ROTULO_PAGO } from '@/features/lab/tipos'
import type { EstadoMuestra, EstadoPago } from '@/features/lab/tipos'

import { InsigniaEstado, InsigniaPago, Paginacion } from './comun'

const OPCIONES_ESTADO = (Object.keys(ROTULO_ESTADO) as EstadoMuestra[]).map((e) => ({
  value: e,
  label: ROTULO_ESTADO[e],
}))
const OPCIONES_PAGO = (Object.keys(ROTULO_PAGO) as EstadoPago[]).map((e) => ({
  value: e,
  label: ROTULO_PAGO[e],
}))

const CABECERAS = ['Código', 'Fecha', 'Médico', 'Paciente', 'Examen', 'Laboratorio', 'Precio', 'Estado', 'Pago']

export function ListaMuestras({
  filtros,
  onCambiar,
  onAbrir,
}: {
  filtros: FiltroMuestras
  onCambiar: (patch: Partial<FiltroMuestras>, reemplazar?: boolean) => void
  onAbrir: (id: string) => void
}) {
  const { estado, pago, medico, desde, hasta, q, pagina } = filtros
  const consulta = useQuery(consultaMuestras({ estado, pago, medico, desde, hasta, q, pagina, porPagina: POR_PAGINA }))
  const medicos = useQuery(consultaMedicos())

  // El buscador escribe en la URL con un respiro, no a cada tecla.
  const [texto, setTexto] = useState(filtros.q ?? '')
  useEffect(() => setTexto(filtros.q ?? ''), [filtros.q])
  useEffect(() => {
    const t = texto.trim()
    if (t === (filtros.q ?? '')) return
    const espera = setTimeout(() => onCambiar({ q: t || undefined, pagina: undefined }, true), 350)
    return () => clearTimeout(espera)
  }, [texto, filtros.q, onCambiar])

  const rango = filtros.desde && filtros.hasta ? { from: filtros.desde, to: filtros.hasta } : null
  const filas = consulta.data ?? []
  const total = filas[0]?.total ?? 0

  return (
    <>
      <FilterBar>
        <SearchInput
          id="lab-q"
          label="Buscar"
          value={texto}
          onChange={setTexto}
          placeholder="Código, paciente o referencia"
          className="w-72"
        />
        <Select<EstadoMuestra | ''>
          id="lab-estado"
          label="Estado"
          value={filtros.estado ?? ''}
          options={[{ value: '', label: 'Todos' }, ...OPCIONES_ESTADO]}
          onChange={(v) => onCambiar({ estado: v || undefined, pagina: undefined })}
          className="w-52"
        />
        <Select<EstadoPago | ''>
          id="lab-pago"
          label="Pago"
          value={filtros.pago ?? ''}
          options={[{ value: '', label: 'Todos' }, ...OPCIONES_PAGO]}
          onChange={(v) => onCambiar({ pago: v || undefined, pagina: undefined })}
          className="w-52"
        />
        <Select
          id="lab-medico"
          label="Médico"
          value={filtros.medico ?? ''}
          options={[{ value: '', label: 'Todos' }, ...(medicos.data ?? []).map((m) => ({ value: m.id, label: m.nombre }))]}
          onChange={(v) => onCambiar({ medico: v || undefined, pagina: undefined })}
          className="w-56"
        />
        <Filtro label="Fechas">
          <Periodo
            rango={rango}
            hoy={hoyCaracas()}
            onChange={(r) => onCambiar({ desde: r.from, hasta: r.to, pagina: undefined })}
            onQuitar={() => onCambiar({ desde: undefined, hasta: undefined, pagina: undefined })}
          />
        </Filtro>
      </FilterBar>

      {consulta.isPending && <SkeletonTable rows={8} />}
      {consulta.isError && <ErrorBox title="No se pudieron leer las muestras" detail={mensajeDeError(consulta.error)} />}
      {consulta.data && filas.length === 0 && (
        <EmptyState
          icon={<FlaskConical size={28} aria-hidden />}
          title="Ninguna muestra con esos filtros"
          description="Cambia o quita algún filtro para ver más."
        />
      )}
      {filas.length > 0 && (
        <>
          <Table headers={CABECERAS}>
            {filas.map((m) => (
              <Tr key={m.id} onClick={() => onAbrir(m.id)}>
                <Td className="font-semibold">{m.codigo}</Td>
                <Td className="whitespace-nowrap">{formatDateTime(m.creada)}</Td>
                <Td>{m.medico}</Td>
                <Td>{m.paciente}</Td>
                <Td>{m.examen}</Td>
                <Td>{m.laboratorio}</Td>
                <Td className="whitespace-nowrap tabular-nums">{formatUsd(m.precioUsd)}</Td>
                <Td>
                  <InsigniaEstado estado={m.estado} />
                </Td>
                <Td>
                  <InsigniaPago pago={m.pagoEstado} />
                </Td>
              </Tr>
            ))}
          </Table>
          <Paginacion
            pagina={filtros.pagina ?? 1}
            total={total}
            porPagina={POR_PAGINA}
            onPagina={(p) => onCambiar({ pagina: p <= 1 ? undefined : p })}
          />
        </>
      )}
    </>
  )
}
