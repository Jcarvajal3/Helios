import { useState } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'

import { CamposDeAlta } from '@/components/afiliacion/CamposDeAlta'
import { OpcionesDelAlta, ResultadoDelAlta, darAccesoAlTitular } from '@/components/admin/directorio/AccesoDelTitular'
import type { DespuesDelAlta, OpcionesDeAcceso } from '@/components/admin/directorio/AccesoDelTitular'
import { VolverA } from '@/components/admin/ficha'
import { Button, ErrorBox } from '@/components/ui'
import { crearClinica } from '@/features/admin/clinicas/api'
import { ALTA_VACIA, motivoDeAlta } from '@/features/admin/clinicas/clinicas'
import type { AltaDeClinica } from '@/features/admin/clinicas/clinicas'
import { SOLO_QUIEN_AFILIA, usePuedeAfiliar } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

/**
 * Dar de alta una clínica (contrato §2.5): el médico titular, el consultorio
 * y a dónde se le paga (transferencia y/o Pago Móvil). Son los datos que manda
 * un médico desde la portada, y sigue el mismo camino que aprobar su
 * solicitud: si se deja marcado, nace con el usuario del titular
 * (administrador), su WhatsApp registrado para el bot y la bienvenida por
 * correo y por WhatsApp.
 *
 * Es una página (`/admin/clinicas/alta`) y no una ventana: se usa sobre todo
 * desde el móvil, en la visita al médico, y un formulario largo dentro de una
 * ventana no se deja llenar bien ahí. Al terminar, el resultado (la
 * contraseña, una sola vez) sale en la misma página.
 *
 * La categoría sale de la especialidad y el logo se pone luego en la ficha.
 * Lo exige el servidor a un super admin o a un capacitador
 * (`helios_assert_puede_afiliar`).
 */
export function PaginaDeAlta() {
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const puedeAfiliar = usePuedeAfiliar()

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
      // El botón queda al fondo de un formulario largo: el resultado va arriba.
      window.scrollTo({ top: 0 })
    },
  })

  const volver = <VolverA link={{ to: '/admin/clinicas' }}>Clínicas</VolverA>

  if (despues) {
    return (
      <>
        {volver}
        <h2 className="mb-4 type-panel-section text-on-surface">{alta.clinicName.trim()} ya está dada de alta</h2>
        <ResultadoDelAlta
          despues={despues}
          alta={alta}
          onIrALaFicha={() =>
            void navigate({ to: '/admin/clinicas/$id', params: { id: despues.merchantId }, search: { tab: 'personal' } })
          }
        />
      </>
    )
  }

  const bloqueo = puedeAfiliar ? (motivoDeAlta(alta) ?? undefined) : SOLO_QUIEN_AFILIA

  return (
    <>
      {volver}
      <div className="flex flex-col gap-6">
        <CamposDeAlta id="alta" valor={alta} onChange={setAlta} autoFocus />

        <OpcionesDelAlta id="alta" alta={alta} opciones={opciones} onChange={setOpciones} titulo="Al crearla" />

        {mutation.isError && <ErrorBox title="No se pudo crear la clínica" detail={describeError(mutation.error)} />}

        <div className="flex flex-col gap-3 sm:flex-row sm:items-start">
          <Button
            size="md"
            className="w-full sm:w-auto"
            disabled={!!bloqueo || mutation.isPending}
            motivoApagado={mutation.isPending ? undefined : bloqueo}
            onClick={() => mutation.mutate()}
          >
            {mutation.isPending ? 'Creando…' : 'Crear la clínica'}
          </Button>
          <Button
            variant="text"
            size="md"
            className="w-full sm:w-auto"
            onClick={() => void navigate({ to: '/admin/clinicas' })}
          >
            Cancelar
          </Button>
        </div>

        <p className="type-panel-caption text-on-surface-variant">
          La clínica nace activa y con su cuenta de pago. La categoría sale de la especialidad; el logo y la
          comisión de su personal van en su ficha.
        </p>
      </div>
    </>
  )
}
