import { createFileRoute } from '@tanstack/react-router'

import { Guia, cabeceraDeGuia } from '@/components/portada/Guia'

/** `/consulta-medica-en-cuotas` — página para buscadores. El texto, en `components/portada/guias.ts`. */
export const Route = createFileRoute('/consulta-medica-en-cuotas')({
  head: () => cabeceraDeGuia('/consulta-medica-en-cuotas'),
  component: () => <Guia ruta="/consulta-medica-en-cuotas" />,
})
