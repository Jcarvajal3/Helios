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
  Select,
  SkeletonTable,
  Table,
  Td,
  Tr,
  formatDateTime,
} from '@/components/ui'
import { enumerar, esCuentaDeRelleno } from '@/features/admin/ajustesReglas'
import { CLAVE_ESTADO_CONFIGURACION } from '@/features/admin/contacto/api'
import { moverCuenta, ordenarCuentas, siguienteOrden } from '@/features/admin/contacto/contacto'
import {
  METODOS_DE_COBRO,
  datosDe,
  esCuentaEnBolivares,
  fetchPaymentDestinations,
  nombreDelMetodoDeCobro,
  setPaymentDestination,
} from '@/features/admin/ops'
import type { CuentaEnBolivares, MetodoDeCobro, MetodoDeCuenta } from '@/features/admin/ops'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

/** Lo que se decide en el diálogo: dar de alta, activar o retirar una cuenta. */
type Decision =
  | { tipo: 'alta' }
  | { tipo: 'activar'; cuenta: CuentaEnBolivares }
  | { tipo: 'retirar'; cuenta: CuentaEnBolivares }

/**
 * Las cuentas a las que transfieren los pacientes (plan H11).
 *
 * En Helios puede haber **varias activas** a la vez —Pago Móvil y
 * transferencia—, cada una con su orden: los mensajes y el comprobante las
 * listan todas, en ese orden. Dar de alta una nueva ya no retira las demás.
 * Todo lo exige el servidor a un super admin y pide motivo.
 *
 * Desde el 2026-10-07 el paciente solo paga en bolívares: Pago Móvil o
 * transferencia. Las cuentas de Zelle de antes quedaron apagadas en la base y
 * aquí se listan como históricas, sin botones: los pagos viejos se siguen
 * cotejando contra ellas, pero ninguna vuelve a salir en un mensaje.
 *
 * Cada cuenta se edita por su id (`admin_set_payment_destination` con `p_id`,
 * contrato §2.3), mandándola completa: la base reescribe todos sus datos.
 * Cada método pide lo suyo: Pago Móvil banco + RIF + teléfono; transferencia
 * banco + RIF + cuenta de 20 dígitos + titular.
 */
