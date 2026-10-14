import { useMutation } from '@tanstack/react-query'

import { useToast } from '@/components/Toast'
import { descargarCsv } from '@/lib/csv'
import { describeError } from '@/lib/supabase'
import { leerDatosDeContratos } from './api'
import { archivoDeContrato, csvDeContratos } from './contrato'

type Pedido =
  /** Las de la lista, con su filtro: `ids` son las que se ven. */
  | { de: 'lista'; ids: ReadonlyArray<string> }
  | { de: 'ficha'; id: string; nombre: string }

/**
 * Bajar en CSV los datos de alta para el contrato: los de las clínicas de la
 * lista (con el filtro de ahora, como «Exportar CSV») o los de una (el «⋯»
 * de su ficha).
 *
 * Se leen al pulsar y no antes: son datos bancarios y de identidad que la
 * pantalla no enseña, así que no se piden si nadie los va a bajar.
 */
export function useDatosDeContrato() {
  const avisar = useToast()

  const mutation = useMutation({
    mutationFn: async (pedido: Pedido) => {
      if (pedido.de === 'ficha') return leerDatosDeContratos(pedido.id)
      const ids = new Set(pedido.ids)
      return (await leerDatosDeContratos()).filter((d) => ids.has(d.merchantId))
    },
    onSuccess: (filas, pedido) => {
      descargarCsv(archivoDeContrato(pedido.de === 'ficha' ? pedido.nombre : undefined), csvDeContratos(filas))
      avisar(
        pedido.de === 'ficha'
          ? `Datos de alta de ${pedido.nombre} descargados`
          : `Datos de alta de ${filas.length} ${filas.length === 1 ? 'clínica' : 'clínicas'} descargados`,
      )
    },
  })

  return {
    descargar: (pedido: Pedido) => mutation.mutate(pedido),
    pendiente: mutation.isPending,
    error: mutation.isError ? (describeError(mutation.error) ?? 'Inténtalo de nuevo.') : null,
  }
}
