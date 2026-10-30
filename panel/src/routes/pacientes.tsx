import { createFileRoute } from '@tanstack/react-router'

import { Guia, cabeceraDeGuia, cargarMedicosDeGuia } from '@/components/portada/Guia'

/** `/pacientes` — página para buscadores. El texto, en `components/portada/guias.ts`. */
export const Route = createFileRoute('/pacientes')({
  // Los médicos del directorio de su especialidad (la franja y sus tarjetas).
  loader: () => cargarMedicosDeGuia('/pacientes'),
  staleTime: 60_000,
  head: () => cabeceraDeGuia('/pacientes'),
  component: () => <Guia ruta="/pacientes" medicos={Route.useLoaderData()} />,
})
