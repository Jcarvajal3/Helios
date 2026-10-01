import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowDown, ArrowUp } from 'lucide-react'

import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Callout,
  Card,
  ConfirmDialog,
  ErrorBox,
  IconButton,
  Input,
  Seccion,
  SkeletonTable,
  Table,
  Td,
  Tr,
  formatDateTime,
} from '@/components/ui'
import { enumerar, esCuentaDeRelleno } from '@/features/admin/ajustesReglas'
import { CLAVE_ESTADO_CONFIGURACION } from '@/features/admin/contacto/api'
import { moverCuenta, ordenarCuentas, siguienteOrden } from '@/features/admin/contacto/contacto'
import { fetchPaymentDestinations, setPaymentDestination } from '@/features/admin/ops'
import type { PaymentDestination } from '@/features/admin/ops'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

/** Lo que se decide en el diálogo: dar de alta, activar o retirar una cuenta. */
type Decision =
  | { tipo: 'alta' }
  | { tipo: 'activar'; cuenta: PaymentDestination }
  | { tipo: 'retirar'; cuenta: PaymentDestination }

/**
 * Las cuentas a las que transfieren los pacientes (plan H11).
 *
 * En Helios puede haber **varias activas** a la vez —Pago Móvil,
 * transferencia, Zelle…—, cada una con su orden: los mensajes y el
 * comprobante las listan todas, en ese orden. Dar de alta una nueva ya no
 * retira las demás. Todo lo exige el servidor a un super admin y pide motivo.
 *
 * La cuenta se reconoce por banco + RIF + teléfono (`admin_set_payment_destination`
 * con `p_sort_order` y `p_is_active`, contrato §2.3).
 */
