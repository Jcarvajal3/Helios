import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Callout,
  Card,
  Chip,
  ConfirmDialog,
  InfoDot,
  Input,
  NoSePudoLeer,
  Seccion,
  Table,
  Td,
  Tr,
  formatDay,
  hoyCaracas,
} from '@/components/ui'
import { fetchMerchantTermsHistory, setSettlementTerms } from '@/features/admin/api'
import type { MerchantTerms, SettlementPolicy } from '@/features/admin/api'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { formatoMontoEditable, leerMonto } from '@/lib/montos'
import { describeError } from '@/lib/supabase'

const POLITICAS: Array<{ value: SettlementPolicy; label: string }> = [
  { value: 'scheduled', label: 'Por fecha' },
  { value: 'on_collection', label: 'Por cobranza' },
]

const politica = (p: SettlementPolicy) => (p === 'scheduled' ? 'por fecha' : 'por cobranza')

/**
 * Las condiciones de liquidación: cuánto se le adelanta, cuánto por cuota, su
 * comisión y cuándo se le paga. Tienen fecha: cada consumo se liquida con las
 * vigentes su noche. Cambiarlas lo exige el servidor a un super admin, y el
 * diálogo pide el motivo porque mueve el dinero que se le transfiere al local.
 */
export function Condiciones({
  merchantId,
  initial,
  onDone,
}: {
  merchantId: string
  initial: MerchantTerms
  onDone: () => void
}) {
  const avisar = useToast()
  const isSuperAdmin = useIsSuperAdmin()
  const queryClient = useQueryClient()

  // Con coma y no con `String`: «2.125» volvería de `leerMonto` como 2125.
  const [upfront, setUpfront] = useState(formatoMontoEditable(initial.upfrontPct))
  const [perInstallment, setPerInstallment] = useState(formatoMontoEditable(initial.perInstallmentPct))
  const [commission, setCommission] = useState(formatoMontoEditable(initial.commissionPct))
  const [policy, setPolicy] = useState<SettlementPolicy>(initial.policy)
  const [desde, setDesde] = useState(hoyCaracas())
  const [confirmando, setConfirmando] = useState(false)

  const historia = useQuery({
    queryKey: ['merchant-terms-history', merchantId],
    queryFn: () => fetchMerchantTermsHistory(merchantId),
  })

  const nums: MerchantTerms = {
    // Lo que no se entiende como cifra es NaN: no cuadra y no se envía.
    upfrontPct: leerMonto(upfront) ?? NaN,
    perInstallmentPct: leerMonto(perInstallment) ?? NaN,
    commissionPct: leerMonto(commission) ?? NaN,
    policy,
  }

  // La comisión NO entra en esta suma: los tramos reparten el neto del
  // consumo (adelanto + dos cuotas = 100 %) y la comisión es lo que Ronda le
  // factura al local aparte.
  const total = nums.upfrontPct + nums.perInstallmentPct * 2
  const cuadra = Math.abs(total - 100) < 0.001

  // Nunca hacia atrás: los consumos ya cerrados se liquidaron con las
  // condiciones de su noche.
  const desdeOk = desde >= hoyCaracas()

  const mutation = useMutation({
    mutationFn: (nota: string) =>
      setSettlementTerms({ merchantId, terms: nums, effectiveFrom: desde, note: nota }),
    onSuccess: () => {
      setConfirmando(false)
      avisar(`Condiciones nuevas, en vigor desde el ${formatDay(desde)}`)
      void queryClient.invalidateQueries({ queryKey: ['merchant-terms-history', merchantId] })
      onDone()
    },
  })

  const bloqueo = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : !cuadra
      ? 'El adelanto más dos veces lo de cada cuota tiene que dar 100.'
      : !Number.isFinite(nums.commissionPct)
        ? 'La comisión de la clínica no es una cifra válida.'
        : !desdeOk
          ? 'La fecha de vigencia no puede ser anterior a hoy.'
          : undefined

  return (
    <Seccion
      titulo="Condiciones de liquidación"
      info="Cada financiamiento se liquida con las condiciones vigentes su día: cambiarlas no toca nada de lo ya financiado. El adelanto y las dos cuotas cubren el neto entero (100); la comisión de la clínica va aparte, y Helios se la factura. Cambiarlas lo exige el servidor a un super admin."
    >
      <Card className="flex flex-col gap-4">
      <div className="grid grid-cols-3 gap-3">
        <Input id={`up-${merchantId}`} label="Adelanto %" value={upfront} onChange={setUpfront} inputMode="decimal" />
        <Input
          id={`cu-${merchantId}`}
          label="Por cuota %"
          value={perInstallment}
          onChange={setPerInstallment}
          inputMode="decimal"
        />
        <Input
          id={`co-${merchantId}`}
          label="Comisión de la clínica %"
          value={commission}
          onChange={setCommission}
          inputMode="decimal"
        />
      </div>

      {cuadra ? (
        <p className="type-panel-caption text-panel-muted">
          {nums.upfrontPct || 0} + ({nums.perInstallmentPct || 0} × 2) = {total}: los tramos cuadran.
        </p>
      ) : (
        <Callout tone="error" titulo="Los tramos no cuadran">
          {nums.upfrontPct || 0} + ({nums.perInstallmentPct || 0} × 2) ={' '}
          {Number.isFinite(total) ? total : '—'}: tienen que cubrir el neto entero (100).
        </Callout>
      )}

      <div className="flex flex-col gap-2">
        <div className="flex items-center gap-1.5">
          <span className="type-panel-label text-on-surface-variant">Cuándo se le paga</span>
          <InfoDot
            title="Cuándo se le paga"
            what="Por fecha: se le liquida en las fechas pactadas, pague o no el paciente, y la pérdida es de Helios. Por cobranza: se le liquida cuando el paciente paga, y la pérdida es de la clínica."
          />
        </div>
        <div className="flex gap-2">
          {POLITICAS.map((p) => (
            <Chip key={p.value} selected={policy === p.value} onClick={() => setPolicy(p.value)}>
              {p.label}
            </Chip>
          ))}
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <Input
          id={`desde-${merchantId}`}
          label="Vigente desde"
          type="date"
          value={desde}
          onChange={setDesde}
          error={!desdeOk}
        />
      </div>

      <div>
        <Button
          size="md"
          disabled={!!bloqueo}
          motivoApagado={bloqueo}
          onClick={() => setConfirmando(true)}
        >
          Guardar las condiciones
        </Button>
      </div>
      </Card>

      <Historia historia={historia} />

      {confirmando && (
        <ConfirmDialog
          title="Cambiar las condiciones"
          summary={`Desde el ${formatDay(desde)}, ${nums.upfrontPct} % de adelanto, ${nums.perInstallmentPct} % por cuota y ${nums.commissionPct} % de comisión de la clínica, con liquidación ${politica(policy)}.`}
          detail={
            <p className="type-panel-body text-on-surface-variant">
              Antes: {initial.upfrontPct} % / {initial.perInstallmentPct} % / {initial.commissionPct} %,{' '}
              {politica(initial.policy)}. Los financiamientos anteriores a esa fecha se siguen liquidando
              con las suyas.
            </p>
          }
          nivel="sensible"
          reasonLabel="Por qué se cambian"
          reasonPlaceholder="Renegociado con el administrador"
          confirmLabel="Guardar las condiciones"
          busy={mutation.isPending}
          error={mutation.isError ? describeError(mutation.error) : undefined}
          onConfirm={(nota) => mutation.mutate(nota)}
          onClose={() => {
            setConfirmando(false)
            mutation.reset()
          }}
        />
      )}
    </Seccion>
  )
}

