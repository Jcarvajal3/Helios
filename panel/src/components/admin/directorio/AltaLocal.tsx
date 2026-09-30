import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'

import { LogoPicker } from '@/components/LogoPicker'
import { useToast } from '@/components/Toast'
import { Button, Chip, DataLabel, ErrorBox, Input, Modal } from '@/components/ui'
import { CATEGORIAS_CLINICA, MERCHANT_CATEGORY_LABEL, createMerchant } from '@/features/admin/api'
import type { MerchantCategory } from '@/features/admin/api'
import {
  normalizeSocialUrl,
  validateSocialUrl,
  validateTaxId,
} from '@/features/admin/merchantProfile'
import { describeError } from '@/lib/supabase'


/**
 * Dar de alta un local. Lo exige el servidor a un super admin; el botón que
 * abre esta ventana ya se pinta apagado, con el motivo, para el operador.
 */
export function AltaLocal({ onClose }: { onClose: () => void }) {
  const avisar = useToast()
  const queryClient = useQueryClient()

  const [name, setName] = useState('')
  const [legalName, setLegalName] = useState('')
  const [taxId, setTaxId] = useState('')
  const [category, setCategory] = useState<MerchantCategory | null>(null)
  const [city, setCity] = useState('')
  const [handle, setHandle] = useState('')
  const [socialUrl, setSocialUrl] = useState('')
  const [logoUrl, setLogoUrl] = useState<string | null>(null)

  // El logo se sube antes de que el local exista, así que no puede ir en una
  // carpeta con su id. Se reserva una al abrir la ventana; sin el
  // inicializador perezoso, cada repintado dejaría huérfana la anterior.
  const [carpeta] = useState(() => crypto.randomUUID())

  const taxIdError = taxId.trim() === '' ? null : validateTaxId(taxId)
  const socialError = socialUrl.trim() === '' ? null : validateSocialUrl(socialUrl)

  const mutation = useMutation({
    mutationFn: () =>
      createMerchant({
        name,
        taxId,
        legalName: legalName || undefined,
        category: category ?? undefined,
        city: city || undefined,
        handle: handle || undefined,
        logoUrl: logoUrl || undefined,
        socialUrl: normalizeSocialUrl(socialUrl) || undefined,
      }),
    // El servidor no devuelve el id del local nuevo: se refresca la lista y
    // aparece arriba del todo, que es donde lo busca quien acaba de crearlo.
    onSuccess: () => {
      avisar(`${name} dado de alta. Todavía le falta el personal para poder cobrar`)
      void queryClient.invalidateQueries({ queryKey: ['merchants'] })
      onClose()
    },
  })

  const bloqueo =
    name.trim() === ''
      ? 'Falta el nombre comercial.'
      : taxId.trim() === ''
        ? 'Falta el RIF.'
        : (taxIdError ?? socialError ?? undefined)

  return (
    <Modal title="Dar de alta una clínica" onClose={onClose}>
      <div className="flex flex-col gap-4">
        <Input
          id="alta-nombre"
          label="Nombre comercial"
          value={name}
          onChange={setName}
          placeholder="Bar Nocturno"
          autoFocus
        />
        <Input
          id="alta-razon"
          label="Razón social (opcional)"
          value={legalName}
          onChange={setLegalName}
          placeholder="Inversiones Nocturno C.A."
        />
        <div>
          <Input id="alta-rif" label="RIF" value={taxId} onChange={setTaxId} placeholder="J-123456789" />
          {taxIdError && <p className="mt-1 type-panel-caption text-error">{taxIdError}</p>}
        </div>

        <div>
          <DataLabel className="mb-shell-gap-stack">Categoría (opcional)</DataLabel>
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
          <Input id="alta-ciudad" label="Ciudad (opcional)" value={city} onChange={setCity} placeholder="Caracas" />
          <Input
            id="alta-handle"
            label="Paciente en redes (opcional)"
            value={handle}
            onChange={setHandle}
            placeholder="BarNocturno"
          />
        </div>

        <div>
          <Input
            id="alta-social"
            label="Red social (opcional)"
            value={socialUrl}
            onChange={setSocialUrl}
            placeholder="instagram.com/barnocturno"
          />
          {socialError && <p className="mt-1 type-panel-caption text-error">{socialError}</p>}
        </div>

        <LogoPicker folder={carpeta} value={logoUrl} onChange={setLogoUrl} />

        {mutation.isError && (
          <ErrorBox title="No se pudo crear la clínica" detail={describeError(mutation.error)} />
        )}

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
          La clínica nace activo y sin personal; lo demás va en su ficha.
        </p>
      </div>
    </Modal>
  )
}
