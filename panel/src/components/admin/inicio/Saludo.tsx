import { useCuentaDelPanel } from '@/components/layouts/cuenta'
import { horaYMinutoDeCaracas } from './reloj'
import { saludo } from './saludoDelDia'
import { useAhora } from './useAhora'

/**
 * «Buenas tardes, Javier»: el título de Inicio, encima de la barra. Va con
 * la hora de Caracas y no con la del navegador, como todo el panel.
 */
export function Saludo({ id }: { id?: string }) {
  const ahora = useAhora()
  const nombre = useCuentaDelPanel()?.nombreDePila ?? null

  return (
    <h1 id={id} className="text-balance text-center type-panel-greeting text-on-surface">
      {saludo(horaYMinutoDeCaracas(ahora).hora, nombre)}
    </h1>
  )
}
