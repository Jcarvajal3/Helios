import { createFileRoute } from '@tanstack/react-router'

import { Guia, cabeceraDeGuia, cargarMedicosDeGuia } from '@/components/portada/Guia'

/** `/odontologia-en-cuotas` — página para buscadores. El texto, en `components/portada/guias.ts`. */
export const Route = createFileRoute('/odontologia-en-cuotas')({
  // Los médicos del directorio de su especialidad (la franja y sus tarjetas).
  loader: () => cargarMedicosDeGuia('/odontologia-en-cuotas'),
  staleTime: 60_000,
  head: () => cabeceraDeGuia('/odontologia-en-cuotas'),
  component: () => <Guia ruta="/odontologia-en-cuotas" medicos={Route.useLoaderData()} />,
})
