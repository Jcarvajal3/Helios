import { useState } from 'react'
import { useMutation } from '@tanstack/react-query'

import { LogoPicker } from '@/components/LogoPicker'
import { useToast } from '@/components/Toast'
import { Button, Card, Chip, ErrorBox, Input, Seccion, Select } from '@/components/ui'
import {
  CATEGORIAS_CLINICA,
  MERCHANT_CATEGORY_LABEL,
  TITULOS_DEL_MEDICO,
  cambiosDeDatos,
  setMerchantProfile,
} from '@/features/admin/api'
import type {
  DatosDeLaClinica,
  MerchantCategory,
  MerchantProfile,
  TitularDeLaClinica,
  TituloDelMedico,
} from '@/features/admin/api'
import { guardarTitular } from '@/features/admin/clinicas/api'
import { comoLoNombran, pareceCorreo } from '@/features/admin/clinicas/clinicas'
import { CampoDocumento } from '@/components/CampoDocumento'
import {
  LETRAS_CEDULA,
  LETRAS_RIF,
  documentoParaEnviar,
  documentoValido,
  rifValido,
  tieneNumero,
} from '@/lib/documento'
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
  titular,
  onDone,
}: {
  merchantId: string
  initial: MerchantProfile
  datos: DatosDeLaClinica
  titular: TitularDeLaClinica
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

  const taxIdError =
    tieneNumero(taxId, LETRAS_RIF) && !rifValido(taxId) ? 'El RIF lleva 8 o 9 números después de la letra.' : null

  const profile: MerchantProfile = {
    ...initial,
    category,
    city: city.trim() || null,
    logoUrl,
    taxId: documentoParaEnviar(taxId, LETRAS_RIF) || null,
  }

  const cambios = cambiosDeDatos(datos, {
    specialty,
    mppsNumber: mpps,
    phone,
    email,
    address,
  })
  const datosCambiados = Object.values(cambios).some((v) => v !== null)
  const correoInvalido = email.trim() !== '' && !pareceCorreo(email)

  const dirty =
    profile.category !== initial.category ||
    profile.city !== initial.city ||
    profile.logoUrl !== initial.logoUrl ||
    // La base lo guarda con guion (`J-123456789`); el campo, pegado.
    profile.taxId !== (documentoParaEnviar(initial.taxId ?? '', LETRAS_RIF) || null) ||
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
      <Titular merchantId={merchantId} titular={titular} onDone={onDone} />

      <Seccion
        titulo="Datos de la clínica"
        info="Especialidad, registro del MPPS y cómo contactarla. Salen en el comprobante del paciente. Dejar un campo vacío lo borra."
      >
        <Card>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <Input id={`specialty-${merchantId}`} label="Especialidad" value={specialty} onChange={setSpecialty} placeholder="Medicina interna" />
            <Input id={`mpps-${merchantId}`} label="Matrícula o MPPS (opcional)" value={mpps} onChange={setMpps} placeholder="12345" />
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
              <CampoDocumento id={`rif-${merchantId}`} label="RIF" value={taxId} onChange={setTaxId} letras={LETRAS_RIF} placeholder="123456789" error={!!taxIdError} />
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


/**
 * El médico titular: su nombre, su cédula o pasaporte, su número de Colegio
 * y su título (Dr., Dra., Lcdo., Lcda.), que va delante de su nombre en los
 * mensajes a sus pacientes. Se guardan aparte del perfil
 * (`admin_set_merchant_owner`). El nombre no se puede dejar vacío; el
 * Colegio y el título sí.
 */
function Titular({
  merchantId,
  titular,
  onDone,
}: {
  merchantId: string
  titular: TitularDeLaClinica
  onDone: () => void
}) {
  const avisar = useToast()
  const isSuperAdmin = useIsSuperAdmin()

  const [nombre, setNombre] = useState(titular.ownerName ?? '')
  const [documento, setDocumento] = useState(titular.ownerDocument ?? '')
  const [colegio, setColegio] = useState(titular.collegeNumber ?? '')
  const [titulo, setTitulo] = useState<TituloDelMedico | ''>(titular.doctorTitle ?? '')
  const comoLoLeen = comoLoNombran(titulo, nombre)

  /** `null` = no tocar; `''` = borrar. */
  const cambio = (antes: string | null, ahora: string) => (ahora.trim() === (antes ?? '').trim() ? null : ahora.trim())
  const cambios = {
    owner_name: cambio(titular.ownerName, nombre),
    owner_document: cambio(titular.ownerDocument, documentoParaEnviar(documento, LETRAS_CEDULA)),
    college_number: cambio(titular.collegeNumber, colegio),
    doctor_title: cambio(titular.doctorTitle, titulo),
  }
  const dirty = Object.values(cambios).some((v) => v !== null)

  const mutation = useMutation({
    mutationFn: () => guardarTitular({ merchantId, cambios }),
    onSuccess: () => {
      avisar('Titular guardado')
      onDone()
    },
  })

  const bloqueo = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : !dirty
      ? 'No has cambiado nada.'
      : nombre.trim().length < 3
        ? 'Falta el nombre completo del titular.'
        : tieneNumero(documento, LETRAS_CEDULA) && !documentoValido(documento, LETRAS_CEDULA)
          ? 'La cédula o el pasaporte no parecen válidos.'
          : undefined

  return (
    <Seccion titulo="Médico titular" info="Quién está detrás de la clínica: su nombre, su cédula o pasaporte, su número de Colegio o Federación y su título, que va delante de su nombre en los mensajes a sus pacientes.">
      <Card className="flex flex-col gap-4">
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Input id={`owner-name-${merchantId}`} label="Nombre completo" value={nombre} onChange={setNombre} placeholder="Ana María Pérez" />
          <CampoDocumento id={`owner-doc-${merchantId}`} label="Cédula o pasaporte" value={documento} onChange={setDocumento} letras={LETRAS_CEDULA} />
          <Input id={`college-${merchantId}`} label="N.º de Colegio o Federación (opcional)" value={colegio} onChange={setColegio} placeholder="12345" />
          <div>
            <Select<TituloDelMedico>
              id={`doctor-title-${merchantId}`}
              label="Título que verán sus pacientes (opcional)"
              value={titulo}
              options={TITULOS_DEL_MEDICO.map((t) => ({ value: t, label: t }))}
              onChange={setTitulo}
              placeholder="Sin título"
            />
            <span className="mt-1.5 block type-panel-caption text-panel-muted">
              Solo cambia cómo lo nombran los mensajes de WhatsApp a sus pacientes. No es un requisito para usar Helios.
              {comoLoLeen && <> Sus pacientes leerán: «{comoLoLeen}».</>}
            </span>
          </div>
        </div>

        {mutation.isError && <ErrorBox title="No se pudo guardar el titular" detail={describeError(mutation.error)} />}

        <div>
          <Button
            size="md"
            variant="tonal"
            disabled={!!bloqueo || mutation.isPending}
            motivoApagado={mutation.isPending ? undefined : bloqueo}
            onClick={() => mutation.mutate()}
          >
            {mutation.isPending ? 'Guardando…' : 'Guardar el titular'}
          </Button>
        </div>
      </Card>
    </Seccion>
  )
}
