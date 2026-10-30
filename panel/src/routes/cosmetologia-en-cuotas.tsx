import { createFileRoute } from '@tanstack/react-router'

import { Guia, cabeceraDeGuia, cargarMedicosDeGuia } from '@/components/portada/Guia'

/** `/cosmetologia-en-cuotas` — página para buscadores. El texto, en `components/portada/guias.ts`. */
export const Route = createFileRoute('/cosmetologia-en-cuotas')({
  // Los médicos del directorio de su especialidad (la franja y sus tarjetas).
  loader: () => cargarMedicosDeGuia('/cosmetologia-en-cuotas'),
  staleTime: 60_000,
  head: () => cabeceraDeGuia('/cosmetologia-en-cuotas'),
  component: () => <Guia ruta="/cosmetologia-en-cuotas" medicos={Route.useLoaderData()} />,
})
