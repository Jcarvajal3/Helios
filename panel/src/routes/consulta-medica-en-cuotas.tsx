import { createFileRoute } from '@tanstack/react-router'

import { Guia, cabeceraDeGuia, cargarMedicosDeGuia } from '@/components/portada/Guia'

/** `/consulta-medica-en-cuotas` — página para buscadores. El texto, en `components/portada/guias.ts`. */
export const Route = createFileRoute('/consulta-medica-en-cuotas')({
  // Los médicos del directorio de su especialidad (la franja y sus tarjetas).
  loader: () => cargarMedicosDeGuia('/consulta-medica-en-cuotas'),
  staleTime: 60_000,
  head: () => cabeceraDeGuia('/consulta-medica-en-cuotas'),
  component: () => <Guia ruta="/consulta-medica-en-cuotas" medicos={Route.useLoaderData()} />,
})
