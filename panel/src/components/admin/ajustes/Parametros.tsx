import { Fragment, useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { ChevronDown, ChevronRight } from 'lucide-react'

import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  ConfirmDialog,
  ErrorBox,
  InfoDot,
  Input,
  Seccion,
  SkeletonList,
  Table,
  Td,
  Tr,
  formatDateTime,
  formatDay,
} from '@/components/ui'
import { setBusinessParameter } from '@/features/admin/ajustes'
import type { Parametro } from '@/features/admin/parametros'
import {
  QUE_DECIDE,
  agruparParametros,
  formatValorParametro,
  leerValorParametro,
  nombreDelParametro,
} from '@/features/admin/parametrosPantalla'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { CLAVE_PARAMETROS, useParametros } from '@/features/admin/useParametros'
import { formatoMontoEditable } from '@/lib/montos'
import { describeError } from '@/lib/supabase'

/**
 * Los números del negocio, con fecha y con su historia.
 *
 * Cada cambio es una fila nueva con su vigencia: no se sobrescribe nada, se
 * pueden programar («sube el lunes») y queda el rastro entero. Lo que no hace
 * un cambio es reescribir el pasado: el estado automático aplica cada mañana
 * el valor vigente ese día.
 */
export function Parametros() {
  const query = useParametros()
  const isSuperAdmin = useIsSuperAdmin()
  const [editando, setEditando] = useState<Parametro | null>(null)
  const [abiertos, setAbiertos] = useState<ReadonlySet<string>>(new Set())

  if (query.isPending) return <SkeletonList rows={4} />
  if (query.isError) {
    return (
      <ErrorBox title="No se pudieron leer los parámetros" detail={describeError(query.error)} />
    )
  }

  const hoy = query.data.businessDate
  const grupos = agruparParametros(query.data.filas)

  function alternar(clave: string) {
    setAbiertos((previos) => {
      const siguientes = new Set(previos)
      if (siguientes.has(clave)) siguientes.delete(clave)
      else siguientes.add(clave)
      return siguientes
    })
  }

  return (
    <div className="flex flex-col gap-shell-gap-block">
      {grupos.map((grupo) => (
        <Seccion key={grupo.titulo} titulo={grupo.titulo} info={grupo.ayuda}>
          <Table
            headers={[
              'Parámetro',
              'Hoy',
              {
                label: 'Desde',
                info: 'Cada cambio es una fila nueva con su fecha: no se sobrescribe nada.',
              },
              {
                label: 'Programado',
                info: 'Un cambio con fecha futura. El estado automático empieza a aplicarlo ese día, no antes.',
              },
              'Historia',
              '',
            ]}
          >
            {grupo.filas.map((p) => {
              const abierto = abiertos.has(p.key)
              return (
                <Fragment key={p.key}>
                  <Tr>
                    <Td>
                      <span className="flex items-center gap-1.5">
                        <span className="font-medium text-on-surface">{nombreDelParametro(p)}</span>
                        {QUE_DECIDE[p.key] && (
                          <InfoDot title={nombreDelParametro(p)} what={QUE_DECIDE[p.key] ?? ''} />
                        )}
                      </span>
                      <span className="mt-0.5 block font-mono type-panel-caption text-on-surface-variant">
                        {p.key}
                      </span>
                    </Td>
                    <Td className="whitespace-nowrap tabular-nums font-semibold">
                      {/* Un parámetro sin valor sí es un estado: lo que lo
                          lee no tiene con qué contar. */}
                      {p.value === null ? (
                        <Badge tone="warning" icono>
                          {formatValorParametro(p.value, p.unit, p.key)}
                        </Badge>
                      ) : (
                        formatValorParametro(p.value, p.unit, p.key)
                      )}
                    </Td>
                    <Td className="whitespace-nowrap text-on-surface-variant">
                      {formatDay(p.effectiveFrom)}
                    </Td>
                    <Td className="whitespace-nowrap">
                      {p.nextValue === null ? (
                        <span className="text-on-surface-variant">—</span>
                      ) : (
                        // Un cambio programado no es una alarma: se escribe en
                        // blanco, como cualquier otro valor.
                        <span className="text-on-surface">
                          {formatValorParametro(p.nextValue, p.unit, p.key)} el {formatDay(p.nextFrom)}
                        </span>
                      )}
                    </Td>
                    <Td>
                      {p.history.length === 0 ? (
                        <span className="text-on-surface-variant">—</span>
                      ) : (
                        <button
                          type="button"
                          aria-expanded={abierto}
                          onClick={() => alternar(p.key)}
                          className="inline-flex items-center gap-1 rounded-panel-control type-panel-control text-on-surface-variant transition-colors hover:text-on-surface"
                        >
                          {abierto ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
                          {p.history.length} {p.history.length === 1 ? 'cambio' : 'cambios'}
                        </button>
                      )}
                    </Td>
                    <Td>
                      <Button
                        size="sm"
                        variant="text"
                        disabled={!isSuperAdmin}
                        motivoApagado={isSuperAdmin ? undefined : SOLO_SUPER_ADMIN}
                        onClick={() => setEditando(p)}
                      >
                        {p.value === null ? 'Fijar' : 'Cambiar'}
                      </Button>
                    </Td>
                  </Tr>
                  {abierto && (
                    <tr className="border-b border-panel-hairline last:border-0">
                      <td colSpan={6} className="bg-panel-raised px-4 py-3">
                        <HistoriaDelParametro parametro={p} />
                      </td>
                    </tr>
                  )}
                </Fragment>
              )
            })}
          </Table>
        </Seccion>
      ))}

      {editando && (
        <EditarParametro parametro={editando} hoy={hoy} onClose={() => setEditando(null)} />
      )}
    </div>
  )
}

/** Todas las versiones de un parámetro, de la más nueva a la más vieja. */
function HistoriaDelParametro({ parametro }: { parametro: Parametro }) {
  const versiones = [...parametro.history].sort((a, b) =>
    a.effectiveFrom === b.effectiveFrom
      ? b.createdAt.localeCompare(a.createdAt)
      : b.effectiveFrom.localeCompare(a.effectiveFrom),
  )
  return (
    <ol className="flex flex-col gap-1.5">
      {versiones.map((v) => (
        <li
          key={`${v.effectiveFrom}-${v.createdAt}`}
          // En el teléfono, el valor y su fecha en un renglón y la nota debajo:
          // con las dos columnas fijas a la nota le quedaban 40 px.
          className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 type-panel-body sm:grid-cols-[7rem_8rem_minmax(0,1fr)] sm:gap-3"
        >
          <span className="tabular-nums font-medium text-on-surface">
            {formatValorParametro(v.value, parametro.unit, parametro.key)}
          </span>
          <span className="whitespace-nowrap text-on-surface-variant">
            desde el {formatDay(v.effectiveFrom)}
          </span>
          <span className="text-on-surface-variant max-sm:col-span-2">
            {v.note ? `«${v.note}»` : 'Sin nota'}
            <span className="ml-2 type-panel-caption">· anotado el {formatDateTime(v.createdAt)}</span>
          </span>
        </li>
      ))}
    </ol>
  )
}

/**
 * Cambiar (o fijar por primera vez) un parámetro.
 *
 * Es `sensible`: el motivo es obligatorio y se guarda como la nota de esa
 * versión, que es lo que después se lee en la historia y en la bitácora.
 */
function EditarParametro({
  parametro,
  hoy,
  onClose,
}: {
  parametro: Parametro
  hoy: string
  onClose: () => void
}) {
  const avisar = useToast()
  const queryClient = useQueryClient()
  const nombre = nombreDelParametro(parametro)

  const [texto, setTexto] = useState(formatoMontoEditable(parametro.value))
  const [desde, setDesde] = useState(hoy)

  const lectura = leerValorParametro(texto, parametro.unit, parametro.key)

  const mutation = useMutation({
    mutationFn: (params: { valor: number; nota: string }) =>
      setBusinessParameter({
        key: parametro.key,
        value: params.valor,
        effectiveFrom: desde || undefined,
        note: params.nota,
      }),
    onSuccess: (_data, params) => {
      // Con la fecha: un parámetro se puede programar, y «guardado» sin el
      // desde no distingue lo que ya rige de lo que regirá el lunes.
      avisar(
        `${nombre}: ${formatValorParametro(params.valor, parametro.unit, parametro.key)} desde el ${formatDay(desde || hoy)}.`,
      )
      void queryClient.invalidateQueries({ queryKey: CLAVE_PARAMETROS })
      onClose()
    },
  })

  const bloqueo = !lectura.ok
    ? lectura.motivo
    : desde === ''
      ? 'Elige desde qué día rige.'
      : desde < hoy
        ? 'Un parámetro no puede entrar en vigor en el pasado.'
        : lectura.valor === parametro.value && desde === parametro.effectiveFrom
          ? 'El valor nuevo es igual al vigente.'
          : undefined

  return (
    <ConfirmDialog
      nivel="sensible"
      title={parametro.value === null ? `Fijar ${nombre.toLowerCase()}` : nombre}
      summary={QUE_DECIDE[parametro.key] ?? 'Un parámetro del negocio.'}
      detail={
        <div className="flex flex-col gap-3">
          <Input
            id="param-valor"
            label={`Valor${parametro.unit ? ` (${parametro.unit})` : ''}`}
            value={texto}
            onChange={setTexto}
            inputMode="decimal"
            error={texto.trim() !== '' && !lectura.ok}
            hint={
              parametro.value === null
                ? 'Todavía no tiene valor.'
                : `Ahora vale ${formatValorParametro(parametro.value, parametro.unit, parametro.key)} desde el ${formatDay(parametro.effectiveFrom)}.`
            }
            autoFocus
          />
          <Input
            id="param-desde"
            label="Desde (día operativo)"
            type="date"
            value={desde}
            min={hoy}
            onChange={setDesde}
            hint="No reescribe el pasado: cada mañana se aplica el valor vigente ese día."
          />
        </div>
      }
      reasonLabel="Motivo (queda como nota de esta versión)"
      reasonPlaceholder="Acuerdo con las clínicas del piloto"
      bloqueo={bloqueo}
      confirmLabel="Guardar"
      busy={mutation.isPending}
      error={mutation.isError ? describeError(mutation.error) : undefined}
      onConfirm={(nota) => {
        if (lectura.ok) mutation.mutate({ valor: lectura.valor, nota })
      }}
      onClose={onClose}
    />
  )
}
