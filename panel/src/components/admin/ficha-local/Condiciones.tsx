import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Card,
  ConfirmDialog,
  InfoDot,
  Input,
  NoSePudoLeer,
  Seccion,
  Table,
  Td,
  Tr,
  formatDay,
  formatUsd,
  hoyCaracas,
} from '@/components/ui'
import { fetchMerchantTermsHistory, setSettlementTerms } from '@/features/admin/api'
import type { MerchantTerms } from '@/features/admin/api'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { formatoMontoEditable, leerMonto } from '@/lib/montos'
import { describeError } from '@/lib/supabase'

/**
 * El reparto de Helios, el único que acepta el servidor
 * (`admin_set_settlement_terms`, 20261019210200): sin adelanto, la mitad de la
 * consulta en cada cuota, sin comisión de la clínica y por fecha. Las
 * columnas vienen de Ronda, donde cada local pactaba el suyo.
 */
const REPARTO_DE_HELIOS: Pick<MerchantTerms, 'upfrontPct' | 'perInstallmentPct' | 'commissionPct' | 'policy'> = {
  upfrontPct: 0,
  perInstallmentPct: 50,
  commissionPct: 0,
  policy: 'scheduled',
}

/**
 * Las condiciones de una clínica. Lo que se le paga no se pacta: recibe el
 * 100 % de cada consulta, la mitad el día siguiente al vencimiento de cada
 * cuota del paciente (días 8 y 15), pague o no el paciente. Lo único que se
 * pacta es la comisión de su personal por orden confirmada.
 *
 * Tienen fecha: cada orden se liquida con las vigentes su día. Cambiarlas lo
 * exige el servidor a un super admin, y el diálogo pide el motivo.
 */
