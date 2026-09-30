import { createFileRoute, redirect } from '@tanstack/react-router'

/**
 * `/` no tiene portada: Helios no tiene app ni público al que hablarle. Quien
 * llega a la raíz va al login, y el login lo reparte a su panel (el de la
 * clínica o el del equipo) según sea personal de una clínica o de Helios.
 */
export const Route = createFileRoute('/')({
  beforeLoad: () => {
    throw redirect({ to: '/login' })
  },
})
