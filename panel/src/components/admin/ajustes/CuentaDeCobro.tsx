import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Callout,
  Card,
  ConfirmDialog,
  ErrorBox,
  Input,
  Seccion,
  SkeletonTable,
  Table,
  Td,
  Tr,
  formatDateTime,
} from '@/components/ui'
import { enumerar, esCuentaDeRelleno } from '@/features/admin/ajustesReglas'
import { fetchPaymentDestinations, setPaymentDestination } from '@/features/admin/ops'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

type DatosDeCuenta = {
  bankName: string
  rif: string
  phone: string
  holderName: string | null
}

/** Una cuenta en cuatro líneas, para ponerla al lado de la otra. */
function FichaDeCuenta({ titulo, cuenta }: { titulo: string; cuenta: DatosDeCuenta | null }) {
  return (
    <div className="flex flex-col gap-0.5">
      <p className="type-panel-label text-on-surface-variant">{titulo}</p>
      {cuenta ? (
        <>
          <p className="type-panel-body font-semibold text-on-surface">{cuenta.bankName}</p>
          <p className="font-mono type-panel-caption text-on-surface">{cuenta.rif}</p>
          <p className="font-mono type-panel-caption text-on-surface">{cuenta.phone}</p>
          <p className="type-panel-caption text-on-surface-variant">
            {cuenta.holderName ?? 'Sin titular'}
          </p>
        </>
      ) : (
        <p className="type-panel-body text-error">Ninguna</p>
      )}
    </div>
  )
}

/**
 * La cuenta de Pago Móvil a la que transfieren todos los usuarios.
 *
 * Solo hay una activa: activar otra retira la anterior en la misma
 * transacción. Por eso activar pasa por el diálogo crítico con las dos cuentas
 * a la vista.
 */
