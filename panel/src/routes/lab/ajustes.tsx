import { createFileRoute } from '@tanstack/react-router'

import { AjustesLab } from '@/components/lab/admin/ajustes/AjustesLab'

export const Route = createFileRoute('/lab/ajustes')({
  staticData: { title: 'Ajustes de Helios Lab' },
  component: AjustesLab,
})
