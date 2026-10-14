import { useState } from 'react'
import { queryOptions, useQuery } from '@tanstack/react-query'
import { Download } from 'lucide-react'

import { Badge, Button, ErrorBox, Input, SkeletonTable, formatDay, formatUsd, formatVes, hoyCaracas } from '@/components/ui'
import { Callout } from '@/components/kit/Callout'
import { Modal } from '@/components/overlays'
import { llamarRpc } from '@/features/admin/metricas/consulta'
import {
  MAX_DESCRIPCION,
  bloqueoDelPagoMasivo,
  cuentaDelBanco,
  descripcionPorDefecto,
  leerHojaDePagoMasivo,
  llenarPlantilla,
  nombreDelArchivo,
  repartirPagoMasivo,
} from '@/features/admin/pagoMasivo'
import plantillaUrl from '@/features/admin/plantilla-pago-masivo.xlsm?url'
import { describeError } from '@/lib/supabase'

/** La última cuenta a debitar que se usó, en este navegador. */
const CLAVE_CUENTA = 'helios.pago-masivo.cuenta-debito'

function cuentaGuardada(): string {
  try {
    return window.localStorage.getItem(CLAVE_CUENTA) ?? ''
  } catch {
    return ''
  }
}

function guardarCuenta(cuenta: string) {
  try {
    window.localStorage.setItem(CLAVE_CUENTA, cuenta)
  } catch {
    // Sin almacenamiento, la próxima vez se vuelve a escribir.
  }
}

function consultaPagoMasivo() {
  return queryOptions({
    queryKey: ['admin-bulk-payout-sheet'],
    queryFn: ({ signal }) => llamarRpc('admin_bulk_payout_sheet', {}, { signal, leer: leerHojaDePagoMasivo }),
  })
}

/** «0191 •••• 0001»: la cuenta, sin enseñarla entera. */
function cuentaCorta(cuenta: string | null): string {
  return cuenta ? `${cuenta.slice(0, 4)} •••• ${cuenta.slice(-4)}` : '—'
}

/**
 * «Archivo del banco»: el .xlsm del pago masivo a proveedores con lo que se
 * le debe hoy a cada clínica, en bolívares, por transferencia.
 *
 * Sustituye al «Exportar CSV» de «Por pagar». Bajar el archivo no registra
 * nada: cuando el banco procese el pago, cada transferencia se registra en
 * la página de su clínica, como siempre.
 */
export function ArchivoDelBanco() {
  const [abierto, setAbierto] = useState(false)

  return (
    <>
      <Button size="sm" variant="text" onClick={() => setAbierto(true)}>
        <Download size={15} aria-hidden />
        Archivo del banco
      </Button>
      {abierto && <VentanaDelArchivo onClose={() => setAbierto(false)} />}
    </>
  )
}

function VentanaDelArchivo({ onClose }: { onClose: () => void }) {
  const hoja = useQuery(consultaPagoMasivo())

  return (
    <Modal title="Archivo de pago masivo" onClose={onClose} width="lg">
      {hoja.isPending ? (
        <SkeletonTable rows={3} columns={4} />
      ) : hoja.isError ? (
        <ErrorBox title="No se pudo leer lo que se debe hoy" detail={describeError(hoja.error)} />
      ) : (
        <Formulario hoja={hoja.data} onClose={onClose} />
      )}
    </Modal>
  )
}

