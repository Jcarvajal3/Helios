import { createFileRoute } from '@tanstack/react-router'

import { Guia, cabeceraDeGuia } from '@/components/portada/Guia'

/** `/odontologia-en-cuotas` — página para buscadores. El texto, en `components/portada/guias.ts`. */
export const Route = createFileRoute('/odontologia-en-cuotas')({
  head: () => cabeceraDeGuia('/odontologia-en-cuotas'),
  component: () => <Guia ruta="/odontologia-en-cuotas" />,
})
