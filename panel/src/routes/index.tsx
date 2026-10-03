import { createFileRoute } from '@tanstack/react-router'

import {
  Clinicas,
  ComoFunciona,
  Heroe,
  Menu,
  Pie,
  Preguntas,
  Reglas,
} from '@/components/portada'

/**
 * LA PORTADA — `/`.
 *
 * Una versión corta de la de Ronda: le habla al paciente, que no tiene app ni
 * cuenta y solo necesita saber qué es, cómo se usa y cuáles son las reglas.
 * El personal de la clínica entra por "Entrar", que lleva a `/login`. Todo el
 * texto vive en `components/portada.tsx`.
 */
const TITULO = 'Helios — Tu consulta hoy, págala en dos semanas'

const DESCRIPCION =
  'En las clínicas afiliadas, pides pagar con Helios en recepción y la consulta se divide en dos cuotas: una a los 7 días y otra a los 14. Hoy no pagas nada.'

export const Route = createFileRoute('/')({
  component: Portada,
  head: () => ({
    meta: [
      { title: TITULO },
      { name: 'description', content: DESCRIPCION },
      { property: 'og:type', content: 'website' },
      { property: 'og:title', content: TITULO },
      { property: 'og:description', content: DESCRIPCION },
    ],
  }),
})

/**
 *   Heroe        qué es         → "tu consulta hoy, en dos cuotas"
 *   ComoFunciona ¿cómo se usa?  → tres pasos, el primero en recepción
 *   Reglas       ¿y la trampa?  → las seis reglas, escritas
 *   Preguntas    lo que queda
 *   Clinicas     la tarjeta para la clínica
 */
function Portada() {
  return (
    <div className="portada-raiz min-h-screen bg-shell-canvas">
      <Menu />
      <main>
        <Heroe />
        <ComoFunciona />
        <Reglas />
        <Preguntas />
        <Clinicas />
      </main>
      <Pie />
    </div>
  )
}
