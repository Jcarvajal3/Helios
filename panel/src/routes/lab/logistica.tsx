import { createFileRoute } from '@tanstack/react-router'

import { LogisticaDeLab } from '@/components/lab/admin/operacion/Logistica'

export const Route = createFileRoute('/lab/logistica')({
  staticData: { title: 'Logística', width: 'wide' },
  component: LogisticaDeLab,
})
