import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Check, Copy } from 'lucide-react'

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
  Select,
  SkeletonList,
  formatDateTime,
} from '@/components/ui'
import { BANKS } from '@/features/admin/banks'
import { claveCuentaDePago, consultaCuentaDePago, guardarCuentaDePago } from '@/features/admin/clinicas/api'
import {
  borradorDeCuenta,
  cambioDeCuenta,
  formatoCuenta,
  lineasParaCopiar,
  textoParaCopiar,
} from '@/features/admin/clinicas/clinicas'
import type { BorradorDeCuenta, CuentaDePagoDeClinica } from '@/features/admin/clinicas/clinicas'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

/**
 * La cuenta a la que Helios le transfiere a la clínica los lunes
 * (`merchant_payout_accounts`, plan H8). Ronda no la guardaba: se pedía por
 * WhatsApp cada vez. Cambiarla lo exige el servidor a un super admin y queda
 * en la bitácora; cambiar una que ya existe pide escribir CAMBIAR: un dígito
 * mal puesto manda el pago de una semana a otra cuenta.
 */
export function CuentaDePago({ merchantId }: { merchantId: string }) {
  const cuenta = useQuery(consultaCuentaDePago(merchantId))
  const [editando, setEditando] = useState(false)
  const isSuperAdmin = useIsSuperAdmin()

  return (
    <Seccion
      titulo="Cuenta de pago"
      info="A dónde se le transfiere a la clínica lo de sus consultas y las comisiones de su personal. Sale al registrar cada transferencia, con botones para copiar."
      controles={
        cuenta.data !== undefined && !editando ? (
          <Button
            size="sm"
            variant="tonal"
            disabled={!isSuperAdmin}
            motivoApagado={isSuperAdmin ? undefined : SOLO_SUPER_ADMIN}
            onClick={() => setEditando(true)}
          >
            {cuenta.data ? 'Cambiar la cuenta' : 'Poner la cuenta'}
          </Button>
        ) : undefined
      }
    >
      {cuenta.isPending && <SkeletonList rows={2} />}
      {cuenta.isError && (
        <Card>
          <NoSePudoLeer onReintentar={() => void cuenta.refetch()} />
        </Card>
      )}
      {cuenta.data !== undefined &&
        (editando ? (
          <EditarCuenta merchantId={merchantId} actual={cuenta.data} onClose={() => setEditando(false)} />
        ) : cuenta.data ? (
          <Card>
            <DatosParaCopiar cuenta={cuenta.data} />
            {cuenta.data.updatedAt && (
              <p className="mt-4 type-panel-caption text-on-surface-variant">
                Cambiada el {formatDateTime(cuenta.data.updatedAt)}
                {cuenta.data.updatedByName ? ` por ${cuenta.data.updatedByName}` : ''}.
              </p>
            )}
          </Card>
        ) : (
          <Callout tone="warning" titulo="Esta clínica no tiene cuenta de pago">
            Sin ella, cada lunes hay que pedirle a dónde transferir. Ponla antes de su primer cierre.
          </Callout>
        ))}
    </Seccion>
  )
}

/**
 * La cuenta, línea a línea, cada una con su botón de copiar, y uno para
 * copiarla entera. Es lo que se pega en el banco al hacer la transferencia.
 */
export function DatosParaCopiar({ cuenta }: { cuenta: CuentaDePagoDeClinica }) {
  return (
    <div className="flex flex-col gap-2">
      <dl className="flex flex-col gap-1.5">
        {lineasParaCopiar(cuenta).map((l) => (
          <div key={l.rotulo} className="flex items-center justify-between gap-3">
            <dt className="type-panel-caption text-on-surface-variant">{l.rotulo}</dt>
            <dd className="flex items-center gap-2">
              <span className="font-mono type-panel-body text-on-surface">
                {l.rotulo === 'Cuenta' ? formatoCuenta(l.valor) : l.valor}
              </span>
              <BotonCopiar texto={l.valor} rotulo={`Copiar ${l.rotulo.toLowerCase()}`} />
            </dd>
          </div>
        ))}
      </dl>
      <div>
        <BotonCopiar texto={textoParaCopiar(cuenta)} rotulo="Copiar todo" conTexto />
      </div>
    </div>
  )
}

function BotonCopiar({ texto, rotulo, conTexto = false }: { texto: string; rotulo: string; conTexto?: boolean }) {
  const avisar = useToast()
  const [copiado, setCopiado] = useState(false)

  async function copiar() {
    try {
      await navigator.clipboard.writeText(texto)
      setCopiado(true)
      setTimeout(() => setCopiado(false), 1500)
    } catch {
      avisar('No se pudo copiar: el navegador no dejó usar el portapapeles')
    }
  }

  return (
    <button
      type="button"
      onClick={() => void copiar()}
      aria-label={rotulo}
      title={rotulo}
      className="inline-flex items-center gap-1 rounded-panel-control px-2 py-1 type-panel-caption text-on-surface-variant transition-colors hover:bg-panel-raised hover:text-on-surface"
    >
      {copiado ? <Check size={13} aria-hidden /> : <Copy size={13} aria-hidden />}
      {conTexto && (copiado ? 'Copiado' : rotulo)}
    </button>
  )
}

