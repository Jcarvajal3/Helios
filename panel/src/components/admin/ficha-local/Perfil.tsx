import { useState } from 'react'
import { useMutation } from '@tanstack/react-query'

import { LogoPicker } from '@/components/LogoPicker'
import { useToast } from '@/components/Toast'
import { Button, Card, Chip, ErrorBox, Input, Seccion } from '@/components/ui'
import { CATEGORIAS_CLINICA, MERCHANT_CATEGORY_LABEL, setMerchantProfile } from '@/features/admin/api'
import type { MerchantCategory, MerchantProfile } from '@/features/admin/api'
import {
  normalizeSocialUrl,
  validateSocialUrl,
  validateTaxId,
} from '@/features/admin/merchantProfile'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'


/**
 * Categoría, ciudad, usuario en redes y logo: lo que usa la pantalla de Buscar
 * de la app para filtrar y pintar la tarjeta del local. Guardarlo lo exige el
 * servidor a un super admin.
 */
export function Perfil({
  merchantId,
  initial,
  onDone,
}: {
  merchantId: string
  initial: MerchantProfile
  onDone: () => void
}) {
  const avisar = useToast()
  const isSuperAdmin = useIsSuperAdmin()

  const [category, setCategory] = useState<MerchantCategory | null>(initial.category)
  const [city, setCity] = useState(initial.city ?? '')
  const [handle, setHandle] = useState(initial.handle ?? '')
  const [logoUrl, setLogoUrl] = useState<string | null>(initial.logoUrl)
  const [socialUrl, setSocialUrl] = useState(initial.socialUrl ?? '')
  const [taxId, setTaxId] = useState(initial.taxId ?? '')

  const taxIdError = taxId.trim() === '' ? null : validateTaxId(taxId)
  const socialError = validateSocialUrl(socialUrl)

  const profile: MerchantProfile = {
    category,
    city: city.trim() || null,
    handle: handle.trim() || null,
    logoUrl,
    socialUrl: normalizeSocialUrl(socialUrl) || null,
    taxId: taxId.trim() || null,
  }

  const dirty =
    profile.category !== initial.category ||
    profile.city !== initial.city ||
    profile.handle !== initial.handle ||
    profile.logoUrl !== initial.logoUrl ||
    profile.socialUrl !== initial.socialUrl ||
    profile.taxId !== initial.taxId

  const mutation = useMutation({
    mutationFn: () => setMerchantProfile({ merchantId, profile }),
    onSuccess: () => {
      avisar('Perfil de la clínica guardado')
      onDone()
    },
  })

  const bloqueo = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : !dirty
      ? 'No has cambiado nada.'
      : taxIdError || socialError || undefined

  return (
    <Seccion titulo="Perfil de la clínica" info="Su categoría, dónde está, sus redes y su logo: lo que se ve en el panel de la clínica y en el comprobante.">
      <Card className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <p className="type-panel-label text-on-surface-variant">Categoría</p>
        <div className="flex flex-wrap gap-2">
          {CATEGORIAS_CLINICA.map((c) => (
            <Chip
              key={c}
              selected={category === c}
              onClick={() => setCategory(category === c ? null : c)}
            >
              {MERCHANT_CATEGORY_LABEL[c]}
            </Chip>
          ))}
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <Input id={`city-${merchantId}`} label="Ciudad" value={city} onChange={setCity} placeholder="Caracas" />
        <Input
          id={`handle-${merchantId}`}
          label="Paciente en redes"
          value={handle}
          onChange={setHandle}
          placeholder="BarNocturno"
        />
      </div>

      <div>
        <Input
          id={`social-${merchantId}`}
          label="Red social"
          value={socialUrl}
          onChange={setSocialUrl}
          placeholder="instagram.com/barnocturno"
        />
        {socialError && <p className="mt-1 type-panel-caption text-error">{socialError}</p>}
      </div>

      {/* El RIF se edita aquí, y no solo en el alta, porque hay locales dados
          de alta antes de que fuera obligatorio que lo tienen vacío. */}
      <div>
        <Input id={`rif-${merchantId}`} label="RIF" value={taxId} onChange={setTaxId} placeholder="J-123456789" />
        {taxIdError && <p className="mt-1 type-panel-caption text-error">{taxIdError}</p>}
      </div>

      <LogoPicker folder={merchantId} value={logoUrl} onChange={setLogoUrl} />

      {mutation.isError && (
        <ErrorBox title="No se pudo guardar el perfil" detail={describeError(mutation.error)} />
      )}

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
  )
}