export function CuentaDeCobro() {
  const avisar = useToast()
  const client = useQueryClient()
  const isSuperAdmin = useIsSuperAdmin()
  const query = useQuery({ queryKey: ['payment-destinations'], queryFn: fetchPaymentDestinations })

  const [bank, setBank] = useState('')
  const [rif, setRif] = useState('')
  const [phone, setPhone] = useState('')
  const [holder, setHolder] = useState('')
  const [decision, setDecision] = useState<Decision | null>(null)

  const cuentas = ordenarCuentas(query.data ?? [])
  const activas = cuentas.filter((c) => c.isActive && !esCuentaDeRelleno(c.rif))

  function refrescar() {
    void client.invalidateQueries({ queryKey: ['payment-destinations'] })
    void client.invalidateQueries({ queryKey: CLAVE_ESTADO_CONFIGURACION })
  }

  const guardar = useMutation({
    mutationFn: async ({ d, nota }: { d: Decision; nota: string }) => {
      if (d.tipo === 'alta') {
        return setPaymentDestination({
          bankName: bank.trim(),
          rif: rif.trim(),
          phone: phone.trim(),
          holderName: holder.trim() || undefined,
          note: nota,
          sortOrder: siguienteOrden(query.data ?? []),
          isActive: true,
        })
      }
      return setPaymentDestination({
        bankName: d.cuenta.bankName,
        rif: d.cuenta.rif,
        phone: d.cuenta.phone,
        holderName: d.cuenta.holderName ?? undefined,
        note: nota,
        sortOrder: d.tipo === 'activar' ? siguienteOrden(query.data ?? []) : d.cuenta.sortOrder,
        isActive: d.tipo === 'activar',
      })
    },
    onSuccess: (_, { d }) => {
      if (d.tipo === 'alta') {
        avisar(`Cuenta de ${bank.trim()} activa. Los mensajes nuevos ya la enseñan.`)
        setBank('')
        setRif('')
        setPhone('')
        setHolder('')
      } else {
        avisar(d.tipo === 'activar' ? `Cuenta de ${d.cuenta.bankName} activa` : `Cuenta de ${d.cuenta.bankName} retirada`)
      }
      setDecision(null)
      refrescar()
    },
  })

  // Subir o bajar: dos escrituras, una por cuenta. El orden no pide motivo.
  const mover = useMutation({
    mutationFn: async ({ id, sentido }: { id: string; sentido: -1 | 1 }) => {
      const cambios = moverCuenta(query.data ?? [], id, sentido)
      if (!cambios) return
      for (const { cuenta, sortOrder } of cambios) {
        await setPaymentDestination({
          bankName: cuenta.bankName,
          rif: cuenta.rif,
          phone: cuenta.phone,
          holderName: cuenta.holderName ?? undefined,
          note: 'Cambio de orden',
          sortOrder,
          isActive: true,
        })
      }
    },
    onSettled: refrescar,
  })

  const faltan = [
    !bank.trim() && 'el banco',
    !rif.trim() && 'la cédula o el RIF',
    !phone.trim() && 'el teléfono o el número de cuenta',
  ].filter((f): f is string => typeof f === 'string')
  const repetida = cuentas.some(
    (c) =>
      c.bankName.trim().toLowerCase() === bank.trim().toLowerCase() &&
      c.rif.trim().toUpperCase() === rif.trim().toUpperCase() &&
      c.phone.trim() === phone.trim(),
  )

  const motivoApagado = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : faltan.length > 0
      ? `${faltan.length === 1 ? 'Falta' : 'Faltan'} ${enumerar(faltan)}.`
      : esCuentaDeRelleno(rif)
        ? 'Un RIF de ceros no es una cuenta.'
        : repetida
          ? 'Esa cuenta ya existe: actívala desde la lista.'
          : undefined

  return (
    <div className="flex flex-col gap-shell-gap-block">
      {query.data && activas.length === 0 && (
        <Callout tone="error" titulo="No hay ninguna cuenta de cobro activa">
          El comprobante y los avisos no dicen a dónde pagar: da de alta la cuenta de Helios aquí abajo.
        </Callout>
      )}

      {query.isLoading && <SkeletonTable rows={4} columns={6} />}
      {query.isError && (
        <ErrorBox title="No se pudieron leer las cuentas de cobro" detail={describeError(query.error)} />
      )}

      {cuentas.length > 0 && (
        <Seccion
          titulo="Cuentas de cobro"
          info="Las activas salen en el comprobante y en los avisos, en este orden. Las retiradas se conservan: un pago se coteja contra la cuenta que estaba activa ese día."
        >
          <Table headers={['Orden', 'Banco', 'RIF', 'Teléfono o cuenta', 'Titular', 'Pagos', 'Estado', '']}>
            {cuentas.map((d) => {
              const activasOrdenadas = cuentas.filter((c) => c.isActive)
              const puesto = activasOrdenadas.findIndex((c) => c.id === d.id)
              return (
                <Tr key={d.id}>
                  <Td className="whitespace-nowrap">
                    {d.isActive ? (
                      <span className="inline-flex items-center gap-1">
                        <span className="w-4 tabular-nums">{puesto + 1}</span>
                        <IconButton
                          label="Subir"
                          disabled={!isSuperAdmin || puesto === 0 || mover.isPending}
                          onClick={() => mover.mutate({ id: d.id, sentido: -1 })}
                        >
                          <ArrowUp size={14} />
                        </IconButton>
                        <IconButton
                          label="Bajar"
                          disabled={!isSuperAdmin || puesto === activasOrdenadas.length - 1 || mover.isPending}
                          onClick={() => mover.mutate({ id: d.id, sentido: 1 })}
                        >
                          <ArrowDown size={14} />
                        </IconButton>
                      </span>
                    ) : (
                      '—'
                    )}
                  </Td>
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
                    <span className="mt-0.5 block whitespace-nowrap type-panel-caption text-on-surface-variant">
                      alta {formatDateTime(d.createdAt)}
                    </span>
                  </Td>
                  <Td>
                    <Button
                      size="sm"
                      variant="tonal"
                      disabled={!isSuperAdmin || (!d.isActive && esCuentaDeRelleno(d.rif))}
                      title={!isSuperAdmin ? SOLO_SUPER_ADMIN : undefined}
                      onClick={() => setDecision({ tipo: d.isActive ? 'retirar' : 'activar', cuenta: d })}
                    >
                      {d.isActive ? 'Retirar' : 'Activar'}
                    </Button>
                  </Td>
                </Tr>
              )
            })}
          </Table>
          {mover.isError && <ErrorBox title="No se pudo cambiar el orden" detail={describeError(mover.error)} />}
        </Seccion>
      )}

      <Seccion
        titulo="Nueva cuenta de cobro"
        info="Un Pago Móvil, una cuenta para transferencias, un Zelle… Se activa al darla de alta y se suma a las activas, al final de la lista; no retira ninguna."
      >
        <Card>
          <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
            <Input id="dest-bank" label="Banco o medio" value={bank} onChange={setBank} placeholder="Banesco" />
            <Input id="dest-rif" label="Cédula o RIF" value={rif} onChange={setRif} placeholder="J-123456789" />
            <Input
              id="dest-phone"
              label="Teléfono (Pago Móvil) o número de cuenta"
              value={phone}
              onChange={setPhone}
              inputMode="tel"
              placeholder="0414 1234567"
            />
            <Input id="dest-holder" label="Titular (opcional)" value={holder} onChange={setHolder} placeholder="Helios C.A." />
          </div>
          <Button
            className="mt-4"
            size="md"
            disabled={motivoApagado !== undefined}
            motivoApagado={motivoApagado}
            onClick={() => setDecision({ tipo: 'alta' })}
          >
            Revisar y activar esta cuenta
          </Button>
        </Card>
      </Seccion>

      {decision && (
        <ConfirmDialog
          nivel={decision.tipo === 'retirar' && activas.length <= 1 ? 'critico' : 'sensible'}
          title={
            decision.tipo === 'alta'
              ? 'Activar una cuenta nueva'
              : decision.tipo === 'activar'
                ? 'Volver a activar la cuenta'
                : 'Retirar la cuenta'
          }
          summary={
            decision.tipo === 'alta'
              ? `${bank.trim()} (${rif.trim()}, ${phone.trim()}) se suma a las cuentas activas: los mensajes y comprobantes nuevos la enseñan desde que confirmes.`
              : decision.tipo === 'activar'
                ? `${decision.cuenta.bankName} (${decision.cuenta.rif}) vuelve a salir en los mensajes, al final de la lista.`
                : activas.length <= 1
                  ? `${decision.cuenta.bankName} es la única cuenta activa: al retirarla, los pacientes no sabrán a dónde pagar.`
                  : `${decision.cuenta.bankName} (${decision.cuenta.rif}) deja de salir en los mensajes. Los pagos ya hechos a ella se siguen cotejando.`
          }
          reasonPlaceholder={decision.tipo === 'retirar' ? 'Cerramos esa cuenta' : 'Cuenta nueva de Helios'}
          confirmLabel={decision.tipo === 'retirar' ? 'Retirar' : 'Activar'}
          busy={guardar.isPending}
          error={guardar.isError ? describeError(guardar.error) : undefined}
          onConfirm={(nota) => guardar.mutate({ d: decision, nota })}
          onClose={() => {
            setDecision(null)
            guardar.reset()
          }}
        />
      )}
    </div>
  )
}
