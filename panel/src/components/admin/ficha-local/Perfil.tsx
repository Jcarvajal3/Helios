import { useState } from 'react'
import { useMutation } from '@tanstack/react-query'

import { LogoPicker } from '@/components/LogoPicker'
import { useToast } from '@/components/Toast'
import { Button, Card, Chip, ErrorBox, Input, Seccion } from '@/components/ui'
import { CATEGORIAS_CLINICA, MERCHANT_CATEGORY_LABEL, cambiosDeDatos, setMerchantProfile } from '@/features/admin/api'
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
  const [specialty, setSpecialty] = useState(datos.specialty ?? '')
  const [mpps, setMpps] = useState(datos.mppsNumber ?? '')
  const [phone, setPhone] = useState(datos.phone ?? '')
  const [email, setEmail] = useState(datos.email ?? '')
  const [address, setAddress] = useState(datos.address ?? '')

  const taxIdError = taxId.trim() === '' ? null : validateTaxId(taxId)

  const profile: MerchantProfile = {
    ...initial,
    category,
    city: city.trim() || null,
    logoUrl,
    taxId: taxId.trim() || null,
  }

  const cambios = cambiosDeDatos(datos, {
    specialty,
    mppsNumber: mpps,
    phone,
    email,
    address,
  })
  const datosCambiados = Object.values(cambios).some((v) => v !== null)
  const correoInvalido = email.trim() !== '' && !/^[^s@]+@[^s@]+.[^s@]{2,}$/.test(email.trim())

  const dirty =
    profile.category !== initial.category ||
    profile.city !== initial.city ||
    profile.logoUrl !== initial.logoUrl ||
    profile.taxId !== initial.taxId ||
    datosCambiados

  const mutation = useMutation({
    mutationFn: () => setMerchantProfile({ merchantId, profile, datos: cambios }),
    onSuccess: () => {
      avisar('Perfil de la clínica guardado')
      onDone()
    },
  })

  const bloqueo = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : !dirty
      ? 'No has cambiado nada.'
      : taxIdError || (correoInvalido ? 'El correo de la clínica no es válido.' : undefined)

  return (
    <div className="flex flex-col gap-shell-gap-block">
      <Seccion
        titulo="Datos de la clínica"
        info="Especialidad, registro del MPPS y cómo contactarla. Salen en el comprobante del paciente. Dejar un campo vacío lo borra."
      >
        <Card>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <Input id={`specialty-${merchantId}`} label="Especialidad" value={specialty} onChange={setSpecialty} placeholder="Medicina interna" />
            <Input id={`mpps-${merchantId}`} label="Número del MPPS (opcional)" value={mpps} onChange={setMpps} placeholder="12345" />
            <Input id={`phone-${merchantId}`} label="Teléfono" value={phone} onChange={setPhone} inputMode="tel" placeholder="0212 1234567" />
            <div>
              <Input id={`email-${merchantId}`} label="Correo" value={email} onChange={setEmail} placeholder="recepcion@clinica.com" />
              {correoInvalido && <p className="mt-1 type-panel-caption text-error">Ese correo no es válido.</p>}
            </div>
            <Input id={`address-${merchantId}`} label="Dirección" value={address} onChange={setAddress} placeholder="Av. Principal, Torre Médica, piso 3" className="sm:col-span-2" />
          </div>
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
              {mutation.isPending ? 'Guardando…' : 'Guardar los cambios'}
            </Button>
          </div>
        </Card>
      </Seccion>
    </div>
  )
}

