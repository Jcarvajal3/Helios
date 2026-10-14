import { RESPONSABLE } from './legal'
import { FUENTES_DE_LA_PORTADA, FUENTES_DEL_PANEL } from '@/lib/fuentes'

/**
 * EL SITIO PÚBLICO — dirección, metadatos y lo que leen los buscadores.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * La dirección pública es `https://conhelios.com`, sin www (en Vercel, el
 * www redirige aquí). Es fija a propósito: el `canonical`, `og:url`, la
 * imagen para compartir y el sitemap apuntan siempre a producción, también
 * desde una vista previa o en local. `VITE_SITIO_URL` la cambia, si algún
 * día hace falta.
 *
 * Las páginas públicas arman su `head` con `cabeceraPublica`, que además
 * pone el JSON-LD común (quién es Helios, el sitio, la página y su miga de
 * pan); las del panel llevan `NO_INDEXAR`. La auditoría SEO y lo que queda
 * por hacer fuera del código están en `docs/02-AUDITORIA-SEO.md`.
 */

export const SITIO_URL = (import.meta.env.VITE_SITIO_URL || 'https://conhelios.com').replace(
  /\/+$/,
  '',
)

export const NOMBRE = 'Helios'

/**
 * Cómo más se busca la marca. Google lo usa para el nombre del sitio en los
 * resultados y para entender que «Helios Salud» (el Instagram) es lo mismo.
 */
export const NOMBRES_ALTERNATIVOS = ['Helios Salud', 'Helios Venezuela'] as const

export const ESLOGAN = 'Tu salud hoy'

/** Los perfiles oficiales: el pie de la portada y el `sameAs` del JSON-LD. */
export const REDES = [
  { nombre: 'Instagram', url: 'https://www.instagram.com/helios.salud' },
] as const

/** 1200 × 630: lo que enseñan WhatsApp, Facebook, X y LinkedIn al compartir. */
export const IMAGEN_COMPARTIR = {
  ruta: '/compartir.jpg',
  ancho: 1200,
  alto: 630,
  alt: 'Helios — Tu salud hoy… Págala en dos cuotas.',
}

/**
 * Las páginas que se le ofrecen al buscador (`/sitemap.xml`), con la fecha
 * de su último cambio de contenido: Google solo se fía del `lastmod` si es
 * cierto, así que se toca a mano cuando cambia el texto de la página.
 */
export const PAGINAS_PUBLICAS = {
  '/': { actualizada: '2026-10-14' },
  '/pacientes': { actualizada: '2026-10-14' },
  '/medicos': { actualizada: '2026-10-14' },
  '/consulta-medica-en-cuotas': { actualizada: '2026-10-14' },
  '/odontologia-en-cuotas': { actualizada: '2026-10-14' },
  '/cosmetologia-en-cuotas': { actualizada: '2026-10-14' },
  '/afiliacion': { actualizada: '2026-10-14' },
  '/soporte': { actualizada: '2026-10-09' },
  '/legal/terminos': { actualizada: '2026-10-07' },
  '/legal/privacidad': { actualizada: '2026-10-07' },
} as const satisfies Record<string, { actualizada: string }>

export type RutaPublica = keyof typeof PAGINAS_PUBLICAS

export function urlAbsoluta(ruta: string): string {
  return `${SITIO_URL}${ruta === '/' ? '/' : ruta}`
}

/** El panel, el login y el superadmin no salen en Google, y llevan las fuentes del panel. */
export const NO_INDEXAR = {
  meta: [{ name: 'robots', content: 'noindex, nofollow' }],
  links: [FUENTES_DEL_PANEL],
}

const ID_ORGANIZACION = `${SITIO_URL}/#organizacion`
const ID_SITIO = `${SITIO_URL}/#sitio`

/** Quién opera Helios y el sitio: van en el JSON-LD de todas las páginas públicas. */
const ORGANIZACION = {
  '@type': 'Organization',
  '@id': ID_ORGANIZACION,
  name: NOMBRE,
  alternateName: [...NOMBRES_ALTERNATIVOS],
  legalName: RESPONSABLE.razonSocial,
  slogan: ESLOGAN,
  description:
    'Helios permite pagar consultas y tratamientos de salud privada en Venezuela en dos cuotas, sin inicial, en consultorios y centros de medicina, odontología y cosmetología afiliados.',
  url: urlAbsoluta('/'),
  logo: { '@type': 'ImageObject', url: urlAbsoluta('/icon-512.png'), width: 512, height: 512 },
  image: urlAbsoluta(IMAGEN_COMPARTIR.ruta),
  areaServed: { '@type': 'Country', name: 'Venezuela' },
  knowsAbout: [
    'Pago en cuotas de consultas médicas',
    'Pago en cuotas de odontología',
    'Pago en cuotas de cosmetología',
    'Pago Móvil',
  ],
  sameAs: REDES.map((r) => r.url),
}

const SITIO = {
  '@type': 'WebSite',
  '@id': ID_SITIO,
  name: NOMBRE,
  alternateName: [...NOMBRES_ALTERNATIVOS],
  url: urlAbsoluta('/'),
  inLanguage: 'es-VE',
  publisher: { '@id': ID_ORGANIZACION },
}

/** Los nombres de cada tramo de la miga de pan, para el JSON-LD. */
export type Miga = { nombre: string; ruta: RutaPublica }

