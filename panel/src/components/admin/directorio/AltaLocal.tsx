import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'

import { CamposDeAlta } from '@/components/afiliacion/CamposDeAlta'
import { OpcionesDelAlta, YaDadaDeAlta, darAccesoAlTitular } from '@/components/admin/directorio/AccesoDelTitular'
import type { DespuesDelAlta, OpcionesDeAcceso } from '@/components/admin/directorio/AccesoDelTitular'
import { Button, ErrorBox, Modal } from '@/components/ui'
import { crearClinica } from '@/features/admin/clinicas/api'
import { ALTA_VACIA, motivoDeAlta } from '@/features/admin/clinicas/clinicas'
import type { AltaDeClinica } from '@/features/admin/clinicas/clinicas'
import { describeError } from '@/lib/supabase'

/**
 * Dar de alta una clínica (contrato §2.5): el médico titular, el consultorio
 * y a dónde se le paga (transferencia y/o Pago Móvil). Son los datos que manda
 * un médico desde la portada, y sigue el mismo camino que aprobar su
 * solicitud: si se deja marcado, nace con el usuario del titular
 * (administrador), su WhatsApp registrado para el bot y la bienvenida por
 * correo y por WhatsApp. Al terminar, la ficha abre en Personal.
 *
 * La categoría sale de la especialidad y el logo se pone luego en la ficha.
 * Lo exige el servidor a un super admin; el botón que abre esta ventana ya se
 * pinta apagado, con el motivo, para el operador.
 */
export function AltaLocal({ onClose }: { onClose: () => void }) {
  const queryClient = useQueryClient()

  const [alta, setAlta] = useState<AltaDeClinica>(ALTA_VACIA)
  const [opciones, setOpciones] = useState<OpcionesDeAcceso>({ crearUsuario: true, darBot: true })
  const [despues, setDespues] = useState<DespuesDelAlta | null>(null)

  const mutation = useMutation({
    mutationFn: async () => {
      const merchantId = await crearClinica(alta)
      return darAccesoAlTitular(merchantId, alta, opciones)
    },
    onSuccess: (resultado) => {
      void queryClient.invalidateQueries({ queryKey: ['merchants'] })
      setDespues(resultado)
    },
  })

  if (despues) return <YaDadaDeAlta despues={despues} alta={alta} onClose={onClose} />

  const bloqueo = motivoDeAlta(alta) ?? undefined

  return (
    <Modal title="Dar de alta una clínica" width="lg" onClose={onClose}>
      <div className="flex flex-col gap-6">
        <CamposDeAlta id="alta" valor={alta} onChange={setAlta} autoFocus />

        <OpcionesDelAlta id="alta" alta={alta} opciones={opciones} onChange={setOpciones} titulo="Al crearla" />

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
          La clínica nace activa y con su cuenta de pago. La categoría sale de la especialidad; el logo y la
          comisión de su personal van en su ficha.
        </p>
      </div>
    </Modal>
  )
}
