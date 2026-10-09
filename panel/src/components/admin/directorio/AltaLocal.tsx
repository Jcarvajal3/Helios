import { useState } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'

import { CamposDeAlta } from '@/components/afiliacion/CamposDeAlta'
import { useToast } from '@/components/Toast'
import { Button, ErrorBox, Modal } from '@/components/ui'
import { crearClinica } from '@/features/admin/clinicas/api'
import { ALTA_VACIA, motivoDeAlta } from '@/features/admin/clinicas/clinicas'
import type { AltaDeClinica } from '@/features/admin/clinicas/clinicas'
import { describeError } from '@/lib/supabase'

/**
 * Dar de alta una clínica (contrato §2.5): el médico titular, el consultorio
 * y a dónde se le paga (transferencia y/o Pago Móvil). Son los datos que manda un médico
 * desde la portada. La categoría sale de la especialidad y el logo se pone
 * luego en la ficha. Lo exige el servidor a un super admin; el botón que abre
 * esta ventana ya se pinta apagado, con el motivo, para el operador.
 */
export function AltaLocal({ onClose }: { onClose: () => void }) {
  const avisar = useToast()
  const queryClient = useQueryClient()
  const navigate = useNavigate()

  const [alta, setAlta] = useState<AltaDeClinica>(ALTA_VACIA)

  const mutation = useMutation({
    mutationFn: () => crearClinica(alta),
    onSuccess: (merchantId) => {
      avisar(`${alta.clinicName.trim()} dada de alta. Le falta el personal`)
      void queryClient.invalidateQueries({ queryKey: ['merchants'] })
      onClose()
      void navigate({ to: '/admin/clinicas/$id', params: { id: merchantId } })
    },
  })

  const bloqueo = motivoDeAlta(alta) ?? undefined

  return (
    <Modal title="Dar de alta una clínica" width="lg" onClose={onClose}>
      <div className="flex flex-col gap-6">
        <CamposDeAlta id="alta" valor={alta} onChange={setAlta} autoFocus />

        {mutation.isError && <ErrorBox title="No se pudo crear la clínica" detail={describeError(mutation.error)} />}

        <div className="flex items-start gap-3">
          <Button
            size="md"
            disabled={!!bloqueo || mutation.isPending}
            motivoApagado={mutation.isPending ? undefined : bloqueo}
            onClick={() => mutation.mutate()}
          >
            {mutation.isPending ? 'Creando…' : 'Crear la clínica'}
          </Button>
          <Button variant="text" size="md" onClick={onClose}>
            Cancelar
          </Button>
        </div>

        <p className="type-panel-caption text-on-surface-variant">
          La clínica nace activa, con su cuenta de pago y sin personal. La categoría sale de la especialidad; el logo y
          las condiciones van en su ficha.
        </p>
      </div>
    </Modal>
  )
}