const OPCIONES_BANCO = BANKS.map((b) => ({ value: b.name, label: b.name }))

function EditarCuenta({
  merchantId,
  actual,
  onClose,
}: {
  merchantId: string
  actual: CuentaDePagoDeClinica | null
  onClose: () => void
}) {
  const client = useQueryClient()
  const avisar = useToast()
  const [b, setB] = useState<BorradorDeCuenta>(() => borradorDeCuenta(actual))
  const [confirmando, setConfirmando] = useState(false)
  const cambio = cambioDeCuenta(b)
  const campo = (k: keyof BorradorDeCuenta) => (v: string) => setB((prev) => ({ ...prev, [k]: v }))

  const guardar = useMutation({
    mutationFn: () => {
      if (!cambio.ok) throw new Error(cambio.motivo)
      return guardarCuentaDePago({ merchantId, payload: cambio.payload })
    },
    onSuccess: () => {
      avisar('Cuenta de pago guardada')
      void client.invalidateQueries({ queryKey: claveCuentaDePago(merchantId) })
      setConfirmando(false)
      onClose()
    },
  })

  return (
    <Card className="flex flex-col gap-4">
      <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
        <Input id={`cuenta-titular-${merchantId}`} label="Titular" value={b.accountHolder} onChange={campo('accountHolder')} placeholder="Consultorio Demo C.A." />
        <Input id={`cuenta-doc-${merchantId}`} label="Cédula o RIF del titular" value={b.holderDocument} onChange={campo('holderDocument')} placeholder="J-123456789" />
        <Select id={`cuenta-banco-${merchantId}`} label="Banco de la cuenta" value={b.bank} placeholder="Sin cuenta bancaria" options={OPCIONES_BANCO} onChange={campo('bank')} />
        <Input id={`cuenta-numero-${merchantId}`} label="Número de cuenta (20 dígitos)" value={b.accountNumber} onChange={campo('accountNumber')} inputMode="numeric" placeholder="0134 0000 0000 0000 0000" />
        <Input id={`cuenta-pm-${merchantId}`} label="Teléfono del Pago Móvil" value={b.pagoMovilPhone} onChange={campo('pagoMovilPhone')} inputMode="tel" placeholder="0414 1234567" />
        <Select id={`cuenta-pm-banco-${merchantId}`} label="Banco del Pago Móvil" value={b.pagoMovilBank} placeholder="Sin Pago Móvil" options={OPCIONES_BANCO} onChange={campo('pagoMovilBank')} />
      </div>
      <div className="flex flex-wrap items-start gap-3">
        <Button size="md" disabled={!cambio.ok} motivoApagado={cambio.ok ? undefined : cambio.motivo} onClick={() => setConfirmando(true)}>
          Revisar y guardar
        </Button>
        <Button size="md" variant="text" onClick={onClose}>
          Cancelar
        </Button>
      </div>
      {guardar.isError && !confirmando && <ErrorBox title="No se pudo guardar" detail={describeError(guardar.error)} />}

      {confirmando && cambio.ok && (
        <ConfirmDialog
          // Sin motivo: la RPC no lo recibe (contrato §2.5) y queda en la
          // bitácora igual. Cambiar una que ya existe pide escribir la palabra.
          confirmWord={actual ? 'CAMBIAR' : undefined}
          danger={actual !== null}
          title={actual ? 'Cambiar la cuenta de pago' : 'Poner la cuenta de pago'}
          summary="Desde que confirmes, las transferencias de los lunes a esta clínica van a esta cuenta."
          detail={
            <DatosParaCopiar
              cuenta={{
                bank: cambio.payload.bank ?? null,
                accountHolder: cambio.payload.account_holder ?? null,
                holderDocument: cambio.payload.holder_document ?? null,
                accountNumber: cambio.payload.account_number ?? null,
                pagoMovilPhone: cambio.payload.pago_movil_phone ?? null,
                pagoMovilBank: cambio.payload.pago_movil_bank ?? null,
                updatedAt: null,
                updatedByName: null,
              }}
            />
          }
          confirmLabel="Guardar la cuenta"
          busy={guardar.isPending}
          error={guardar.isError ? describeError(guardar.error) : undefined}
          onConfirm={() => guardar.mutate()}
          onClose={() => {
            setConfirmando(false)
            guardar.reset()
          }}
        />
      )}
    </Card>
  )
}
