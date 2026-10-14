import { createFileRoute } from '@tanstack/react-router'

import { Guia, cabeceraDeGuia } from '@/components/portada/Guia'

/** `/cosmetologia-en-cuotas` — página para buscadores. El texto, en `components/portada/guias.ts`. */
export const Route = createFileRoute('/cosmetologia-en-cuotas')({
  head: () => cabeceraDeGuia('/cosmetologia-en-cuotas'),
  component: () => <Guia ruta="/cosmetologia-en-cuotas" />,
})
