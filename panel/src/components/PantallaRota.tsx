import type { ErrorComponentProps } from '@tanstack/react-router'

import { Button, ErrorBox } from '@/components/ui'
import { describeError } from '@/lib/supabase'

/**
 * Lo que se ve cuando una pantalla revienta al pintarse. El router lo pone en
 * el hueco de la ruta rota, así que la barra lateral sigue ahí y se puede
 * saltar a otra sección.
 *
 * Recarga la página entera en vez de reintentar la ruta: un fallo de pintado
 * vuelve a salir idéntico con los mismos datos en memoria.
 */
export function PantallaRota({ error }: ErrorComponentProps) {
  return (
    <div className="flex flex-col gap-[var(--spacing-shell-gap-stack)] p-[var(--spacing-panel-pad-card)]">
      <ErrorBox title="No se pudo mostrar esta pantalla" detail={describeError(error)} />
      <div>
        <Button size="md" onClick={() => window.location.reload()}>
          Volver a cargar
        </Button>
      </div>
    </div>
  )
}
