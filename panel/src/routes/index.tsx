import { createFileRoute } from '@tanstack/react-router'

import { useMemo } from 'react'

import { ParaMedicos } from '@/components/directorio/PaginaDelDirectorio'
import {
  Cierre,
  Cifras,
  ComoFunciona,
  Heroe,
  Manifiesto,
  Menu,
  Pacientes,
  Pie,
  Preguntas,
} from '@/components/portada'
import { Especialidades, MedicosDelDirectorio } from '@/components/portada/ParaElPaciente'
import { PREGUNTAS } from '@/components/portada/datos'
import { cargarDirectorio } from '@/features/directorio/api'
import { especialidadesPresentes } from '@/features/directorio/directorio'
import { cabeceraPublica, preguntasFrecuentes, servicio } from '@/config/sitio'

/**
 * LA PORTADA — `/`.
 *
 * Le habla al paciente (Javier, 2026-11-12): qué es, las especialidades y los
 * médicos del directorio, cómo funciona, lo que paga y las preguntas. Al
 * médico le queda una franja («¿Eres médico?») que lleva a `/medicos` y a la
 * afiliación; él y su personal entran por «Entrar» (`/login`). El texto vive
 * en `components/portada/datos.ts`.
 *
 * Carga el directorio (como las guías) para enseñar especialidades y médicos
 * de verdad; si no contesta, la página sale igual, sin esas dos secciones.
 *
 * La portada va SIEMPRE en claro: no lee los tokens del tema del panel
 * (que cambian con `data-theme`) sino su propia paleta fija, la de
 * `styles/portada.css`. Trae además su tipografía (Geist, Geist Mono e
 * Instrument Serif), que comparte con las páginas para buscadores (`Guia`).
 */
const TITULO = 'Consultas médicas en cuotas | Helios Venezuela'

const DESCRIPCION =
  'Paga tu consulta de medicina, odontología o cosmetología: el 50% el día de la consulta y el resto en 2 cuotas, a los 14 y 28 días. El médico cobra el 100%.'

/**
 * Lo que el buscador entiende de la página sin leerla, además de quién es
 * Helios (eso lo pone `cabeceraPublica`): el servicio visto por cada público
 * y las preguntas frecuentes (las mismas de la sección).
 */
const DATOS_ESTRUCTURADOS = [
  servicio({
    ruta: '/pacientes',
    nombre: 'Pago de consultas de salud en cuotas',
    descripcion:
      'Consultas y tratamientos de medicina, odontología y cosmetología: el 50% el día de la consulta y el resto en dos cuotas, a los 14 y 28 días, pagados en bolívares por Pago Móvil o transferencia.',
    publico: 'Patient',
  }),
  servicio({
    ruta: '/medicos',
    nombre: 'Pago en cuotas para consultorios y centros de salud',
    descripcion:
      'El médico o centro de salud recibe el 100% de cada consulta a los 8 y 15 días, pague o no el paciente sus cuotas. Sin costo ni permanencia.',
    publico: 'Clinician',
  }),
  preguntasFrecuentes('/', PREGUNTAS),
]

export const Route = createFileRoute('/')({
  component: Portada,
  staleTime: 60_000,
  loader: () => cargarDirectorio(),
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
  const { medicos, fallo, whatsappHelios } = Route.useLoaderData()
  const especialidades = useMemo(() => especialidadesPresentes(medicos), [medicos])
  const hayDirectorio = !fallo && medicos.length > 0

  return (
    <div className="portada-raiz min-h-screen">
      <Menu />
      <main>
        <Heroe />
        {hayDirectorio && <Especialidades especialidades={especialidades} total={medicos.length} />}
        <Cifras />
        <Manifiesto />
        <ComoFunciona />
        <Pacientes />
        {hayDirectorio && <MedicosDelDirectorio medicos={medicos} whatsappHelios={whatsappHelios} />}
        <Preguntas />
        <ParaMedicos />
        <Cierre />
      </main>
      <Pie />
    </div>
  )
}
