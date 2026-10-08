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
import { ESPECIALIDADES, PREGUNTAS } from '@/components/portada/datos'
import { RESPONSABLE } from '@/config/legal'
import { NOMBRE, REDES, SITIO_URL, cabeceraPublica, jsonLd, urlAbsoluta } from '@/config/sitio'

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
// Google corta el título hacia los 60 caracteres y la descripción hacia los
// 155: lo que importa va delante.
const TITULO = 'Tu salud hoy, en dos cuotas | Helios Venezuela'

const DESCRIPCION =
  'Paga tu consulta de medicina, odontología o cosmetología en dos cuotas, a los 7 y 14 días, sin inicial. En bolívares, por Pago Móvil o transferencia.'

const FUENTES =
  'https://fonts.googleapis.com/css2?family=Geist:wght@300..700&family=Geist+Mono:wght@400;500&family=Instrument+Serif:ital@0;1&display=swap'

/**
 * Lo que el buscador entiende de la página sin leerla: quién opera Helios,
 * el servicio y las preguntas frecuentes (las mismas de la sección).
 */
const DATOS_ESTRUCTURADOS = {
  '@context': 'https://schema.org',
  '@graph': [
    {
      '@type': 'Organization',
      '@id': `${SITIO_URL}/#organizacion`,
      name: NOMBRE,
      legalName: RESPONSABLE.razonSocial,
      url: urlAbsoluta('/'),
      logo: urlAbsoluta('/icon-512.png'),
      areaServed: { '@type': 'Country', name: 'Venezuela' },
      sameAs: REDES.map((r) => r.url),
    },
    {
      '@type': 'WebSite',
      '@id': `${SITIO_URL}/#sitio`,
      name: NOMBRE,
      url: urlAbsoluta('/'),
      inLanguage: 'es-VE',
      publisher: { '@id': `${SITIO_URL}/#organizacion` },
    },
    {
      '@type': 'Service',
      name: 'Pago en cuotas de consultas y tratamientos de salud privada',
      serviceType: 'Pago en cuotas',
      description: DESCRIPCION,
      provider: { '@id': `${SITIO_URL}/#organizacion` },
      areaServed: { '@type': 'Country', name: 'Venezuela' },
      audience: ESPECIALIDADES.map((e) => ({ '@type': 'Audience', audienceType: e })),
    },
    {
      '@type': 'FAQPage',
      mainEntity: PREGUNTAS.map((p) => ({
        '@type': 'Question',
        name: p.pregunta,
        acceptedAnswer: { '@type': 'Answer', text: p.respuesta },
      })),
    },
  ],
}

export const Route = createFileRoute('/')({
  component: Portada,
  head: () => {
    const base = cabeceraPublica({ titulo: TITULO, descripcion: DESCRIPCION, ruta: '/' })
    return {
      meta: [...base.meta, { name: 'color-scheme', content: 'light' }],
      links: [...base.links, { rel: 'stylesheet', href: FUENTES }],
      scripts: [jsonLd(DATOS_ESTRUCTURADOS)],
    }
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
