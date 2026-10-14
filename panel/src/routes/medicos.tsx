import { createFileRoute } from '@tanstack/react-router'

import { Guia, cabeceraDeGuia } from '@/components/portada/Guia'

/** `/medicos` — página para buscadores. El texto, en `components/portada/guias.ts`. */
export const Route = createFileRoute('/medicos')({
  head: () => cabeceraDeGuia('/medicos'),
  component: () => <Guia ruta="/medicos" />,
})
