import { createFileRoute } from '@tanstack/react-router'

import { Guia, cabeceraDeGuia } from '@/components/portada/Guia'

/** `/pacientes` — página para buscadores. El texto, en `components/portada/guias.ts`. */
export const Route = createFileRoute('/pacientes')({
  head: () => cabeceraDeGuia('/pacientes'),
  component: () => <Guia ruta="/pacientes" />,
})
