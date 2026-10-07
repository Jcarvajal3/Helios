import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import {
  Button,
  Callout,
  Card,
  ConfirmDialog,
  InfoDot,
  Input,
  NoSePudoLeer,
  Select,
  formatDay,
  formatMoneda,
  formatUsd,
  formatVes,
  hoyCaracas,
} from '@/components/ui'
import type { Moneda } from '@/components/ui'
import { AdjuntarComprobante } from '@/components/admin/caja/AdjuntarComprobante'
import { DatosParaCopiar } from '@/components/admin/ficha-local/CuentaDePago'
import { reportMerchantPayout, uploadPayoutReceipt } from '@/features/admin/api'
import { consultaCuentaDePago } from '@/features/admin/clinicas/api'
import type { ConsultasYComisiones } from '@/features/admin/clinicas/clinicas'
import { fetchFxHistory } from '@/features/admin/fx'
import {
  METODOS_DE_PAGO,
  bolivaresPorMoneda,
  medioConReferencia,
  monedasDe,
  nombreDelMedio,
  partesPorMoneda,
  tasaDelDia,
} from '@/features/admin/liquidaciones'
import type { LineaAPagar, PayoutMethod } from '@/features/admin/liquidaciones'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { useToast } from '@/components/Toast'
import { formatoMontoEditable, leerMonto } from '@/lib/montos'
import { describeError } from '@/lib/supabase'

/** Los medios que salen del banco en bolívares: los únicos con tasa. */
const EN_BOLIVARES: readonly PayoutMethod[] = ['pago_movil', 'transferencia']

/** Días de tasas que se piden: bastan para una transferencia registrada tarde. */
const DIAS_DE_TASAS = 60

/** «del dólar», «del euro». */
const DE_LA_MONEDA: Record<Moneda, string> = { USD: 'del dólar', EUR: 'del euro' }

/**
 * Registrar una transferencia que ya se hizo por fuera, contra las
 * liquidaciones marcadas.
 *
 * El monto en dólares vacío es «todo lo marcado». En bolívares, cada
 * liquidación va a la tasa BCV de la moneda de su orden (2026-10-07: una
 * consulta se cobra en dólares o en euros) del día en que salió del banco,
 * que no es la de hoy si se registra el lunes lo del viernes, y el monto por
 * defecto sale de sumar las partes. Vacíos, los calcula el servidor con esas
 * mismas tasas; escritos, mandan: es lo que dice el extracto.
 *
 * La tasa a mano es la de UNA moneda: si lo marcado mezcla dólares y euros no
 * se ofrece, y lo que se corrige es el total en bolívares.
 */
