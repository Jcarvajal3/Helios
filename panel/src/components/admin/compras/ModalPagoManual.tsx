import { useRef, useState } from 'react'
import { keepPreviousData, useMutation, useQuery } from '@tanstack/react-query'

import { AdjuntarComprobante } from '@/components/admin/caja/AdjuntarComprobante'
import {
  Button,
  Callout,
  ErrorBox,
  Input,
  Modal,
  Select,
  Textarea,
  diaOperativo,
  formatBcvRate,
  formatDay,
  formatUsd,
  formatVes,
} from '@/components/ui'
import { BANKS } from '@/features/admin/banks'
import {
  registrarPagoCompra,
  subirComprobanteCompra,
} from '@/features/admin/compras/api'
import { consultaPrevisionPagoCompra } from '@/features/admin/compras/consultas'
import { METODOS_PAGO_COMPRA } from '@/features/admin/compras/estados'
import type {
  MetodoPagoCompra,
  SolicitudCompraResumen,
} from '@/features/admin/compras/tipos'
import { valorDe } from '@/features/admin/parametros'
import {
  diferenciaEnBs,
  motivoDeArchivo,
} from '@/features/admin/pagosRegistrados/registrarPago'
import type { MargenBs } from '@/features/admin/pagosRegistrados/registrarPago'
import { useParametros } from '@/features/admin/useParametros'
import { leerMonto } from '@/lib/montos'
import { describeError } from '@/lib/supabase'