export function CuentaDeCobro() {
  const avisar = useToast()
  const client = useQueryClient()
  const isSuperAdmin = useIsSuperAdmin()
  const query = useQuery({ queryKey: ['payment-destinations'], queryFn: fetchPaymentDestinations })

  const [method, setMethod] = useState<MetodoDeCobro>('pago_movil')
  const [bank, setBank] = useState('')
  const [rif, setRif] = useState('')
  const [phone, setPhone] = useState('')
  const [account, setAccount] = useState('')
  const [holder, setHolder] = useState('')
  const [decision, setDecision] = useState<Decision | null>(null)

  const cuentas = ordenarCuentas(query.data ?? [])
  // Las que se pueden ordenar, activar o retirar: las de bolívares. Una de
  // Zelle que siguiera activa por error tampoco cuenta: la base ya no la
  // enseña en los mensajes.
  const enBolivares = (query.data ?? []).filter(esCuentaEnBolivares)
  const activas = enBolivares.filter((c) => c.isActive && !esCuentaDeRelleno(c.rif))

  function refrescar() {
    void client.invalidateQueries({ queryKey: ['payment-destinations'] })
    void client.invalidateQueries({ queryKey: CLAVE_ESTADO_CONFIGURACION })
  }

  const guardar = useMutation({
    mutationFn: async ({ d, nota }: { d: Decision; nota: string }) => {
      if (d.tipo === 'alta') {
        return setPaymentDestination({
          method,
          bankName: bank.trim(),
          rif: rif.trim(),
          phone: method === 'pago_movil' ? phone.trim() : '',
          accountNumber: method === 'transferencia' ? soloDigitos(account) : null,
          email: null,
          holderName: holder.trim() || undefined,
          note: nota,
          sortOrder: siguienteOrden(enBolivares),
          isActive: true,
        })
      }
      return setPaymentDestination({
        ...datosDe(d.cuenta),
        note: nota,
        sortOrder: d.tipo === 'activar' ? siguienteOrden(enBolivares) : d.cuenta.sortOrder,
        isActive: d.tipo === 'activar',
      })
    },
    onSuccess: (_, { d }) => {
      if (d.tipo === 'alta') {
        avisar(`Cuenta de ${nombreDeCuenta({ method, bankName: bank.trim() })} activa. Los mensajes nuevos ya la enseñan.`)
        setBank('')
        setRif('')
        setPhone('')
        setAccount('')
        setHolder('')
      } else {
        avisar(d.tipo === 'activar' ? `Cuenta de ${nombreDeCuenta(d.cuenta)} activa` : `Cuenta de ${nombreDeCuenta(d.cuenta)} retirada`)
      }
      setDecision(null)
      refrescar()
    },
  })

  // Subir o bajar: dos escrituras, una por cuenta. El orden no pide motivo.
  const mover = useMutation({
    mutationFn: async ({ id, sentido }: { id: string; sentido: -1 | 1 }) => {
      const cambios = moverCuenta(enBolivares, id, sentido)
      if (!cambios) return
      for (const { cuenta, sortOrder } of cambios) {
        await setPaymentDestination({
          ...datosDe(cuenta),
          note: 'Cambio de orden',
          sortOrder,
          isActive: true,
        })
      }
    },
    onSettled: refrescar,
  })

  const digitosCuenta = soloDigitos(account)
  const faltan = [
    !bank.trim() && 'el banco',
    !rif.trim() && 'la cédula o el RIF',
    method === 'pago_movil' && !phone.trim() && 'el teléfono',
    method === 'transferencia' && digitosCuenta.length !== 20 && 'el número de cuenta (20 dígitos)',
    method === 'transferencia' && !holder.trim() && 'el titular',
  ].filter((f): f is string => typeof f === 'string')
  const claveNueva = claveDeCuenta({ method, bankName: bank, rif, phone, accountNumber: digitosCuenta })
  const repetida = cuentas.some((c) => claveDeCuenta(c) === claveNueva)

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
          info="Las activas salen en el comprobante y en los avisos, en este orden. Las retiradas se conservan: un pago se coteja contra la cuenta que estaba activa ese día. Las de Zelle son de antes del 2026-10-07, cuando el paciente aún podía pagar en divisas: quedan como historia y no se pueden volver a activar."
        >
          <Table headers={['Orden', 'Método', 'Banco', 'RIF', 'Teléfono, cuenta o correo', 'Titular', 'Pagos', 'Estado', '']}>
            {cuentas.map((d) => {
              const activasOrdenadas = cuentas.filter((c) => c.isActive && esCuentaEnBolivares(c))
              const puesto = activasOrdenadas.findIndex((c) => c.id === d.id)
              return (
                <Tr key={d.id}>
                  <Td className="whitespace-nowrap">
                    {d.isActive && esCuentaEnBolivares(d) ? (
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
                  <Td>{nombreDelMetodoDeCobro(d.method)}</Td>
                  <Td className="font-medium">{d.bankName || '—'}</Td>
                  <Td className="font-mono type-panel-caption">{d.rif || '—'}</Td>
                  <Td className="font-mono type-panel-caption">{dondeSePaga(d)}</Td>
                  <Td className="text-on-surface-variant">{d.holderName ?? '—'}</Td>
                  <Td className="tabular-nums text-on-surface-variant">{d.reportCount}</Td>
                  <Td>
                    {!esCuentaEnBolivares(d) ? (
                      <Badge>Histórica</Badge>
                    ) : d.isActive ? (
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
                    {esCuentaEnBolivares(d) ? (
                      <Button
                        size="sm"
                        variant="tonal"
                        disabled={!isSuperAdmin || (!d.isActive && esCuentaDeRelleno(d.rif))}
                        title={!isSuperAdmin ? SOLO_SUPER_ADMIN : undefined}
                        onClick={() => setDecision({ tipo: d.isActive ? 'retirar' : 'activar', cuenta: d })}
                      >
                        {d.isActive ? 'Retirar' : 'Activar'}
                      </Button>
                    ) : (
                      <span className="type-panel-caption text-on-surface-variant">Solo se paga en bolívares</span>
                    )}
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
        info="Un Pago Móvil o una cuenta para transferencias: el paciente solo paga en bolívares. Se activa al darla de alta y se suma a las activas, al final de la lista; no retira ninguna."
      >
        <Card>
          <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
            <Select id="dest-method" label="Método" value={method} options={METODOS_DE_COBRO} onChange={setMethod} />
            <Input id="dest-bank" label="Banco" value={bank} onChange={setBank} placeholder="Banesco" />
            <Input id="dest-rif" label="Cédula o RIF" value={rif} onChange={setRif} placeholder="J-123456789" />
            {method === 'pago_movil' && (
              <Input
                id="dest-phone"
                label="Teléfono del Pago Móvil"
                value={phone}
                onChange={setPhone}
                inputMode="tel"
                placeholder="0414 1234567"
              />
            )}
            {method === 'transferencia' && (
              <Input
                id="dest-account"
                label="Número de cuenta (20 dígitos)"
                value={account}
                onChange={setAccount}
                inputMode="numeric"
                placeholder="0134 0000 00 0000000000"
              />
            )}
            <Input
              id="dest-holder"
              label={method === 'pago_movil' ? 'Titular (opcional)' : 'Titular'}
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
              ? `${nombreDelMetodoDeCobro(method)} ${nombreDeCuenta({ method, bankName: bank.trim() })} (${dondeSePaga({ method, phone: phone.trim(), accountNumber: digitosCuenta })}) se suma a las cuentas activas: los mensajes y comprobantes nuevos la enseñan desde que confirmes.`
              : decision.tipo === 'activar'
                ? `${nombreDeCuenta(decision.cuenta)} (${decision.cuenta.rif}) vuelve a salir en los mensajes, al final de la lista.`
                : activas.length <= 1
                  ? `${nombreDeCuenta(decision.cuenta)} es la única cuenta activa: al retirarla, los pacientes no sabrán a dónde pagar.`
                  : `${nombreDeCuenta(decision.cuenta)} (${decision.cuenta.rif}) deja de salir en los mensajes. Los pagos ya hechos a ella se siguen cotejando.`
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

function soloDigitos(valor: string): string {
  return valor.replace(/\D/g, '')
}

/** Cómo se nombra una cuenta en un aviso: el banco, o «Zelle» si es una de las históricas. */
function nombreDeCuenta(c: { method: MetodoDeCuenta; bankName: string }): string {
  return c.method === 'zelle' ? 'Zelle' : c.bankName
}

/** El dato al que se paga: teléfono, número de cuenta o, en una de Zelle histórica, el correo. */
function dondeSePaga(c: {
  method: MetodoDeCuenta
  phone?: string
  accountNumber?: string | null
  email?: string | null
}): string {
  if (c.method === 'transferencia') return c.accountNumber || '—'
  if (c.method === 'zelle') return c.email || '—'
  return c.phone || '—'
}

/** Dos cuentas son la misma si coinciden método y destino. */
function claveDeCuenta(c: {
  method: MetodoDeCuenta
  bankName: string
  rif: string
  phone: string
  accountNumber?: string | null
  email?: string | null
}): string {
  const norm = (x: string | null | undefined) => (x ?? '').trim().toLowerCase().replace(/\s+/g, '')
  return [c.method, norm(c.bankName), norm(c.rif), norm(c.phone), soloDigitos(c.accountNumber ?? ''), norm(c.email)].join('|')
}