function Formulario({
  hoja,
  onClose,
}: {
  hoja: ReturnType<typeof leerHojaDePagoMasivo>
  onClose: () => void
}) {
  const hoy = hoyCaracas()
  const [cuentaDebito, setCuentaDebito] = useState(() => cuentaGuardada() || hoja.debitAccount?.accountNumber || '')
  const [fechaPago, setFechaPago] = useState(hoy)
  const [descripcion, setDescripcion] = useState(() => descripcionPorDefecto(hoy))
  const [bajando, setBajando] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const opciones = { cuentaDebito: cuentaDelBanco(cuentaDebito) ?? cuentaDebito, fechaPago, descripcion }
  const reparto = repartirPagoMasivo(hoja, opciones)
  const bloqueo = bloqueoDelPagoMasivo(opciones, hoy, reparto.dentro.length)

  async function bajar() {
    setBajando(true)
    setError(null)
    try {
      const respuesta = await fetch(plantillaUrl)
      if (!respuesta.ok) throw new Error(`No se pudo leer la plantilla del banco (${respuesta.status}).`)
      const plantilla = new Uint8Array(await respuesta.arrayBuffer())
      const archivo = llenarPlantilla(plantilla, reparto.dentro.map((d) => d.fila))

      const blob = new Blob([archivo as BlobPart], { type: 'application/vnd.ms-excel.sheet.macroEnabled.12' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = nombreDelArchivo(fechaPago)
      a.click()
      URL.revokeObjectURL(url)

      guardarCuenta(opciones.cuentaDebito)
      onClose()
    } catch (e) {
      setError(describeError(e) ?? 'Inténtalo otra vez.')
    } finally {
      setBajando(false)
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <p className="type-panel-body text-on-surface-variant">
        Lo que se le debe hoy a cada clínica (con lo atrasado), en bolívares a la tasa BCV de hoy, listo para
        cargar en el pago masivo a proveedores del banco. Solo va por transferencia.
      </p>

      <div className="grid gap-3 md:grid-cols-3">
        <Input
          id="pago-masivo-cuenta"
          label="Cuenta a debitar"
          value={cuentaDebito}
          onChange={setCuentaDebito}
          inputMode="numeric"
          autoComplete="off"
          placeholder="20 dígitos"
          error={cuentaDebito.trim() !== '' && !cuentaDelBanco(cuentaDebito)}
          hint={
            hoja.debitAccount && !cuentaGuardada()
              ? `La de cobro de ${hoja.debitAccount.bankName ?? 'Helios'}.`
              : 'La cuenta de Helios de la que sale el pago.'
          }
        />
        <Input
          id="pago-masivo-fecha"
          label="Fecha de pago"
          type="date"
          value={fechaPago}
          min={hoy}
          onChange={setFechaPago}
          error={fechaPago < hoy}
        />
        <Input
          id="pago-masivo-descripcion"
          label="Descripción"
          value={descripcion}
          onChange={setDescripcion}
          error={descripcion.trim().length > MAX_DESCRIPCION}
          hint={`${descripcion.trim().length}/${MAX_DESCRIPCION}`}
        />
      </div>

      {reparto.dentro.length > 0 && (
        <div className="overflow-x-auto rounded-panel-control border border-panel-hairline">
          <table className="w-full type-panel-body">
            <thead className="text-left type-panel-label text-on-surface-variant">
              <tr>
                <th className="px-3 py-2 font-normal">Clínica</th>
                <th className="px-3 py-2 font-normal">Titular</th>
                <th className="px-3 py-2 font-normal">Cuenta</th>
                <th className="px-3 py-2 text-right font-normal">Monto</th>
              </tr>
            </thead>
            <tbody>
              {reparto.dentro.map(({ clinica, fila }) => (
                <tr key={clinica.merchantId} className="border-t border-panel-hairline">
                  <td className="px-3 py-2 text-on-surface">{clinica.merchantName}</td>
                  <td className="px-3 py-2 text-on-surface-variant">
                    {fila.nombreBeneficiario}
                    <span className="block type-panel-caption">{fila.idBeneficiario}</span>
                  </td>
                  <td className="px-3 py-2 whitespace-nowrap tabular-nums text-on-surface-variant">
                    {cuentaCorta(fila.cuentaBeneficiario)}
                  </td>
                  <td className="px-3 py-2 text-right whitespace-nowrap tabular-nums">
                    <span className="text-on-surface">{formatVes(fila.monto)}</span>
                    <span className="block type-panel-caption text-on-surface-variant">
                      {formatUsd(clinica.pendingUsd)}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {reparto.fuera.length > 0 && (
        <Callout
          tone="warning"
          titulo={`${reparto.fuera.length} ${reparto.fuera.length === 1 ? 'clínica no entra' : 'clínicas no entran'} en el archivo`}
          detalles={
            <ul className="flex flex-col gap-1">
              {reparto.fuera.map(({ clinica, motivo }) => (
                <li key={clinica.merchantId}>
                  <span className="text-on-surface">{clinica.merchantName}</span> ({formatUsd(clinica.pendingUsd)}):{' '}
                  {motivo}
                </li>
              ))}
            </ul>
          }
        >
          Hay que pagarles a mano desde su página o completar su cuenta de pago en la ficha.
        </Callout>
      )}

      {reparto.pruebas.length > 0 && (
        <p className="flex items-center gap-2 type-panel-caption text-on-surface-variant">
          <Badge tone="neutral">Prueba</Badge>
          {reparto.pruebas.length === 1 ? 'Una clínica de prueba queda' : `${reparto.pruebas.length} clínicas de prueba quedan`}{' '}
          fuera: no se les transfiere.
        </p>
      )}

      {error && <ErrorBox title="No se pudo armar el archivo" detail={error} />}

      <div className="flex flex-wrap items-center justify-between gap-4 rounded-panel-control bg-panel-raised p-4">
        <span className="type-panel-body text-on-surface-variant">
          {reparto.dentro.length} {reparto.dentro.length === 1 ? 'transferencia' : 'transferencias'} para el{' '}
          {formatDay(fechaPago)}
          {hoja.fxRateUsd !== null && (
            <span className="block type-panel-caption">
              BCV de hoy: {formatVes(hoja.fxRateUsd)} por dólar
              {hoja.fxRateEur !== null && ` · ${formatVes(hoja.fxRateEur)} por euro`}
            </span>
          )}
        </span>
        <span className="text-right">
          <span className="block type-panel-figure text-on-surface">{formatVes(reparto.totalVes)}</span>
          <span className="block type-panel-caption tabular-nums text-on-surface-variant">
            {formatUsd(reparto.totalUsd)}
          </span>
        </span>
      </div>

      <div className="flex flex-wrap items-start justify-end gap-3">
        <Button size="md" variant="text" onClick={onClose}>
          Cancelar
        </Button>
        <Button
          size="md"
          disabled={bloqueo !== null || bajando}
          motivoApagado={bloqueo ?? undefined}
          onClick={() => void bajar()}
        >
          <Download size={16} aria-hidden />
          {bajando ? 'Armando el archivo…' : 'Bajar el archivo (.xlsm)'}
        </Button>
      </div>

      <p className="type-panel-caption text-panel-muted">
        Bajar el archivo no mueve dinero ni registra nada. Cuando el banco procese el pago, registra cada
        transferencia en la página de su clínica.
      </p>
    </div>
  )
}