export function Condiciones({
  merchantId,
  initial,
  comisionGlobal,
  onDone,
}: {
  merchantId: string
  initial: MerchantTerms
  /** El parámetro `staff_commission_usd`: lo que vale si la clínica no tiene la suya. */
  comisionGlobal: number | null
  onDone: () => void
}) {
  const avisar = useToast()
  const isSuperAdmin = useIsSuperAdmin()
  const queryClient = useQueryClient()

  // Vacío = usa el global (`null` en la base). Con coma y no con `String`:
  // «0.5» volvería de `leerMonto` como 5.
  const [comisionPersonal, setComisionPersonal] = useState(
    initial.staffCommissionUsd === null ? '' : formatoMontoEditable(initial.staffCommissionUsd),
  )
  const [desde, setDesde] = useState(hoyCaracas())
  const [confirmando, setConfirmando] = useState(false)

  const historia = useQuery({
    queryKey: ['merchant-terms-history', merchantId],
    queryFn: () => fetchMerchantTermsHistory(merchantId),
  })

  const nums: MerchantTerms = {
    ...REPARTO_DE_HELIOS,
    staffCommissionUsd: comisionPersonal.trim() === '' ? null : (leerMonto(comisionPersonal) ?? NaN),
  }
  const comisionOk =
    nums.staffCommissionUsd === null ||
    (Number.isFinite(nums.staffCommissionUsd) && nums.staffCommissionUsd >= 0)
  const textoComision = (v: number | null) =>
    v === null
      ? `la global${comisionGlobal !== null ? ` (${formatUsd(comisionGlobal)})` : ''}`
      : formatUsd(v)

  // Nunca hacia atrás: las órdenes ya registradas se liquidaron con las
  // condiciones de su día.
  const desdeOk = desde >= hoyCaracas()

  const mutation = useMutation({
    mutationFn: (nota: string) =>
      setSettlementTerms({ merchantId, terms: nums, effectiveFrom: desde, note: nota }),
    onSuccess: () => {
      setConfirmando(false)
      avisar(`Comisión del personal nueva, en vigor desde el ${formatDay(desde)}`)
      void queryClient.invalidateQueries({ queryKey: ['merchant-terms-history', merchantId] })
      onDone()
    },
  })

  const bloqueo = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : !comisionOk
      ? 'La comisión por orden no es una cifra válida (vacía = la global).'
      : !desdeOk
        ? 'La fecha de vigencia no puede ser anterior a hoy.'
        : undefined

  return (
    <Seccion
      titulo="Condiciones"
      info="Cada orden se liquida con las condiciones vigentes su día: cambiarlas no toca nada de lo ya registrado. Cambiarlas lo exige el servidor a un super admin."
    >
      <Card className="flex flex-col gap-4">
        <div className="flex flex-col gap-1">
          <span className="type-panel-label text-on-surface-variant">Lo que se le paga</span>
          <p className="type-panel-body text-on-surface">
            El 100 % de cada consulta: la mitad el día siguiente al vencimiento de cada cuota del paciente
            (a los 8 y a los 15 días), pague o no el paciente. Es igual para todas las clínicas y no se
            pacta.
          </p>
        </div>

        <div className="flex flex-col gap-2">
          <div className="flex items-center gap-1.5">
            <span className="type-panel-label text-on-surface-variant">Comisión del personal por orden</span>
            <InfoDot
              title="Comisión del personal por orden"
              what="Lo que gana quien registra cada orden confirmada en esta clínica. Se le paga a la clínica junto con la primera mitad de esa consulta (día 8 de la orden), sumada en la misma transferencia, y ella se la entrega a su personal. Vacía, usa el valor global de Ajustes › Parámetros."
            />
          </div>
          <div className="grid gap-3 sm:grid-cols-2">
            <Input
              id={`comision-personal-${merchantId}`}
              value={comisionPersonal}
              onChange={setComisionPersonal}
              inputMode="decimal"
              placeholder={comisionGlobal !== null ? `${formatoMontoEditable(comisionGlobal)} (la global)` : 'La global'}
              error={!comisionOk}
              hint={
                nums.staffCommissionUsd === null
                  ? `Vacía: usa la global${comisionGlobal !== null ? `, hoy ${formatUsd(comisionGlobal)}` : ''}.`
                  : 'En dólares, por orden confirmada.'
              }
            />
          </div>
        </div>

        <div className="grid gap-3 sm:grid-cols-2">
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
          <Button size="md" disabled={!!bloqueo} motivoApagado={bloqueo} onClick={() => setConfirmando(true)}>
            Guardar la comisión
          </Button>
        </div>
      </Card>

      <Historia historia={historia} />

      {confirmando && (
        <ConfirmDialog
          title="Cambiar la comisión del personal"
          summary={`Desde el ${formatDay(desde)}, comisión del personal por orden: ${textoComision(nums.staffCommissionUsd)}.`}
          detail={
            <p className="type-panel-body text-on-surface-variant">
              Antes: {textoComision(initial.staffCommissionUsd)}. Las órdenes anteriores a esa fecha se siguen
              liquidando con la suya: la comisión ya devengada no cambia.
            </p>
          }
          nivel="sensible"
          reasonLabel="Por qué se cambia"
          reasonPlaceholder="Pactado con el administrador"
          confirmLabel="Guardar la comisión"
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

/** Lo que se ha pactado con la clínica, para explicar una orden vieja. */
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
    <Seccion titulo="Lo que se ha pactado" as="div" info="Sirve para explicar una orden vieja: cada orden se liquidó con las condiciones de su día.">
      <Table headers={['Desde', 'Comisión del personal', 'Quién']}>
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
            <Td className="type-panel-caption tabular-nums">
              {h.staffCommissionUsd === null ? 'La global' : formatUsd(h.staffCommissionUsd)}
              {h.note && <span className="block italic text-on-surface-variant">{h.note}</span>}
            </Td>
            <Td className="type-panel-caption text-on-surface-variant">{h.createdByName}</Td>
          </Tr>
        ))}
      </Table>
    </Seccion>
  )
}
