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
import { PREGUNTAS } from '@/components/portada/datos'
import { cabeceraPublica, preguntasFrecuentes, servicio } from '@/config/sitio'

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
 * Instrument Serif), que comparte con las páginas para buscadores (`Guia`).
 */
const TITULO = 'Consultas médicas en cuotas, sin inicial | Helios Venezuela'

const DESCRIPCION =
  'Paga tu consulta de medicina, odontología o cosmetología en 2 cuotas, a los 7 y 14 días, sin inicial. El médico cobra el 100%, pague o no el paciente.'

/**
 * Lo que el buscador entiende de la página sin leerla, además de quién es
 * Helios (eso lo pone `cabeceraPublica`): el servicio visto por cada público
 * y las preguntas frecuentes (las mismas de la sección).
 */
const DATOS_ESTRUCTURADOS = [
  servicio({
    ruta: '/pacientes',
    nombre: 'Pago de consultas de salud en dos cuotas',
    descripcion:
      'Consultas y tratamientos de medicina, odontología y cosmetología en dos cuotas, a los 7 y 14 días, sin inicial, pagadas en bolívares por Pago Móvil o transferencia.',
    publico: 'Patient',
  }),
  servicio({
    ruta: '/medicos',
    nombre: 'Pago en cuotas para consultorios y centros de salud',
    descripcion:
      'El médico o centro de salud recibe el 100% de cada consulta a los 8 y 15 días, pague o no el paciente. Sin costo ni permanencia.',
    publico: 'Clinician',
  }),
  preguntasFrecuentes('/', PREGUNTAS),
]

export const Route = createFileRoute('/')({
  component: Portada,
  head: () => {
    const base = cabeceraPublica({
      titulo: TITULO,
      descripcion: DESCRIPCION,
      ruta: '/',
      datos: DATOS_ESTRUCTURADOS,
      aspecto: 'portada',
    })
    return { ...base, meta: [...base.meta, { name: 'color-scheme', content: 'light' }] }
  },
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
