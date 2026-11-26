import { createFileRoute } from '@tanstack/react-router'

import { InventarioDeLab } from '@/components/lab/admin/operacion/Inventario'

export const Route = createFileRoute('/lab/inventario')({
  staticData: { title: 'Inventario', width: 'wide' },
  component: InventarioDeLab,
})