/** Registro manual de un pago: el equipo carga el comprobante que el médico mandó por fuera. */
export function ModalPagoManual({
  request,
  onClose,
  onRegistrado,
}: {
  request: SolicitudCompraResumen
  onClose: () => void
  onRegistrado: () => void
}) {
  const hoy = diaOperativo()
  const parametros = useParametros()
  const [metodo, setMetodo] = useState<MetodoPagoCompra>('pago_movil')
  const [banco, setBanco] = useState('')
  const [referencia, setReferencia] = useState('')
  const [pagadoEl, setPagadoEl] = useState(hoy)
  const [telefonoPagador, setTelefonoPagador] = useState(request.phone)
  const [montoBs, setMontoBs] = useState('')
  const [archivo, setArchivo] = useState<File | null>(null)
  const [nota, setNota] = useState('')
  // La captura se sube una sola vez: si la RPC falla, el reintento reutiliza esta ruta.
  const subida = useRef<{ file: File; ruta: string } | null>(null)

  const fechaValida = pagadoEl !== '' && pagadoEl <= hoy
  const prevision = useQuery({
    ...consultaPrevisionPagoCompra(request.id, pagadoEl),
    enabled: fechaValida,
    placeholderData: keepPreviousData,
  })

  // El margen sale de los parámetros; si no están cargados no se promete un veredicto.
  const menosBs = valorDe(parametros.data, 'payment_margin_under_ves')
  const masBs = valorDe(parametros.data, 'payment_margin_over_ves')
  const margen: MargenBs | null =
    menosBs !== null && masBs !== null ? { menosBs, masBs } : null

  const escritoBs = leerMonto(montoBs)
  const esperadoBs = prevision.data?.expectedVes ?? null
  const tasa = prevision.data?.fxRate ?? null
  const diferencia = margen
    ? diferenciaEnBs(escritoBs, esperadoBs, tasa, margen)
    : null

  const faltan: string[] = []
  if (!banco) faltan.push('Elige el banco de origen.')
  if (referencia.trim().length < 4)
    faltan.push('Escribe la referencia del comprobante.')
  if (!fechaValida) faltan.push('La fecha no puede ser futura.')
  if (escritoBs === null || escritoBs <= 0)
    faltan.push('Escribe el monto en bolívares.')
  const errArchivo = archivo ? motivoDeArchivo(archivo) : null
  if (errArchivo) faltan.push(errArchivo)

  const registrar = useMutation({
    mutationFn: async () => {
      if (escritoBs === null) throw new Error('Escribe el monto en bolívares.')
      let ruta: string | null = null
      if (archivo) {
        if (subida.current?.file !== archivo) {
          subida.current = {
            file: archivo,
            ruta: await subirComprobanteCompra({
              carpeta: `compras/${request.id}`,
              file: archivo,
            }),
          }
        }
        ruta = subida.current.ruta
      }
      await registrarPagoCompra({
        requestId: request.id,
        method: metodo,
        bank: banco,
        reference: referencia,
        paidOn: pagadoEl,
        amountVes: escritoBs,
        receiptPath: ruta,
        payerPhone: telefonoPagador,
        note: nota,
      })
    },
    onSuccess: onRegistrado,
  })

  return (
    <Modal
      title={`Registrar pago manual · ${request.code}`}
      width="lg"
      onClose={onClose}
    >
      <div className="flex flex-col gap-4">
        {request.vencida && (
          <Callout tone="warning" titulo="La cotización está vencida">
            Puedes registrar el pago igualmente: es decisión tuya y queda
            marcado como pago sobre cotización vencida.
          </Callout>
        )}

        <div className="rounded-panel-control border border-panel-hairline bg-panel-raised p-4">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <span className="type-panel-body text-on-surface-variant">
              Total de la solicitud
            </span>
            <span className="type-panel-section tabular-nums text-on-surface">
              {formatUsd(request.totalUsd)}
            </span>
          </div>
          {prevision.isPending ? (
            <p className="mt-1 type-panel-caption text-on-surface-variant">
              Consultando tasa BCV del {formatDay(pagadoEl)}…
            </p>
          ) : prevision.isError ? (
            <p className="mt-1 type-panel-caption text-warning">
              No se pudo precalcular el monto en Bs:{' '}
              {describeError(prevision.error)}
            </p>
          ) : esperadoBs !== null && tasa !== null ? (
            <p className="mt-1 type-panel-caption text-on-surface-variant">
              Esperado al {formatDay(pagadoEl)}:{' '}
              <span className="font-semibold text-on-surface">
                {formatVes(esperadoBs)}
              </span>{' '}
              ({formatBcvRate(tasa)}).
            </p>
          ) : null}
        </div>

        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          <Select
            id="compra-pago-metodo"
            label="Medio de pago (bolívares)"
            value={metodo}
            options={METODOS_PAGO_COMPRA}
            onChange={setMetodo}
          />
          <Select
            id="compra-pago-banco"
            label="Banco origen"
            value={banco}
            placeholder="Elige el banco"
            options={BANKS.map((b) => ({ value: b.name, label: b.name }))}
            onChange={setBanco}
          />
          <Input
            id="compra-pago-referencia"
            label="Referencia"
            value={referencia}
            onChange={setReferencia}
            placeholder="Últimos 6–8 dígitos del comprobante"
            autoComplete="off"
          />
          <Input
            id="compra-pago-fecha"
            label="Fecha del pago"
            type="date"
            value={pagadoEl}
            onChange={setPagadoEl}
            max={hoy}
          />
          <Input
            id="compra-pago-monto"
            label="Monto en bolívares"
            value={montoBs}
            onChange={setMontoBs}
            inputMode="decimal"
            placeholder={esperadoBs !== null ? formatVes(esperadoBs) : 'Bs'}
            hint={
              diferencia === null || margen === null
                ? undefined
                : diferencia.cuadra
                  ? `Dentro del margen (−${margen.menosBs} / +${margen.masBs} Bs): diferencia ${diferencia.bs >= 0 ? '+' : '−'}${formatVes(Math.abs(diferencia.bs))}.`
                  : `Fuera del margen: diferencia ${diferencia.bs >= 0 ? '+' : '−'}${formatVes(Math.abs(diferencia.bs))} (≈ ${formatUsd(Math.abs(diferencia.usd))}).`
            }
            error={diferencia !== null && !diferencia.cuadra}
          />
          <Input
            id="compra-pago-telefono"
            label="Teléfono del pagador (opcional)"
            value={telefonoPagador}
            onChange={setTelefonoPagador}
            placeholder="0414-1234567"
            inputMode="tel"
          />
        </div>

        <AdjuntarComprobante
          id="compra-pago-captura"
          file={archivo}
          onChange={setArchivo}
        />

        <Textarea
          id="compra-pago-nota"
          label="Nota (opcional)"
          value={nota}
          onChange={setNota}
          rows={2}
          maxLength={300}
          placeholder="Comprobante recibido por WhatsApp del Dr."
        />

        {registrar.isError && (
          <ErrorBox
            title="No se pudo registrar el pago"
            detail={describeError(registrar.error)}
          />
        )}

        <div className="flex flex-wrap gap-2">
          <Button
            size="md"
            disabled={faltan.length > 0 || registrar.isPending}
            motivoApagado={faltan[0]}
            onClick={() => registrar.mutate()}
          >
            {registrar.isPending ? 'Registrando…' : 'Registrar pago'}
          </Button>
          <Button size="md" variant="text" onClick={onClose}>
            Cancelar
          </Button>
        </div>
      </div>
    </Modal>
  )
}