/**
 * Título, descripción, canonical, tarjetas para compartir y JSON-LD de una
 * página pública. El título va tal cual: cada página lo escribe completo
 * (Google lo corta hacia los 60 caracteres y la descripción hacia los 155,
 * así que lo que importa va delante).
 *
 * `migas` es el camino desde la portada sin incluirla (la portada no lleva);
 * `datos` son los nodos propios de la página (servicio, preguntas…), que se
 * suman al grafo común. `aspecto` dice qué fuentes descarga: las de la
 * portada o las del panel (`lib/fuentes.ts`).
 */
export function cabeceraPublica({
  titulo,
  descripcion,
  ruta,
  migas = [],
  datos = [],
  aspecto,
}: {
  titulo: string
  descripcion: string
  ruta: RutaPublica
  migas?: Miga[]
  datos?: object[]
  aspecto: 'portada' | 'panel'
}) {
  const url = urlAbsoluta(ruta)
  const imagen = urlAbsoluta(IMAGEN_COMPARTIR.ruta)

  const pagina = {
    '@type': 'WebPage',
    '@id': `${url}#pagina`,
    url,
    name: titulo,
    description: descripcion,
    inLanguage: 'es-VE',
    isPartOf: { '@id': ID_SITIO },
    about: { '@id': ID_ORGANIZACION },
    dateModified: PAGINAS_PUBLICAS[ruta].actualizada,
    primaryImageOfPage: { '@type': 'ImageObject', url: imagen },
    ...(migas.length ? { breadcrumb: { '@id': `${url}#migas` } } : {}),
  }

  const miga = migas.length
    ? [
        {
          '@type': 'BreadcrumbList',
          '@id': `${url}#migas`,
          itemListElement: [{ nombre: 'Inicio', ruta: '/' as RutaPublica }, ...migas].map(
            (m, i) => ({
              '@type': 'ListItem',
              position: i + 1,
              name: m.nombre,
              item: urlAbsoluta(m.ruta),
            }),
          ),
        },
      ]
    : []

  return {
    meta: [
      { title: titulo },
      { name: 'description', content: descripcion },
      {
        name: 'robots',
        content: 'index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1',
      },
      { property: 'og:type', content: 'website' },
      { property: 'og:site_name', content: NOMBRE },
      { property: 'og:locale', content: 'es_VE' },
      { property: 'og:url', content: url },
      { property: 'og:title', content: titulo },
      { property: 'og:description', content: descripcion },
      { property: 'og:image', content: imagen },
      { property: 'og:image:type', content: 'image/jpeg' },
      { property: 'og:image:width', content: String(IMAGEN_COMPARTIR.ancho) },
      { property: 'og:image:height', content: String(IMAGEN_COMPARTIR.alto) },
      { property: 'og:image:alt', content: IMAGEN_COMPARTIR.alt },
      { name: 'twitter:card', content: 'summary_large_image' },
      { name: 'twitter:title', content: titulo },
      { name: 'twitter:description', content: descripcion },
      { name: 'twitter:image', content: imagen },
      { name: 'twitter:image:alt', content: IMAGEN_COMPARTIR.alt },
      { name: 'geo.region', content: 'VE' },
    ],
    links: [
      { rel: 'canonical', href: url },
      // Un solo idioma, pero dicho: así Google no duda a qué país va.
      { rel: 'alternate', hrefLang: 'es-VE', href: url },
      { rel: 'alternate', hrefLang: 'x-default', href: url },
      aspecto === 'portada' ? FUENTES_DE_LA_PORTADA : FUENTES_DEL_PANEL,
    ],
    scripts: [
      jsonLd({
        '@context': 'https://schema.org',
        '@graph': [ORGANIZACION, SITIO, pagina, ...miga, ...datos],
      }),
    ],
  }
}

/** Las preguntas frecuentes de una página, como nodo `FAQPage` del JSON-LD. */
export function preguntasFrecuentes(
  ruta: RutaPublica,
  preguntas: ReadonlyArray<{ pregunta: string; respuesta: string }>,
) {
  return {
    '@type': 'FAQPage',
    '@id': `${urlAbsoluta(ruta)}#preguntas`,
    mainEntity: preguntas.map((p) => ({
      '@type': 'Question',
      name: p.pregunta,
      acceptedAnswer: { '@type': 'Answer', text: p.respuesta },
    })),
  }
}

/**
 * El servicio, visto desde un público: el paciente que paga en cuotas o el
 * médico que las ofrece. Nunca como producto financiero: es un pago en
 * cuotas (CLAUDE.md, «Nombres»).
 */
export function servicio({
  ruta,
  nombre,
  descripcion,
  publico,
  categoria,
}: {
  ruta: RutaPublica
  nombre: string
  descripcion: string
  publico: 'Patient' | 'Clinician'
  categoria?: string
}) {
  return {
    '@type': 'Service',
    '@id': `${urlAbsoluta(ruta)}#servicio`,
    name: nombre,
    serviceType: 'Pago en cuotas',
    ...(categoria ? { category: categoria } : {}),
    description: descripcion,
    url: urlAbsoluta(ruta),
    provider: { '@id': ID_ORGANIZACION },
    brand: { '@id': ID_ORGANIZACION },
    areaServed: { '@type': 'Country', name: 'Venezuela' },
    audience: { '@type': 'MedicalAudience', audienceType: publico },
    availableChannel: {
      '@type': 'ServiceChannel',
      serviceUrl: urlAbsoluta(ruta),
      availableLanguage: { '@type': 'Language', name: 'Español', alternateName: 'es' },
    },
  }
}

/** JSON-LD listo para un `<script>`: sin `<` que pueda cerrar la etiqueta. */
export function jsonLd(datos: unknown) {
  return {
    type: 'application/ld+json',
    children: JSON.stringify(datos).replace(/</g, '\\u003c'),
  }
}