/** Lo que se ha pactado con el local, para explicar una venta vieja. */
function Historia({
  historia,
}: {
  historia: { data?: Awaited<ReturnType<typeof fetchMerchantTermsHistory>>; isError: boolean; refetch: () => unknown }
}) {
  if (historia.isError) {
    return (
      <p className="type-panel-body text-on-surface-variant">
        Lo pactado antes: <NoSePudoLeer onReintentar={() => void historia.refetch()} />
      </p>
    )
  }

  const filas = historia.data ?? []
  if (filas.length <= 1) return null

  return (
    <Seccion titulo="Lo que se ha pactado" as="div" info="Sirve para explicar un financiamiento vieja: cada financiamiento se liquidó con las condiciones de su día.">
      <Table headers={['Desde', 'Reparto', 'Cómo', 'Quién']}>
        {filas.map((h) => (
          <Tr key={h.id}>
            <Td className="whitespace-nowrap">
              {formatDay(h.effectiveFrom)}
              {!h.isCurrentOrPast && (
                <span className="mt-0.5 block">
                  <Badge tone="neutral">Todavía no vigente</Badge>
                </span>
              )}
            </Td>
            <Td className="whitespace-nowrap tabular-nums type-panel-caption">
              {h.upfrontPct} % + {h.perInstallmentPct} % × 2
              <span className="block text-on-surface-variant">comisión {h.commissionPct} %</span>
            </Td>
            <Td className="type-panel-caption text-on-surface-variant">
              {h.policy === 'scheduled' ? 'Por fecha' : 'Por cobranza'}
              {h.note && <span className="block italic">{h.note}</span>}
            </Td>
            <Td className="type-panel-caption text-on-surface-variant">{h.createdByName}</Td>
          </Tr>
        ))}
      </Table>
    </Seccion>
  )
}
