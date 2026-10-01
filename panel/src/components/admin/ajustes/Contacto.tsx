import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { useToast } from '@/components/Toast'
import {
  Button,
  Callout,
  Card,
  ConfirmDialog,
  ErrorBox,
  Input,
  NoSePudoLeer,
  Seccion,
  SkeletonList,
  formatDateTime,
  formatPhone,
} from '@/components/ui'
import {
  CLAVE_CONTACTO,
  CLAVE_ESTADO_CONFIGURACION,
  consultaContacto,
  guardarContacto,
} from '@/features/admin/contacto/api'
import { borradorDe, cambioDeContacto } from '@/features/admin/contacto/contacto'
import type { BorradorDeContacto, ContactoDeHelios } from '@/features/admin/contacto/contacto'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

/**
 * Contacto (plan H11, contrato §2.3): el WhatsApp de Helios, el correo y el
 * horario de soporte, y el remitente de los correos.
 *
 * Es lo que lee el paciente en el comprobante y en cada aviso
 * (`{whatsapp_helios}`), y lo que la clínica le da a quien «no está
 * disponible». Solo lo cambia un super admin y queda en la bitácora.
 */
export function Contacto() {
  const contacto = useQuery(consultaContacto())

  if (contacto.isPending) return <SkeletonList rows={4} />
  if (contacto.isError) {
    return (
      <Card>
        <NoSePudoLeer onReintentar={() => void contacto.refetch()} />
      </Card>
    )
  }
  // Se monta con los datos ya leídos: el borrador arranca de ellos.
  return <FormularioDeContacto actual={contacto.data} />
}

function FormularioDeContacto({ actual }: { actual: ContactoDeHelios }) {
  const client = useQueryClient()
  const avisar = useToast()
  const esSuperAdmin = useIsSuperAdmin()
  const [b, setB] = useState<BorradorDeContacto>(() => borradorDe(actual))
  const [confirmando, setConfirmando] = useState(false)
  const campo = (k: keyof BorradorDeContacto) => (v: string) => setB((prev) => ({ ...prev, [k]: v }))

  const cambio = cambioDeContacto(actual, b)
  const bloqueo = !esSuperAdmin ? SOLO_SUPER_ADMIN : cambio.ok ? undefined : cambio.motivo

  const guardar = useMutation({
    mutationFn: () => {
      if (!cambio.ok) throw new Error(cambio.motivo)
      return guardarContacto(cambio.payload)
    },
    onSuccess: (guardado) => {
      avisar('Contacto de Helios guardado: los mensajes nuevos ya lo usan')
      client.setQueryData(CLAVE_CONTACTO, guardado)
      void client.invalidateQueries({ queryKey: CLAVE_CONTACTO })
      void client.invalidateQueries({ queryKey: CLAVE_ESTADO_CONFIGURACION })
      void client.invalidateQueries({ queryKey: ['admin-audit'] })
      setB(borradorDe(guardado))
      setConfirmando(false)
    },
  })

  const sinWhatsApp = !actual.whatsappNumber
  const sinRemitente = !actual.senderEmail

  return (
    <div className="flex flex-col gap-shell-gap-block">
      {(sinWhatsApp || sinRemitente) && (
        <Callout tone="warning" titulo="Configuración incompleta">
          {sinWhatsApp &&
            'Sin WhatsApp, el comprobante dice «Helios te escribirá por WhatsApp» y la clínica no tiene a qué número remitir al paciente. '}
          {sinRemitente && 'Sin remitente, los comprobantes no tienen con qué nombre y dirección salir.'}
        </Callout>
      )}

      <Seccion
        titulo="Cómo contactar a Helios"
        info="Lo que lee el paciente en el comprobante y en cada aviso, y lo que la clínica le da cuando no se le puede financiar. El WhatsApp se guarda en formato internacional."
      >
        <Card className="grid grid-cols-1 gap-4 md:grid-cols-2">
          <Input
            id="contacto-whatsapp"
            label="WhatsApp de Helios"
            value={b.whatsappNumber}
            onChange={campo('whatsappNumber')}
            inputMode="tel"
            placeholder="0414 1234567"
            hint={actual.whatsappNumber ? `Ahora: ${formatPhone(actual.whatsappNumber)}` : 'Sin configurar'}
          />
          <Input
            id="contacto-correo"
            label="Correo de soporte"
            type="email"
            value={b.supportEmail}
            onChange={campo('supportEmail')}
            placeholder="soporte@helios.com"
          />
          <Input
            id="contacto-horario"
            label="Horario de atención"
            value={b.supportHours}
            onChange={campo('supportHours')}
            placeholder="Lunes a viernes, 8:00 a 18:00"
          />
        </Card>
      </Seccion>

      <Seccion
        titulo="Remitente de los correos"
        info="Con qué nombre y desde qué dirección salen el comprobante y los recordatorios. La dirección tiene que ser de un dominio verificado en Resend (SPF, DKIM y DMARC); si no, los correos caen en spam."
      >
        <Card className="grid grid-cols-1 gap-4 md:grid-cols-2">
          <Input
            id="contacto-remitente-nombre"
            label="Nombre del remitente"
            value={b.senderName}
            onChange={campo('senderName')}
            placeholder="Helios"
          />
          <Input
            id="contacto-remitente-correo"
            label="Correo del remitente"
            type="email"
            value={b.senderEmail}
            onChange={campo('senderEmail')}
            placeholder="comprobantes@helios.com"
          />
        </Card>
      </Seccion>

      <div className="flex flex-wrap items-start gap-3">
        <Button size="md" disabled={bloqueo !== undefined} motivoApagado={bloqueo} onClick={() => setConfirmando(true)}>
          Guardar el contacto
        </Button>
        {actual.updatedAt && (
          <p className="self-center type-panel-caption text-on-surface-variant">
            Cambiado el {formatDateTime(actual.updatedAt)}
            {actual.updatedByName ? ` por ${actual.updatedByName}` : ''}.
          </p>
        )}
      </div>

      {guardar.isError && !confirmando && <ErrorBox title="No se pudo guardar" detail={describeError(guardar.error)} />}

      {confirmando && cambio.ok && (
        <ConfirmDialog
          title="Cambiar el contacto de Helios"
          summary={`Cambia ${cambio.cambios.join(', ')}. Los mensajes y comprobantes nuevos lo usan desde que confirmes; los ya enviados no cambian.`}
          confirmLabel="Guardar"
          busy={guardar.isPending}
          error={guardar.isError ? describeError(guardar.error) : undefined}
          onConfirm={() => guardar.mutate()}
          onClose={() => {
            setConfirmando(false)
            guardar.reset()
          }}
        />
      )}
    </div>
  )
}
