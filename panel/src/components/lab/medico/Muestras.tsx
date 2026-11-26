import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { FlaskConical } from 'lucide-react'

import {
  Badge,
  Button,
  Card,
  ConfirmDialog,
  EmptyState,
  ErrorBox,
  Segmented,
  SkeletonList,
  formatDateTime,
  formatUsd,
} from '@/components/ui'
import { anularMuestra, explicarErrorLab, muestrasLabOptions, pasoDe } from '@/features/lab/medico'
import type { MuestraLab } from '@/features/lab/medico'
import { PASOS_MUESTRA, ROTULO_ESTADO, ROTULO_PAGO, TONO_ESTADO, TONO_PAGO } from '@/features/lab/tipos'
import type { EstadoMuestra } from '@/features/lab/tipos'

type Filtro = EstadoMuestra | 'todas'

const FILTROS: Array<{ value: Filtro; label: string }> = [
  { value: 'todas', label: 'Todas' },
  { value: 'lista_para_retirar', label: ROTULO_ESTADO.lista_para_retirar },
  { value: 'retirada', label: ROTULO_ESTADO.retirada },
  { value: 'en_laboratorio', label: ROTULO_ESTADO.en_laboratorio },
  { value: 'resultado_recibido', label: ROTULO_ESTADO.resultado_recibido },
  { value: 'resultado_entregado', label: ROTULO_ESTADO.resultado_entregado },
  { value: 'anulada', label: ROTULO_ESTADO.anulada },
]

export function Muestras({ merchantId }: { merchantId: string }) {
  const [filtro, setFiltro] = useState<Filtro>('todas')
  const [aAnular, setAAnular] = useState<MuestraLab | null>(null)
  const queryClient = useQueryClient()

  const muestras = useQuery(muestrasLabOptions(merchantId, filtro === 'todas' ? null : filtro, ''))

  const anular = useMutation({
    mutationFn: (p: { muestraId: string; motivo: string }) => anularMuestra({ merchantId, ...p }),
    onSuccess: () => {
      setAAnular(null)
      return queryClient.invalidateQueries({ queryKey: ['lab-medico', 'muestras'] })
    },
  })

  return (
    <div className="flex flex-col gap-4">
      <div className="overflow-x-auto">
        <Segmented options={FILTROS} value={filtro} onChange={setFiltro} />
      </div>

      {muestras.isPending ? (
        <SkeletonList />
      ) : muestras.isError ? (
        <ErrorBox title="No se pudieron cargar las muestras" detail={explicarErrorLab(muestras.error)} />
      ) : muestras.data.length === 0 ? (
        <EmptyState
          icon={<FlaskConical size={28} />}
          title={filtro === 'todas' ? 'Todavía no has registrado muestras' : 'No hay muestras en este estado'}
        />
      ) : (
        <ul className="flex flex-col gap-3">
          {muestras.data.map((m) => (
            <li key={m.id}>
              <Card>
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div className="min-w-0">
                    <p className="type-panel-body font-semibold text-on-surface">
                      {m.codigo} · {m.pacienteNombre}
                    </p>
                    <p className="type-panel-caption text-on-surface-variant">
                      {m.examenNombre} · {m.laboratorioNombre}
                    </p>
                    <p className="type-panel-caption text-on-surface-variant">{formatDateTime(m.creadaEn)}</p>
                  </div>
                  <p className="type-panel-body font-semibold tabular-nums text-on-surface">
                    {formatUsd(m.precioUsd)}
                  </p>
                </div>
                <div className="mt-2 flex flex-wrap items-center gap-2">
                  <Badge tone={TONO_ESTADO[m.estado]}>{ROTULO_ESTADO[m.estado]}</Badge>
                  {m.pagoEstado && <Badge tone={TONO_PAGO[m.pagoEstado]}>Pago: {ROTULO_PAGO[m.pagoEstado]}</Badge>}
                </div>
                {m.estado !== 'anulada' && <Progreso estado={m.estado} />}
                {m.estado === 'lista_para_retirar' && (
                  <div className="mt-3">
                    <Button variant="outlined" size="sm" onClick={() => setAAnular(m)}>
                      Anular
                    </Button>
                  </div>
                )}
              </Card>
            </li>
          ))}
        </ul>
      )}

      {aAnular && (
        <ConfirmDialog
          title="Anular la muestra"
          summary={`Vas a anular la muestra ${aAnular.codigo} de ${aAnular.pacienteNombre}. Solo se puede mientras nadie la haya retirado.`}
          confirmLabel="Anular muestra"
          nivel="sensible"
          reasonLabel="Motivo"
          danger
          busy={anular.isPending}
          error={anular.isError ? explicarErrorLab(anular.error) : undefined}
          onConfirm={(motivo) => anular.mutate({ muestraId: aAnular.id, motivo })}
          onClose={() => {
            setAAnular(null)
            anular.reset()
          }}
        />
      )}
    </div>
  )
}

/** El recorrido de la muestra: una barrita por paso, encendidas hasta el actual. */
function Progreso({ estado }: { estado: EstadoMuestra }) {
  const actual = pasoDe(estado)
  return (
    <div
      className="mt-3 flex gap-1"
      role="img"
      aria-label={`Paso ${actual + 1} de ${PASOS_MUESTRA.length}: ${ROTULO_ESTADO[estado]}`}
    >
      {PASOS_MUESTRA.map((p, i) => (
        <span
          key={p}
          title={ROTULO_ESTADO[p]}
          className={`h-1.5 flex-1 rounded-full ${i <= actual ? 'bg-success' : 'bg-panel-raised'}`}
        />
      ))}
    </div>
  )
}
