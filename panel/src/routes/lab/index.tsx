import { createFileRoute } from '@tanstack/react-router'

import { Resumen } from '@/components/lab/admin/resumen/Resumen'

export const Route = createFileRoute('/lab/')({
  staticData: { title: 'Resumen', width: 'wide' },
  component: Resumen,
})
