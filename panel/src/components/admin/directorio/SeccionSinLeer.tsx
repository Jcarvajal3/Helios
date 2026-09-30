import { ErrorConReintento } from '@/components/admin/ErrorConReintento'

/**
 * Una sección que no se pudo leer, con la causa y su botón de reintentar.
 *
 * Es lo contrario de esconderla: una sección que desaparece cuando su
 * consulta falla se lee como «no hay nada», y en Cuentas relacionadas o en
 * lo que se le debe a un local eso es justo lo que no se puede dar por bueno.
 *
 * Es el mismo aviso que `ErrorConReintento`, con «Reintentar» a su altura;
 * el nombre se queda porque lo usan las fichas y las listas del directorio.
 */
export function SeccionSinLeer({
  titulo,
  error,
  onReintentar,
}: {
  titulo: string
  error: unknown
  onReintentar: () => void
}) {
  return <ErrorConReintento title={titulo} error={error} onReintentar={onReintentar} />
}
