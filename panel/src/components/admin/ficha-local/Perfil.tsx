import { useState } from 'react'
import type { ReactNode } from 'react'
import { useMutation } from '@tanstack/react-query'

import { LogoPicker } from '@/components/LogoPicker'
import { useToast } from '@/components/Toast'
import { Button, Card, Chip, ErrorBox, Input, Seccion, formatPhone } from '@/components/ui'
import { CATEGORIAS_CLINICA, MERCHANT_CATEGORY_LABEL, setMerchantProfile } from '@/features/admin/api'
import type { DatosDeLaClinica, MerchantCategory, MerchantProfile } from '@/features/admin/api'
import { validateTaxId } from '@/features/admin/merchantProfile'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

/**
 * Quién es la clínica: su categoría médica, dónde está, su RIF y, si se
 * quiere, su logo (sale en su panel y en el comprobante). Guardarlo lo exige
 * el servidor a un super admin.
 *
 * Helios no tiene app: la clínica no tiene perfil público, ni usuario en
 * redes. Lo que se guarde en esas columnas heredadas de Ronda se conserva tal
 * cual, sin enseñarlo.
 */
export function Perfil({
  merchantId,
  initial,
  datos,
  onDone,
}: {
  merchantId: string
  initial: MerchantProfile
  datos: DatosDeLaClinica
  onDone: () => void
}) {
  const avisar = useToast()
  const isSuperAdmin = useIsSuperAdmin()

  const [category, setCategory] = useState<MerchantCategory | null>(initial.category)
  const [city, setCity] = useState(initial.city ?? '')
  const [logoUrl, setLogoUrl] = useState<string | null>(initial.logoUrl)
  const [taxId, setTaxId] = useState(initial.taxId ?? '')

  const taxIdError = taxId.trim() === '' ? null : validateTaxId(taxId)

  const profile: MerchantProfile = {
    ...initial,
    category,
    city: city.trim() || null,
    logoUrl,
    taxId: taxId.trim() || null,
  }

  const dirty =
    profile.category !== initial.category ||
    profile.city !== initial.city ||
    profile.logoUrl !== initial.logoUrl ||
    profile.taxId !== initial.taxId

  const mutation = useMutation({
    mutationFn: () => setMerchantProfile({ merchantId, profile }),
    onSuccess: () => {
      avisar('Perfil de la clínica guardado')
      onDone()
    },
  })

  const bloqueo = !isSuperAdmin ? SOLO_SUPER_ADMIN : !dirty ? 'No has cambiado nada.' : taxIdError || undefined

  return (
    <div className="flex flex-col gap-shell-gap-block">
      <Seccion
        titulo="Datos de la clínica"
        info="Los datos que se pusieron en el alta: especialidad, registro del MPPS y cómo contactarla. Salen en el comprobante del paciente."
      >
        <Card>
          <dl className="grid grid-cols-1 gap-x-8 gap-y-4 sm:grid-cols-2">
            <Dato rotulo="Especialidad">{datos.specialty ?? '—'}</Dato>
            <Dato rotulo="Número del MPPS">{datos.mppsNumber ?? '—'}</Dato>
            <Dato rotulo="Teléfono">{datos.phone ? formatPhone(datos.phone) : '—'}</Dato>
            <Dato rotulo="Correo">{datos.email ?? '—'}</Dato>
            <Dato rotulo="Dirección">{datos.address ?? '—'}</Dato>
          </dl>
          {/* TODO(contrato §2.5): editarlos cuando haya RPC; hoy solo se ponen en el alta. */}
          <p className="mt-4 type-panel-caption text-on-surface-variant">
            Se ponen al dar de alta la clínica. Para corregirlos, pídeselo al equipo técnico.
          </p>
        </Card>
      </Seccion>

      <Seccion
        titulo="Perfil de la clínica"
        info="Su categoría, su ciudad, su RIF y su logo (opcional): lo que se ve en el panel de la clínica y en el comprobante."
      >
        <Card className="flex flex-col gap-4">
          <div className="flex flex-col gap-2">
            <p className="type-panel-label text-on-surface-variant">Categoría</p>
            <div className="flex flex-wrap gap-2">
              {CATEGORIAS_CLINICA.map((c) => (
                <Chip key={c} selected={category === c} onClick={() => setCategory(category === c ? null : c)}>
                  {MERCHANT_CATEGORY_LABEL[c]}
                </Chip>
              ))}
            </div>
          </div>

          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <Input id={`city-${merchantId}`} label="Ciudad" value={city} onChange={setCity} placeholder="Caracas" />
            {/* El RIF se edita aquí, y no solo en el alta, por las clínicas
                heredadas que lo tienen vacío. */}
            <div>
              <Input id={`rif-${merchantId}`} label="RIF" value={taxId} onChange={setTaxId} placeholder="J-123456789" />
              {taxIdError && <p className="mt-1 type-panel-caption text-error">{taxIdError}</p>}
            </div>
          </div>

          <LogoPicker folder={merchantId} value={logoUrl} onChange={setLogoUrl} />

          {mutation.isError && <ErrorBox title="No se pudo guardar el perfil" detail={describeError(mutation.error)} />}

          <div>
            <Button
              size="md"
              variant="tonal"
              disabled={!!bloqueo || mutation.isPending}
              motivoApagado={mutation.isPending ? undefined : bloqueo}
              onClick={() => mutation.mutate()}
            >
              {mutation.isPending ? 'Guardando…' : 'Guardar el perfil'}
            </Button>
          </div>
        </Card>
      </Seccion>
    </div>
  )
}

function Dato({ rotulo, children }: { rotulo: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <dt className="type-panel-label text-on-surface-variant">{rotulo}</dt>
      <dd className="type-panel-body text-on-surface">{children}</dd>
    </div>
  )
}