export function RegistrarTransferencia({
  merchantId,
  merchantName,
  settlementIds,
  lineas,
  totalUsd,
  desglose,
  onRegistrado,
}: {
  merchantId: string
  merchantName: string
  settlementIds: string[]
  /** Las liquidaciones marcadas, con su moneda: de ellas salen los bolívares. */
  lineas: LineaAPagar[]
  /** Lo que FALTA de las liquidaciones marcadas: el máximo que se puede pagar. */
  totalUsd: number
  /** Lo marcado, partido en consultas y comisiones del personal (plan §6). */
  desglose?: ConsultasYComisiones
  onRegistrado: () => void
}) {
  const queryClient = useQueryClient()
  const isSuperAdmin = useIsSuperAdmin()
  const avisar = useToast()
  // A dónde se transfiere: con botones para copiar cada dato en el banco.
  const cuenta = useQuery(consultaCuentaDePago(merchantId))

  const [metodo, setMetodo] = useState<PayoutMethod>('pago_movil')
  const [referencia, setReferencia] = useState('')
  const [importe, setImporte] = useState('')
  const [fecha, setFecha] = useState(hoyCaracas())
  const [tasa, setTasa] = useState('')
  const [bolivares, setBolivares] = useState('')
  const [comprobante, setComprobante] = useState<File | null>(null)
  const [confirmando, setConfirmando] = useState(false)

  const conBolivares = EN_BOLIVARES.includes(metodo)
  const monedas = monedasDe(lineas)
  const mezcla = monedas.length > 1
  /** La moneda de lo marcado si es una sola: la de la tasa que se puede escribir. */
  const unica: Moneda | null = monedas.length === 1 ? (monedas[0] ?? null) : null
  const hayEuros = monedas.includes('EUR')

  const tasasDolar = useQuery({
    queryKey: ['fx-history', 'USD', DIAS_DE_TASAS],
    queryFn: () => fetchFxHistory(DIAS_DE_TASAS, 'USD'),
    enabled: conBolivares,
    staleTime: 5 * 60_000,
  })
  const tasasEuro = useQuery({
    queryKey: ['fx-history', 'EUR', DIAS_DE_TASAS],
    queryFn: () => fetchFxHistory(DIAS_DE_TASAS, 'EUR'),
    enabled: conBolivares && hayEuros,
    staleTime: 5 * 60_000,
  })

  // Vacío significa «todo lo marcado». Lo que no se entiende como cifra es
  // NaN, y NaN no pasa `importeValido`.
  const importeNum = importe.trim() === '' ? totalUsd : (leerMonto(importe) ?? NaN)
  const importeValido = Number.isFinite(importeNum) && importeNum > 0 && importeNum <= totalUsd + 0.005
  const parcial = importeValido && importeNum < totalUsd - 0.005
  const dolares = importeValido ? importeNum : totalUsd
  // Lo que el pago lleva en cada moneda, repartido como lo hará la base.
  const partes = partesPorMoneda(lineas, dolares)

  const tasaBcv: Record<Moneda, number | null> = {
    USD: tasasDolar.data ? tasaDelDia(tasasDolar.data, fecha) : null,
    EUR: tasasEuro.data ? tasaDelDia(tasasEuro.data, fecha) : null,
  }
  // Con monedas mezcladas no hay tasa que escribir: lo que hubiera en la
  // casilla de antes no cuenta.
  const tasaBcvDeLaUnica = unica === null ? null : tasaBcv[unica]
  const tasaEscrita = mezcla || tasa.trim() === '' ? null : leerMonto(tasa)
  const tasaIlegible = !mezcla && tasa.trim() !== '' && tasaEscrita === null
  const tasasUsadas: Record<Moneda, number | null> =
    unica !== null && tasaEscrita !== null ? { ...tasaBcv, [unica]: tasaEscrita } : tasaBcv
  const bolivaresEscritos = bolivares.trim() === '' ? null : leerMonto(bolivares)
  const bolivaresIlegibles = bolivares.trim() !== '' && bolivaresEscritos === null
  // Sin el historial (o sin tasa ese día), si se paga hoy todo lo marcado,
  // valen los bolívares de hoy que manda la base con cada liquidación.
  const vesDeHoy =
    fecha === hoyCaracas() && !parcial && tasaEscrita === null && lineas.every((l) => l.pendingVesHoy != null)
      ? Math.round(lineas.reduce((s, l) => s + (l.pendingVesHoy ?? 0), 0) * 100) / 100
      : null
  const bolivaresPorDefecto = bolivaresPorMoneda(partes, tasasUsadas) ?? vesDeHoy

  const referenciaOk = !medioConReferencia(metodo) || referencia.trim().length > 0
  const fechaOk = fecha !== '' && fecha <= hoyCaracas()

  const bloqueo = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : settlementIds.length === 0
      ? 'Marca al menos una liquidación.'
      : !referenciaOk
        ? 'Falta la referencia de la transferencia.'
        : !importeValido
          ? `El monto tiene que ser mayor que cero y no pasar de ${formatUsd(totalUsd)}.`
          : !fechaOk
            ? 'La fecha de salida no puede ser futura.'
            : conBolivares && (tasaIlegible || bolivaresIlegibles)
              ? `${tasaIlegible ? 'La tasa' : 'El monto en bolívares'} no es una cifra válida. Escríbela como 1.250,50.`
              : undefined

  const mutation = useMutation({
    // El motivo se escribe en el diálogo, que es donde ya se ve qué se va a
    // registrar, y viaja como la nota de la transferencia: queda en la fila y
    // en la bitácora.
    mutationFn: async (motivo: string) => {
      // El comprobante primero: si la subida falla, no se registra un pago que
      // dice tener un papel que no está.
      const receiptPath =
        comprobante
          ? await uploadPayoutReceipt({ merchantId, file: comprobante })
          : undefined

      await reportMerchantPayout({
        merchantId,
        settlementIds,
        method: metodo,
        reference: referencia.trim() || undefined,
        note: motivo,
        amountUsd: parcial ? importeNum : undefined,
        paidOn: fecha || undefined,
        // Vacíos, el servidor aplica la tasa BCV de cada moneda del día de
        // salida. La tasa escrita solo viaja con una moneda: con dos, la base
        // la rechaza.
        amountVes: conBolivares ? (bolivaresEscritos ?? undefined) : undefined,
        fxRate: conBolivares && !mezcla ? (tasaEscrita ?? undefined) : undefined,
        receiptPath,
      })
    },
    onSuccess: () => {
      setConfirmando(false)
      avisar(`Transferencia registrada: ${formatUsd(dolares)} a ${merchantName}`)
      setReferencia('')
      setImporte('')
      setTasa('')
      setBolivares('')
      setComprobante(null)
      setFecha(hoyCaracas())
      for (const clave of [
        'merchant-payables',
        'settlements',
        'merchant-payouts',
        'settlement-runs',
        'run-payables',
        'admin-overview',
        'admin-cash',
        'admin-forecast',
      ]) {
        void queryClient.invalidateQueries({ queryKey: [clave] })
      }
      onRegistrado()
    },
  })

  const errorDeTasas = tasasDolar.isError || tasasEuro.isError
  // «$55,00 a la tasa del dólar y €50,00 a la del euro»: solo si hay euros,
  // que con dólares solos no hay nada que aclarar.
  const lasPartes = hayEuros
    ? monedas
        .filter((m) => partes[m] > 0)
        .map((m) => `${formatMoneda(partes[m], m)} a la tasa ${DE_LA_MONEDA[m]}`)
        .join(' y ')
    : null

  return (
    <Card as="section" className="mt-2 flex flex-col gap-4">
      <div className="flex items-center gap-1.5">
        <h3 className="type-panel-section text-on-surface">Registrar una transferencia</h3>
        <InfoDot
          title="Registrar una transferencia"
          what="Deja constancia de una transferencia que ya se hizo por fuera y baja lo que se le debe a la clínica. Se aplica a las liquidaciones marcadas arriba, de la más antigua a la más nueva. En bolívares, cada liquidación va a la tasa BCV de la moneda en que se cobró su orden (dólar o euro) del día en que salió del banco."
        />
      </div>

      <div className="rounded-panel-control border border-panel-hairline p-4">
        <p className="mb-2 type-panel-label text-on-surface-variant">Cuenta de pago de la clínica</p>
        {cuenta.isError ? (
          <NoSePudoLeer onReintentar={() => void cuenta.refetch()} />
        ) : cuenta.data === undefined ? (
          <p className="type-panel-caption text-on-surface-variant">Leyendo…</p>
        ) : cuenta.data ? (
          <DatosParaCopiar cuenta={cuenta.data} />
        ) : (
          <p className="type-panel-body text-warning">
            La clínica no tiene cuenta de pago. Ponla en su ficha, pestaña «Cuenta de pago».
          </p>
        )}
      </div>

      <div className="grid gap-3 md:grid-cols-3">
        <Select
          id={`medio-${merchantId}`}
          label="Medio"
          value={metodo}
          options={METODOS_DE_PAGO}
          onChange={setMetodo}
        />
        <Input
          id={`ref-${merchantId}`}
          label={medioConReferencia(metodo) ? 'Referencia' : 'Referencia (no hace falta en efectivo)'}
          value={referencia}
          onChange={setReferencia}
          placeholder="Últimos dígitos o identificador de la operación"
        />
        <Input
          id={`fecha-${merchantId}`}
          label="Salió del banco el"
          type="date"
          value={fecha}
          max={hoyCaracas()}
          onChange={setFecha}
          error={!fechaOk}
        />
      </div>

      <div className="grid gap-3 md:grid-cols-3">
        <Input
          id={`importe-${merchantId}`}
          label="Monto transferido en dólares"
          value={importe}
          onChange={setImporte}
          inputMode="decimal"
          placeholder={formatoMontoEditable(totalUsd)}
          error={!importeValido}
        />
        {conBolivares && (
          <>
            {unica !== null ? (
              <Input
                id={`tasa-${merchantId}`}
                label={`Tasa ${DE_LA_MONEDA[unica]} (Bs/${unica === 'EUR' ? '€' : '$'})`}
                value={tasa}
                onChange={setTasa}
                inputMode="decimal"
                placeholder={
                  tasaBcvDeLaUnica === null
                    ? `Tasa BCV ${DE_LA_MONEDA[unica]} de ese día`
                    : formatoMontoEditable(tasaBcvDeLaUnica)
                }
                error={tasaIlegible}
                hint={
                  errorDeTasas
                    ? 'No se pudo leer la BCV; la pondrá el servidor.'
                    : `Vacía, va la BCV ${DE_LA_MONEDA[unica]} del ${formatDay(fecha)}.`
                }
              />
            ) : (
              <p className="self-center type-panel-caption text-on-surface-variant">
                Lo marcado va en dólares y en euros: cada parte se paga a la tasa BCV de su moneda del{' '}
                {formatDay(fecha)}. Si el banco usó otra, escribe solo el total en bolívares.
              </p>
            )}
            <Input
              id={`ves-${merchantId}`}
              label="Monto en bolívares"
              value={bolivares}
              onChange={setBolivares}
              inputMode="decimal"
              placeholder={
                bolivaresPorDefecto === null ? 'Según la tasa' : formatoMontoEditable(bolivaresPorDefecto)
              }
              error={bolivaresIlegibles}
              hint={lasPartes ? `${lasPartes}.` : undefined}
            />
          </>
        )}
      </div>

      <div className="grid gap-3 md:grid-cols-2">
        <AdjuntarComprobante id={`comp-${merchantId}`} file={comprobante} onChange={setComprobante} />
      </div>

      {parcial && (
        <Callout
          tone="warning"
          titulo="Es un pago parcial"
          detalles="Se aplica de la liquidación más antigua a la más nueva, y la última que alcance queda a medias."
        >
          A la clínica le quedarán por cobrar {formatUsd(totalUsd - importeNum)} de lo marcado.
        </Callout>
      )}

      <div className="flex flex-wrap items-center justify-between gap-4 rounded-panel-control bg-panel-raised p-4">
        <span className="type-panel-body text-on-surface-variant">
          {settlementIds.length}{' '}
          {settlementIds.length === 1 ? 'liquidación marcada' : 'liquidaciones marcadas'}
          {parcial && `, por ${formatUsd(totalUsd)}`}
          {desglose && (
            <span className="block type-panel-caption">
              Consultas {formatUsd(desglose.consultasUsd)} + Comisiones del personal{' '}
              {formatUsd(desglose.comisionesUsd)}
            </span>
          )}
          {hayEuros && partes.EUR > 0 && (
            <span className="block type-panel-caption">
              De ello, {formatMoneda(partes.EUR, 'EUR')} de órdenes cobradas en euros
            </span>
          )}
        </span>
        <span className="text-right">
          <span className="block type-panel-figure text-on-surface">{formatUsd(dolares)}</span>
          {conBolivares && (bolivaresEscritos ?? bolivaresPorDefecto) !== null && (
            <span className="block type-panel-caption tabular-nums text-on-surface-variant">
              {formatVes(bolivaresEscritos ?? bolivaresPorDefecto ?? 0)}
            </span>
          )}
        </span>
      </div>

      <Button
        size="md"
        disabled={bloqueo !== undefined}
        motivoApagado={bloqueo}
        onClick={() => setConfirmando(true)}
      >
        Registrar el pago de {formatUsd(dolares)}
      </Button>

      <p className="type-panel-caption text-panel-muted">
        Registra una transferencia que ya se hizo por fuera: no mueve dinero.
      </p>

      {confirmando && (
        <ConfirmDialog
          title="Registrar el pago"
          summary={`Vas a registrar un pago de ${formatUsd(dolares)} a ${merchantName} por ${nombreDelMedio(metodo)}${
                  referencia.trim() ? `, referencia ${referencia.trim()}` : ''
          }, que salió del banco el ${formatDay(fecha)}.`}
          detail={
            <p className="type-panel-body text-on-surface-variant">
              {parcial
                ? `Cubre parte de las ${settlementIds.length} liquidaciones marcadas, de la más antigua a la más nueva. La última que alcance queda parcial y lo que falte sigue saliendo como atrasado en los pagos de los días siguientes.`
                : `Cubre ${settlementIds.length} ${settlementIds.length === 1 ? 'liquidación' : 'liquidaciones'} por completo.`}{' '}
              {desglose &&
                !parcial &&
                `Son ${formatUsd(desglose.consultasUsd)} de consultas y ${formatUsd(desglose.comisionesUsd)} de comisiones del personal, que la clínica le entrega a quien registró cada financiamiento. `}
              {conBolivares && lasPartes && `En bolívares van ${lasPartes}. `}
              Al confirmar se escribe el asiento en el libro y baja «Por pagar a clínicas».
              {comprobante && ' El comprobante se guarda con el pago.'}
            </p>
          }
          nivel="sensible"
          reasonLabel="Motivo"
          reasonPlaceholder="Pago de hoy, desde la cuenta del banco"
          confirmLabel={`Registrar ${formatUsd(dolares)}`}
          busy={mutation.isPending}
          error={mutation.isError ? describeError(mutation.error) : undefined}
          onConfirm={(motivo) => mutation.mutate(motivo)}
          onClose={() => {
            setConfirmando(false)
            mutation.reset()
          }}
        />
      )}
    </Card>
  )
}
