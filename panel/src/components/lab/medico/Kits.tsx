import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { Textarea } from '@/components/kit/Textarea'
import { Badge, Button, Card, EmptyState, ErrorBox, Input, Modal, SkeletonList } from '@/components/ui'
import { explicarErrorLab, kitsLabOptions, pedirKits } from '@/features/lab/medico'
import type { KitLab } from '@/features/lab/medico'
import { ROTULO_KIT } from '@/features/lab/tipos'

export function Kits({ merchantId }: { merchantId: string }) {
  const kits = useQuery(kitsLabOptions(merchantId))
  const [pidiendo, setPidiendo] = useState<KitLab | null>(null)
  const [aviso, setAviso] = useState<string | null>(null)

  if (kits.isPending) return <SkeletonList />
  if (kits.isError) return <ErrorBox title="No se pudieron cargar los kits" detail={explicarErrorLab(kits.error)} />
  if (kits.data.length === 0) return <EmptyState title="Todavía no hay kits para pedir" />

  return (
    <div className="flex flex-col gap-4">
      {aviso && <p className="type-panel-body text-success">{aviso}</p>}
      <ul className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        {kits.data.map((k) => (
          <li key={k.kitTipo}>
            <Card className="flex h-full flex-col gap-3">
              <div className="flex items-start justify-between gap-2">
                <p className="type-panel-body font-semibold text-on-surface">{k.nombre || ROTULO_KIT[k.kitTipo]}</p>
                {k.pedidosPendientes > 0 && <Badge tone="warning">{k.pedidosPendientes} por llegar</Badge>}
              </div>
              <div>
                <p className="text-3xl font-bold tabular-nums text-on-surface">{k.enConsultorio}</p>
                <p className="type-panel-caption text-on-surface-variant">en tu consultorio</p>
              </div>
              <div className="mt-auto">
                <Button variant="tonal" size="md" onClick={() => { setAviso(null); setPidiendo(k) }}>
                  Pedir kits
                </Button>
              </div>
            </Card>
          </li>
        ))}
      </ul>
      {pidiendo && (
        <PedirKits
          merchantId={merchantId}
          kit={pidiendo}
          onClose={() => setPidiendo(null)}
          onListo={(n) => {
            setPidiendo(null)
            setAviso(`Listo. Pediste ${n} ${n === 1 ? 'kit' : 'kits'}; Helios los llevará en la próxima ruta.`)
          }}
        />
      )}
    </div>
  )
}

function PedirKits({
  merchantId,
  kit,
  onClose,
  onListo,
}: {
  merchantId: string
  kit: KitLab
  onClose: () => void
  onListo: (cantidad: number) => void
}) {
  const queryClient = useQueryClient()
  const [cantidad, setCantidad] = useState('10')
  const [nota, setNota] = useState('')
  const n = Number(cantidad)
  const valida = Number.isInteger(n) && n >= 1 && n <= 500

  const pedir = useMutation({
    mutationFn: () => pedirKits({ merchantId, kitTipo: kit.kitTipo, cantidad: n, nota }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['lab-medico', 'kits'] })
      onListo(n)
    },
  })

  return (
    <Modal title={`Pedir kits de ${ROTULO_KIT[kit.kitTipo].toLowerCase()}`} onClose={onClose} width="sm">
      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault()
          if (valida && !pedir.isPending) pedir.mutate()
        }}
      >
        <Input
          id="kits-cantidad"
          label="Cantidad"
          value={cantidad}
          onChange={setCantidad}
          inputMode="numeric"
          error={!valida}
          hint={valida ? undefined : 'Un número entero, de 1 a 500.'}
        />
        <Textarea id="kits-nota" label="Nota (opcional)" value={nota} onChange={setNota} rows={3} maxLength={300} />
        {pedir.isError && <ErrorBox title="No se pudo hacer el pedido" detail={explicarErrorLab(pedir.error)} />}
        <div className="flex flex-wrap gap-2">
          <Button type="submit" disabled={!valida || pedir.isPending}>
            {pedir.isPending ? 'Pidiendo…' : 'Pedir kits'}
          </Button>
          <Button variant="outlined" onClick={onClose}>
            Cancelar
          </Button>
        </div>
      </form>
    </Modal>
  )
}
