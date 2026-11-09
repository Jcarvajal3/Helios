import { createFileRoute } from '@tanstack/react-router'

import { PaginaDelDirectorio } from '@/components/directorio/PaginaDelDirectorio'
import { cabeceraPublica } from '@/config/sitio'
import { cargarConsultas } from '@/features/directorio/api'
import { TEXTOS_DE_CONSULTAS } from '@/features/directorio/consultas'
import { CLAVES_DE_ESPECIALIDAD } from '@/features/directorio/especialidades'
import type { ClaveDeEspecialidad } from '@/features/directorio/especialidades'
import { unoDe } from '@/lib/busqueda'

/**
 * CONSULTAS CON $15 DE INICIAL — `/consultas`, la variante B de la prueba
 * A/B del directorio (docs/06-PRUEBA-AB-DEL-DIRECTORIO.md). La pinta
 * `PaginaDelDirectorio` con `variante="b"`.
 *
 * Solo los médicos que entran en B (`helios_directorio_consultas()`:
 * consulta de más de $15 y hasta $60, o su equivalente en euros), en el
 * orden sorteado del directorio. El botón de cada tarjeta va al WhatsApp de
 * Helios con el código y «-B»; sin número de Helios o sin código, directo
 * al médico.
 *
 * No se enlaza desde ninguna página, no está en el sitemap, ni en
 * `llms.txt`, y lleva `noindex` sin JSON-LD de la lista: se llega solo por
 * la URL (anuncios, enlaces compartidos). El filtro de especialidad va en
 * la búsqueda (`?especialidad=`) y no recarga la lista.
 */
export const Route = createFileRoute('/consultas')({
  validateSearch: (search: Record<string, unknown>): { especialidad?: ClaveDeEspecialidad } => ({
    especialidad: unoDe(CLAVES_DE_ESPECIALIDAD, search.especialidad),
  }),
  loaderDeps: () => ({}),
  staleTime: 60_000,
  loader: () => cargarConsultas(),
  head: () => {
    const base = cabeceraPublica({
      titulo: TEXTOS_DE_CONSULTAS.titulo,
      descripcion: TEXTOS_DE_CONSULTAS.descripcion,
      ruta: '/consultas',
      aspecto: 'portada',
      indexar: false,
    })
    return { ...base, meta: [...base.meta, { name: 'color-scheme', content: 'light' }] }
  },
  component: Consultas,
})

function Consultas() {
  const { medicos, fallo, whatsappHelios } = Route.useLoaderData()
  const { especialidad } = Route.useSearch()
  return (
    <PaginaDelDirectorio
      variante="b"
      medicos={medicos}
      fallo={fallo}
      whatsappHelios={whatsappHelios}
      especialidad={especialidad}
      h1={TEXTOS_DE_CONSULTAS.h1}
      entrada={TEXTOS_DE_CONSULTAS.entrada}
    />
  )
}
