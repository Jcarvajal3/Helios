import { createFileRoute, redirect } from '@tanstack/react-router'

import { PaginaDelDirectorio } from '@/components/directorio/PaginaDelDirectorio'
import { cabeceraPublica, urlAbsoluta } from '@/config/sitio'
import { cargarDirectorio } from '@/features/directorio/api'
import { directorioEnSchema } from '@/features/directorio/directorio'
import { CLAVES_DE_ESPECIALIDAD } from '@/features/directorio/especialidades'
import type { ClaveDeEspecialidad } from '@/features/directorio/especialidades'
import { rutaDeFicha, segmentoDeEspecialidad } from '@/features/directorio/paginas'
import { unoDe } from '@/lib/busqueda'

/**
 * EL DIRECTORIO DE MÉDICOS — `/directorio`, todos los médicos. La página la
 * pinta `PaginaDelDirectorio`; cada especialidad tiene la suya
 * (`directorio_.$especialidad.tsx`) y cada médico su ficha
 * (`medico.$slug.tsx`).
 *
 * Sale en Google desde el 2026-10-30 (Javier; antes llevaba `noindex`):
 * usa `cabeceraPublica`, está en el sitemap y en `llms.txt`, y su JSON-LD
 * lleva cada médico como `Physician` (`directorioEnSchema`). Se llega por
 * «Directorio» en el menú, por el pie y compartiendo la URL.
 *
 * Hasta el 2026-10-30 el filtro iba en la búsqueda (`?especialidad=`): esos
 * enlaces, ya compartidos, redirigen (301) a la página de la especialidad.
 */

const TITULO = 'Médicos con pago en cuotas en Venezuela | Directorio Helios'
const DESCRIPCION =
  'Encuentra médicos, odontólogos y especialistas que aceptan Helios, escríbeles por WhatsApp y paga tu consulta en dos cuotas, a los 7 y 14 días, sin inicial.'

export const Route = createFileRoute('/directorio')({
  validateSearch: (search: Record<string, unknown>): { especialidad?: ClaveDeEspecialidad } => ({
    especialidad: unoDe(CLAVES_DE_ESPECIALIDAD, search.especialidad),
  }),
  beforeLoad: ({ search }) => {
    if (search.especialidad) {
      throw redirect({
        to: '/directorio/$especialidad',
        params: { especialidad: segmentoDeEspecialidad(search.especialidad) },
        statusCode: 301,
      })
    }
  },
  loaderDeps: () => ({}),
  staleTime: 60_000,
  loader: () => cargarDirectorio(),
  head: ({ loaderData }) => {
    const base = cabeceraPublica({
      titulo: TITULO,
      descripcion: DESCRIPCION,
      ruta: '/directorio',
      migas: [{ nombre: 'Directorio de médicos', ruta: '/directorio' }],
      datos: loaderData?.medicos.length
        ? [directorioEnSchema(loaderData.medicos, urlAbsoluta('/directorio'), (s) => urlAbsoluta(rutaDeFicha(s)))]
        : [],
      aspecto: 'portada',
    })
    return { ...base, meta: [...base.meta, { name: 'color-scheme', content: 'light' }] }
  },
  component: Directorio,
})

function Directorio() {
  const { medicos, fallo, whatsappHelios } = Route.useLoaderData()
  return (
    <PaginaDelDirectorio
      medicos={medicos}
      fallo={fallo}
      whatsappHelios={whatsappHelios}
      h1={{ antes: 'Encuentra a tu médico', enfasis: 'con 0% de inicial.' }}
      entrada="Escríbele por WhatsApp y paga tu consulta en 2 cuotas, a los 7 y 14 días."
      guia={{ ruta: '/pacientes', texto: 'Cómo funciona el pago en cuotas' }}
    />
  )
}
