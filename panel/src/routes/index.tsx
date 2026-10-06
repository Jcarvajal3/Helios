import { createFileRoute } from '@tanstack/react-router'

import {
  ComoFunciona,
  Heroe,
  Medicos,
  Menu,
  Pacientes,
  Pie,
  Preguntas,
} from '@/components/portada'

/**
 * LA PORTADA — `/`.
 *
 * Le habla a los dos públicos de Helios: el médico o centro que se afilia y
 * el paciente que paga en cuotas. Los médicos y su personal entran por
 * "Entrar", que lleva a `/login`. Todo el texto vive en
 * `components/portada.tsx`.
 */
const TITULO = 'Helios — Tu consulta hoy, págala en dos cuotas'

const DESCRIPCION =
  'Helios es una forma de pagar consultas y tratamientos de salud privada en cuotas: medicina, odontología y cosmetología. Dos cuotas, a los 7 y a los 14 días, con una comisión de servicio del 12% + IVA.'

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
 *   Heroe        qué es         → salud privada en cuotas, y un ejemplo
 *   ComoFunciona ¿cómo se usa?  → registra el médico, confirma el paciente, dos cuotas
 *   Medicos      para médicos   → pago garantizado a los 8 y 15 días, «Quiero afiliarme»
 *   Pacientes    para pacientes → 7 y 14 días, comisión del 12%, límite de $150
 *   Preguntas    lo que queda
 */
function Portada() {
  return (
    <div className="portada-raiz min-h-screen bg-shell-canvas">
      <Menu />
      <main>
        <Heroe />
        <ComoFunciona />
        <Medicos />
        <Pacientes />
        <Preguntas />
      </main>
      <Pie />
    </div>
  )
}
