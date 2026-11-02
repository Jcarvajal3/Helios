import { createFileRoute } from '@tanstack/react-router'

import { PaginaDeAlta } from '@/components/admin/directorio/AltaLocal'

/**
 * Dar de alta una clínica, en su propia página: se llena sobre todo desde el
 * móvil, en la visita al médico.
 */
export const Route = createFileRoute('/admin/clinicas_/alta')({
  staticData: { title: 'Dar de alta una clínica' },
  component: PaginaDeAlta,
})
