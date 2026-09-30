import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'

import { LogoPicker } from '@/components/LogoPicker'
import { useToast } from '@/components/Toast'
import { Button, Chip, DataLabel, ErrorBox, Input, Modal } from '@/components/ui'
import { CATEGORIAS_CLINICA, MERCHANT_CATEGORY_LABEL, createMerchant } from '@/features/admin/api'
import { motivoDeAlta, telefonoAE164 } from '@/features/admin/clinicas/clinicas'
import type { AltaDeClinica } from '@/features/admin/clinicas/clinicas'
import { validateTaxId } from '@/features/admin/merchantProfile'
import { describeError } from '@/lib/supabase'

const VACIA: AltaDeClinica = {
  name: '',
  legalName: '',
  taxId: '',
  category: '',
  specialty: '',
  mppsNumber: '',
  phone: '',
  email: '',
  address: '',
  city: '',
}

/**
 * Dar de alta una clínica (contrato §2.5): su nombre, RIF y categoría médica,
 * la especialidad, el número del MPPS si es un médico independiente, y cómo
 * contactarla. Lo exige el servidor a un super admin; el botón que abre esta
 * ventana ya se pinta apagado, con el motivo, para el operador.
 */
export function AltaLocal({ onClose }: { onClose: () => void }) {
  const avisar = useToast()
  const queryClient = useQueryClient()

  const [alta, setAlta] = useState<AltaDeClinica>(VACIA)
  const [logoUrl, setLogoUrl] = useState<string | null>(null)
  const campo = (k: keyof AltaDeClinica) => (v: string) => setAlta((prev) => ({ ...prev, [k]: v }))

  // El logo se sube antes de que la clínica exista, así que no puede ir en
  // una carpeta con su id. Se reserva una al abrir la ventana; sin el
  // inicializador perezoso, cada repintado dejaría huérfana la anterior.
  const [carpeta] = useState(() => crypto.randomUUID())

  const taxIdError = alta.taxId.trim() === '' ? null : validateTaxId(alta.taxId)
  const opcional = (v: string) => v.trim() || undefined

  const mutation = useMutation({
    mutationFn: () =>
      createMerchant({
        name: alta.name.trim(),
        taxId: alta.taxId,
        legalName: opcional(alta.legalName),
        category: CATEGORIAS_CLINICA.find((c) => c === alta.category),
        city: opcional(alta.city),
        logoUrl: logoUrl || undefined,
        specialty: opcional(alta.specialty),
        mppsNumber: opcional(alta.mppsNumber),
        phone: alta.phone.trim() ? (telefonoAE164(alta.phone) ?? undefined) : undefined,
        email: opcional(alta.email)?.toLowerCase(),
        address: opcional(alta.address),
      }),
    // El servidor no devuelve el id de la clínica nueva: se refresca la lista
    // y aparece arriba del todo, que es donde la busca quien acaba de crearla.
    onSuccess: () => {
      avisar(`${alta.name} dada de alta. Le falta el personal y la cuenta de pago`)
      void queryClient.invalidateQueries({ queryKey: ['merchants'] })
      onClose()
    },
  })

  const bloqueo = motivoDeAlta(alta) ?? undefined

  return (
    <Modal title="Dar de alta una clínica" width="lg" onClose={onClose}>
      <div className="flex flex-col gap-4">
        <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
          <Input
            id="alta-nombre"
            label="Nombre"
            value={alta.name}
            onChange={campo('name')}
            placeholder="Consultorio Pediátrico Los Palos Grandes"
            autoFocus
          />
          <Input
            id="alta-razon"
            label="Razón social (opcional)"
            value={alta.legalName}
            onChange={campo('legalName')}
            placeholder="Servicios Médicos Demo C.A."
          />
          <div>
            <Input id="alta-rif" label="RIF" value={alta.taxId} onChange={campo('taxId')} placeholder="J-123456789" />
            {taxIdError && <p className="mt-1 type-panel-caption text-error">{taxIdError}</p>}
          </div>
          <Input
            id="alta-mpps"
            label="Número del MPPS (opcional)"
            value={alta.mppsNumber}
            onChange={campo('mppsNumber')}
            inputMode="numeric"
            placeholder="Si es un médico independiente"
          />
        </div>

        <div>
          <DataLabel className="mb-shell-gap-stack">Categoría</DataLabel>
          <div className="flex flex-wrap gap-2">
            {CATEGORIAS_CLINICA.map((c) => (
              <Chip
                key={c}
                selected={alta.category === c}
                onClick={() => setAlta((prev) => ({ ...prev, category: prev.category === c ? '' : c }))}
              >
                {MERCHANT_CATEGORY_LABEL[c]}
              </Chip>
            ))}
          </div>
        </div>

        <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
          <Input
            id="alta-especialidad"
            label="Especialidad (opcional)"
            value={alta.specialty}
            onChange={campo('specialty')}
            placeholder="Pediatría"
          />
          <Input id="alta-ciudad" label="Ciudad (opcional)" value={alta.city} onChange={campo('city')} placeholder="Caracas" />
          <Input
            id="alta-telefono"
            label="Teléfono (opcional)"
            value={alta.phone}
            onChange={campo('phone')}
            inputMode="tel"
            placeholder="0212 5551234"
          />
          <Input
            id="alta-correo"
            label="Correo (opcional)"
            type="email"
            value={alta.email}
            onChange={campo('email')}
            placeholder="recepcion@clinica.com"
          />
        </div>
        <Input
          id="alta-direccion"
          label="Dirección (opcional)"
          value={alta.address}
          onChange={campo('address')}
          placeholder="Av. Francisco de Miranda, Torre Médica, piso 3"
        />

        <LogoPicker folder={carpeta} value={logoUrl} onChange={setLogoUrl} />

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
          La clínica nace activa y sin personal; la cuenta de pago y las condiciones van en su ficha.
        </p>
      </div>
    </Modal>
  )
}
