import { createFileRoute, notFound } from '@tanstack/react-router'

import { PaginaDelDirectorio } from '@/components/directorio/PaginaDelDirectorio'
import { NoEncontrada, PAGINA_NO_ENCONTRADA } from '@/components/directorio/NoEncontrada'
import { cabeceraPublica, urlAbsoluta } from '@/config/sitio'
import { cargarDirectorio } from '@/features/directorio/api'
import { directorioEnSchema } from '@/features/directorio/directorio'
import {
  claveDeSegmento,
  guiaDeEspecialidad,
  rutaDeEspecialidad,
  rutaDeFicha,
  textosDeEspecialidad,
  ultimoCambio,
} from '@/features/directorio/paginas'

/**
 * UNA ESPECIALIDAD DEL DIRECTORIO — `/directorio/<especialidad>`
 * («/directorio/odontologia»). La misma página que `/directorio`, con sus
 * médicos marcados, su título («Odontólogos con pago en cuotas…»), su miga
 * de pan y su JSON-LD.
 *
 * Una especialidad que no existe, o que no tiene médicos, es 404: no se
 * publica una página vacía. «Otras especialidades» tiene página (para quien
 * la elija en los filtros) pero no sale en Google: no es algo que se busque.
 */
export const Route = createFileRoute('/directorio_/$especialidad')({
  staleTime: 60_000,
  loader: async ({ params }) => {
    const clave = claveDeSegmento(params.especialidad)
    if (!clave) throw notFound()
    const datos = await cargarDirectorio()
    if (!datos.fallo && !datos.medicos.some((m) => m.clave === clave)) throw notFound()
    return { ...datos, clave }
  },
  head: ({ loaderData }) => {
    if (!loaderData) return PAGINA_NO_ENCONTRADA
    const { clave, medicos } = loaderData
    const textos = textosDeEspecialidad(clave)
    const ruta = rutaDeEspecialidad(clave)
    const suyos = medicos.filter((m) => m.clave === clave)
    const base = cabeceraPublica({
      titulo: textos.titulo,
      descripcion: textos.descripcion,
      ruta,
      actualizada: ultimoCambio(suyos.map((m) => m.actualizado)),
      migas: [
        { nombre: 'Directorio de médicos', ruta: '/directorio' },
        { nombre: textos.miga, ruta },
      ],
      datos: suyos.length
        ? [directorioEnSchema(suyos, urlAbsoluta(ruta), (s) => urlAbsoluta(rutaDeFicha(s)))]
        : [],
      aspecto: 'portada',
      indexar: clave !== 'otra',
    })
    return { ...base, meta: [...base.meta, { name: 'color-scheme', content: 'light' }] }
  },
  component: Especialidad,
  notFoundComponent: NoEncontrada,
})

function Especialidad() {
  const { medicos, fallo, whatsappHelios, clave } = Route.useLoaderData()
  const textos = textosDeEspecialidad(clave)
  return (
    <PaginaDelDirectorio
      medicos={medicos}
      fallo={fallo}
      whatsappHelios={whatsappHelios}
      especialidad={clave}
      h1={textos.h1}
      entrada={textos.entrada}
      guia={guiaDeEspecialidad(clave)}
    />
  )
}