export function CuentaDeCobro() {
  const avisar = useToast()
  const client = useQueryClient()
  const isSuperAdmin = useIsSuperAdmin()
  const query = useQuery({
    queryKey: ['payment-destinations'],
    queryFn: fetchPaymentDestinations,
  })

  const [bank, setBank] = useState('')
  const [rif, setRif] = useState('')
  const [phone, setPhone] = useState('')
  const [holder, setHolder] = useState('')
  const [revisando, setRevisando] = useState(false)

  const activa = query.data?.find((d) => d.isActive) ?? null
  const sinCuenta = query.data ? !activa || esCuentaDeRelleno(activa.rif) : false

  const nueva: DatosDeCuenta = {
    bankName: bank.trim(),
    rif: rif.trim(),
    phone: phone.trim(),
    holderName: holder.trim() || null,
  }

  const mutation = useMutation({
    // El motivo del diálogo va a la bitácora con el cambio.
    mutationFn: (nota: string) =>
      setPaymentDestination({
        bankName: nueva.bankName,
        rif: nueva.rif,
        phone: nueva.phone,
        holderName: nueva.holderName ?? undefined,
        note: nota,
      }),
    onSuccess: () => {
      avisar(`La cuenta de cobro es ahora la de ${nueva.bankName}. Las plantillas ya la usan.`)
      setBank('')
      setRif('')
      setPhone('')
      setHolder('')
      setRevisando(false)
      void client.invalidateQueries({ queryKey: ['payment-destinations'] })
    },
  })

  const faltan = [
    !nueva.bankName && 'el banco',
    !nueva.rif && 'la cédula o el RIF',
    !nueva.phone && 'el teléfono',
  ].filter((f): f is string => typeof f === 'string')

  const motivoApagado = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : faltan.length > 0
      ? `${faltan.length === 1 ? 'Falta' : 'Faltan'} ${enumerar(faltan)}.`
      : esCuentaDeRelleno(nueva.rif)
        ? 'Un RIF de ceros no es una cuenta.'
        : undefined

  return (
    <div className="flex flex-col gap-shell-gap-block">
      {sinCuenta && (
        <Callout
          tone="error"
          titulo={activa ? 'La cuenta activa es la de relleno' : 'No hay ninguna cuenta activa'}
        >
          Nadie sabrá a dónde transferir: da de alta la cuenta de Helios aquí abajo.
        </Callout>
      )}

      <Seccion
        titulo="Nueva cuenta de Pago Móvil"
        info="La cuenta a la que transfieren todos los pacientes. Solo hay una activa: activar otra retira la anterior en la misma operación, y los mensajes la enseñan desde ese momento."
      >
        <Card>
          {/* Escrito y no en el tooltip: el cambio llega a todos a la vez y un
              dígito mal puesto manda las transferencias a otra cuenta. */}
          <p className="type-panel-body text-on-surface-variant">
            Al activarla, todos los pacientes transferirán a esta cuenta.
          </p>
          <div className="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2">
            <Input id="dest-bank" label="Banco" value={bank} onChange={setBank} placeholder="Banesco" />
            <Input
              id="dest-rif"
              label="Cédula o RIF"
              value={rif}
              onChange={setRif}
              placeholder="J-123456789"
            />
            <Input
              id="dest-phone"
              label="Teléfono"
              value={phone}
              onChange={setPhone}
              inputMode="tel"
              placeholder="0414 1234567"
            />
            <Input
              id="dest-holder"
              label="Titular (opcional)"
              value={holder}
              onChange={setHolder}
              placeholder="Helios C.A."
            />
          </div>
  
          <Button
            className="mt-4"
            size="md"
            disabled={motivoApagado !== undefined}
            motivoApagado={motivoApagado}
            onClick={() => setRevisando(true)}
          >
            Revisar y activar esta cuenta
          </Button>
        </Card>
      </Seccion>

      {query.isLoading && <SkeletonTable rows={4} columns={7} />}
      {query.isError && (
        <ErrorBox title="No se pudieron leer las cuentas de cobro" detail={describeError(query.error)} />
      )}

      {query.data && query.data.length > 0 && (
        <Seccion
          titulo="Historial de cuentas"
          info="Las retiradas se conservan: un pago se coteja contra la cuenta que estaba activa ese día."
        >
          <Table headers={['Banco', 'RIF', 'Teléfono', 'Titular', 'Pagos recibidos', 'Estado', 'Alta']}>
            {query.data.map((d) => (
              <Tr key={d.id}>
                <Td className="font-medium">{d.bankName}</Td>
                <Td className="font-mono type-panel-caption">{d.rif}</Td>
                <Td className="font-mono type-panel-caption">{d.phone}</Td>
                <Td className="text-on-surface-variant">{d.holderName ?? '—'}</Td>
                <Td className="tabular-nums text-on-surface-variant">{d.reportCount}</Td>
                <Td>
                  {d.isActive ? (
                    <Badge tone="success" icono>
                      Activa
                    </Badge>
                  ) : (
                    <Badge>Retirada</Badge>
                  )}
                </Td>
                <Td className="whitespace-nowrap type-panel-caption text-on-surface-variant">
                  {formatDateTime(d.createdAt)}
                </Td>
              </Tr>
            ))}
          </Table>
        </Seccion>
      )}

      {revisando && (
        <ConfirmDialog
          nivel="critico"
          title="Cambiar la cuenta de cobro"
          summary="Desde que confirmes, los mensajes enseñan esta cuenta a todos los pacientes para transferir, y la actual deja de mostrarse."
          detail={
            <div className="grid grid-cols-2 gap-4">
              <FichaDeCuenta titulo="Cuenta actual" cuenta={activa} />
              <FichaDeCuenta titulo="Cuenta nueva" cuenta={nueva} />
            </div>
          }
          reasonPlaceholder="Cambio de banco de Helios"
          confirmLabel="Activar la cuenta nueva"
          busy={mutation.isPending}
          error={mutation.isError ? describeError(mutation.error) : undefined}
          onConfirm={(nota) => mutation.mutate(nota)}
          onClose={() => setRevisando(false)}
        />
      )}
    </div>
  )
}
