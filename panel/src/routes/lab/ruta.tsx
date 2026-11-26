import { createFileRoute } from '@tanstack/react-router'

import { RutaDelDia } from '@/components/lab/admin/operacion/RutaDelDia'

export const Route = createFileRoute('/lab/ruta')({
  staticData: { title: 'Ruta del día', width: 'normal' },
  component: RutaDelDia,
})
