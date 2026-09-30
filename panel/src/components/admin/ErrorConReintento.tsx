import { Button, Callout } from '@/components/ui'
import { describeError } from '@/lib/supabase'

/**
 * Una lectura que falló, dicha entera y con la salida al lado.
 *
 * Es para lo que ocupa un bloque o una pestaña entera; para una cifra suelta
 * está `NoSePudoLeer` del kit. Sin el botón, quien lo ve solo puede recargar
 * la página y perder los filtros. Es un `Callout` de error con «Reintentar»
 * como acción, a la altura del aviso.
 */
export function ErrorConReintento({
  title,
  error,
  onReintentar,
}: {
  title: string
  error: unknown
  onReintentar: () => void
}) {
  return (
    <Callout
      tone="error"
      titulo={title}
      accion={
        <Button variant="tonal" size="sm" onClick={onReintentar}>
          Reintentar
        </Button>
      }
    >
      {describeError(error)}
    </Callout>
  )
}
