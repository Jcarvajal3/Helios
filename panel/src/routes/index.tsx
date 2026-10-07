import { createFileRoute } from '@tanstack/react-router'

import {
  Cierre,
  Cifras,
  ComoFunciona,
  Heroe,
  Manifiesto,
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
 * `components/portada/datos.ts`.
 *
 * La portada va SIEMPRE en claro: no lee los tokens del tema del panel
 * (que cambian con `data-theme`) sino su propia paleta fija, la de
 * `styles/portada.css`. Trae además su tipografía (Geist, Geist Mono e
 * Instrument Serif), que solo se descarga aquí.
 */
const TITULO = 'Helios — Tu consulta hoy, págala en dos cuotas'

const DESCRIPCION =
  'Helios es una forma de pagar consultas y tratamientos de salud privada en cuotas: medicina, odontología y cosmetología. Dos cuotas, a los 7 y a los 14 días, con una comisión de servicio del 12% + IVA.'

const FUENTES =
  'https://fonts.googleapis.com/css2?family=Geist:wght@300..700&family=Geist+Mono:wght@400;500&family=Instrument+Serif:ital@0;1&display=swap'

export const Route = createFileRoute('/')({
  component: Portada,
  head: () => ({
    meta: [
      { title: TITULO },
      { name: 'description', content: DESCRIPCION },
      { name: 'color-scheme', content: 'light' },
      { property: 'og:type', content: 'website' },
      { property: 'og:title', content: TITULO },
      { property: 'og:description', content: DESCRIPCION },
    ],
    links: [{ rel: 'stylesheet', href: FUENTES }],
  }),
})

function Portada() {
  return (
    <div className="portada-raiz min-h-screen">
      <Menu />
      <main>
        <Heroe />
        <Cifras />
        <Manifiesto />
        <ComoFunciona />
        <Medicos />
        <Pacientes />
        <Preguntas />
        <Cierre />
      </main>
      <Pie />
    </div>
  )
}
