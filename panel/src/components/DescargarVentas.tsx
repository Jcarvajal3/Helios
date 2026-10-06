import { useState } from 'react'
import { useMutation } from '@tanstack/react-query'
import { Download } from 'lucide-react'

import { useToast } from '@/components/Toast'
import { Button, CampoDeRango, ConfirmDialog } from '@/components/ui'
import { QUE_LLEVA, descargarVentas } from '@/features/merchant/salesExport'
import { describeError } from '@/lib/supabase'

/**
 * Llevarse las ventas a contabilidad.
 *
 * Es un CSV y no un `.xlsx`. No es una rebaja: se abre en Excel con doble
 * clic, y lo hace bien porque va con punto y coma, coma decimal y BOM —las
 * tres cosas que espera un Excel con la configuración de Venezuela—. Generar
 * un xlsx de verdad significaría meter una librería de medio megabyte en el
 * bundle de una tablet para producir el mismo contenido en un archivo que
 * Sheets, Numbers y cualquier contaduría abren peor.
 *
 * El rango sale de la pantalla: lo que se descarga es lo que se está viendo,
 * y por eso no hay un segundo par de fechas que puedan contradecir al de
 * arriba. Se enseñan para poder corregirlas sin cerrar el diálogo.
 */
export function DescargarVentas({
  from,
  to,
  merchantName,
  onRange,
}: {
  from: string
  to: string
  merchantName: string
  /** Cambiar las fechas aquí mueve también la tabla de detrás: son el mismo
   *  rango, y dos rangos distintos en la misma pantalla es una trampa. */
  onRange: (range: { from: string; to: string }) => void
}) {
  const avisar = useToast()
  const [abierto, setAbierto] = useState(false)

  const descarga = useMutation({
    mutationFn: () => descargarVentas({ from, to, merchantName }),
    onSuccess: (filas) => {
      setAbierto(false)
      avisar(
        filas === 0
          ? 'No hay pagos en cuotas en ese rango: el archivo va vacío'
          : `${filas} ${filas === 1 ? 'fila descargada' : 'filas descargadas'}`,
      )
    },
  })

  const alReves = from > to

  return (
    <>
      <Button size="md" variant="tonal" onClick={() => setAbierto(true)}>
        <Download size={16} />
        Descargar
      </Button>

      {abierto && (
        <ConfirmDialog
          title="Descargar para contabilidad"
          summary="Un archivo CSV que se abre en Excel con doble clic. Lleva el desglose completo de cada pago en cuotas: base, IVA, comisiones y cuándo te pagamos."
          detail={
            <div className="flex flex-col gap-4">
              <p className="type-panel-body leading-5 text-on-surface-variant">{QUE_LLEVA}</p>

              <CampoDeRango
                id="descarga-fechas"
                label="Fechas (día operativo)"
                rango={{ from, to }}
                onChange={onRange}
                error={alReves}
              />

              <p className="type-panel-body leading-5 text-on-surface-variant">
                Las fechas son <strong>días operativos</strong>: de medianoche a medianoche,
                hora de Caracas.
              </p>
            </div>
          }
          confirmLabel="Descargar"
          bloqueo={alReves ? 'El rango está al revés' : undefined}
          busy={descarga.isPending}
          error={descarga.isError ? describeError(descarga.error) : undefined}
          onConfirm={() => descarga.mutate()}
          onClose={() => setAbierto(false)}
        />
      )}
    </>
  )
}
