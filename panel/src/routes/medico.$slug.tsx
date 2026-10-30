import { createFileRoute, Link, notFound } from '@tanstack/react-router'
import { ArrowUpRight, AtSign, MapPin } from 'lucide-react'

import { IconoDeEspecialidad } from '@/components/directorio/IconoDeEspecialidad'
import { NoEncontrada, PAGINA_NO_ENCONTRADA } from '@/components/directorio/NoEncontrada'
import {
  ComoPagas,
  MigasDelDirectorio,
  ParaMedicos,
} from '@/components/directorio/PaginaDelDirectorio'
import { LogoWhatsApp } from '@/components/directorio/TarjetaDeMedico'
import { Pie } from '@/components/portada'
import { Menu } from '@/components/portada/Menu'
import { Lienzo, Revelar, Rotulo } from '@/components/portada/piezas'
import { cabeceraPublica, urlAbsoluta } from '@/config/sitio'
import { apuntarContacto, cargarDirectorio, consultarMedico } from '@/features/directorio/api'
import {
  enlaceDeRed,
  enlaceDeWhatsApp,
  especialidadDeTarjeta,
  lugarDeTarjeta,
  medicoEnSchema,
} from '@/features/directorio/directorio'
import type { MedicoDelDirectorio } from '@/features/directorio/directorio'
import { nombreDeEspecialidad } from '@/features/directorio/especialidades'
import {
  enlaceDeMapa,
  guiaDeEspecialidad,
  otrosDeLaEspecialidad,
  profesionales,
  rutaDeEspecialidad,
  rutaDeFicha,
  textosDeFicha,
} from '@/features/directorio/paginas'

/**
 * LA FICHA DE UN MÉDICO — `/medico/<slug>` («/medico/dra-ana-lara»).
 *
 * Una página por médico publicado en el directorio, armada sola desde la
 * base: su nombre, su especialidad, dónde atiende (con un enlace que busca
 * esa dirección en Google Maps, tal cual la escribió él), su red social y el
 * botón para agendar por WhatsApp, que es el mismo de su tarjeta (pasa por
 * el WhatsApp de Helios con su código y apunta el clic con su origen).
 *
 * Solo dice lo que el directorio sabe: nada de horarios, precios, estudios
 * ni opiniones que no tengamos. Un médico que deja de salir es 404.
 *
 * Abajo, cómo se paga y otros médicos de la misma especialidad (enlazado
 * interno: así Google llega de una ficha a otra).
 */
export const Route = createFileRoute('/medico/$slug')({
  staleTime: 60_000,
  loader: async ({ params }) => {
    const [medico, directorio] = await Promise.all([consultarMedico(params.slug), cargarDirectorio()])
    if (!medico?.slug) throw notFound()
    return { medico, otros: otrosDeLaEspecialidad(medico, directorio.medicos), whatsappHelios: directorio.whatsappHelios }
  },
  head: ({ loaderData }) => {
    if (!loaderData) return PAGINA_NO_ENCONTRADA
    const { medico: m } = loaderData
    const ruta = rutaDeFicha(m.slug ?? '')
    const textos = textosDeFicha(m)
    const base = cabeceraPublica({
      titulo: textos.titulo,
      descripcion: textos.descripcion,
      ruta,
      actualizada: m.actualizado?.slice(0, 10),
      migas: [
        { nombre: 'Directorio de médicos', ruta: '/directorio' },
        ...(m.clave === 'otra' ? [] : [{ nombre: nombreDeEspecialidad(m.clave), ruta: rutaDeEspecialidad(m.clave) }]),
        { nombre: m.nombre, ruta },
      ],
      datos: [medicoEnSchema(m, urlAbsoluta(ruta))],
      aspecto: 'portada',
    })
    return { ...base, meta: [...base.meta, { name: 'color-scheme', content: 'light' }] }
  },
  component: Ficha,
  notFoundComponent: NoEncontrada,
})

function Ficha() {
  const { medico: m, otros, whatsappHelios } = Route.useLoaderData()
  return (
    <div className="portada-raiz min-h-screen">
      <Menu />
      <main>
        <Cabecera medico={m} whatsappHelios={whatsappHelios} />
        <ComoPagas guia={guiaDeEspecialidad(m.clave)} />
        {otros.length > 0 && <Otros medico={m} otros={otros} />}
        <ParaMedicos />
      </main>
      <Pie />
    </div>
  )
}

function Cabecera({ medico: m, whatsappHelios }: { medico: MedicoDelDirectorio; whatsappHelios: string | null }) {
  const { especialidad } = textosDeFicha(m)
  const lugar = lugarDeTarjeta(m)
  const mapa = enlaceDeMapa(m)
  const red = enlaceDeRed(m)
  const chat = enlaceDeWhatsApp(m, whatsappHelios)

  return (
    <section className="relative isolate overflow-clip bg-white">
      <div
        aria-hidden
        className="portada-aurora absolute -right-[25%] -top-[35%] -z-10 size-[900px] rounded-full"
      />
      <Lienzo className="pb-20 pt-28 sm:pb-24 sm:pt-36">
        <MigasDelDirectorio
          tramos={[
            { texto: 'Inicio', to: '/' },
            { texto: 'Directorio', to: '/directorio' },
            ...(m.clave === 'otra' ? [] : [{ texto: nombreDeEspecialidad(m.clave), to: rutaDeEspecialidad(m.clave) }]),
            { texto: m.nombre },
          ]}
        />

        <div className="mt-10 flex max-w-[52rem] flex-col gap-6 sm:flex-row sm:items-start sm:gap-8">
          <span className="directorio-icono grid size-16 shrink-0 place-items-center rounded-[20px] text-portada-azul sm:size-20">
            <IconoDeEspecialidad clave={m.clave} className="size-7 sm:size-8" />
          </span>
          <div className="min-w-0">
            <h1 className="text-[clamp(1.9rem,1.3rem+2.4vw,3.2rem)] font-medium leading-[1.05] tracking-[-0.045em] text-portada-tinta [overflow-wrap:anywhere]">
              {m.nombre}
            </h1>
            <p className="mt-3 text-[1.1rem] leading-snug text-portada-azul">{especialidad}</p>

            {(lugar || red) && (
              <div className="mt-6 flex flex-col gap-2.5 text-[0.98rem] leading-snug text-portada-tinta-2">
                {lugar && (
                  <p className="flex gap-2.5">
                    <MapPin aria-hidden className="mt-[0.2em] size-4 shrink-0 text-portada-tinta-3" />
                    <span className="[overflow-wrap:anywhere]">
                      {lugar}
                      {mapa && (
                        <>
                          {' · '}
                          <a
                            href={mapa}
                            target="_blank"
                            rel="noopener noreferrer nofollow"
                            className="font-medium text-portada-azul underline-offset-4 hover:underline"
                          >
                            Ver en el mapa
                          </a>
                        </>
                      )}
                    </span>
                  </p>
                )}
                {red && (
                  <p className="flex gap-2.5">
                    <AtSign aria-hidden className="mt-[0.2em] size-4 shrink-0 text-portada-tinta-3" />
                    <a
                      href={red.url}
                      target="_blank"
                      rel="noopener noreferrer nofollow"
                      className="min-w-0 truncate underline-offset-4 hover:text-portada-azul hover:underline"
                    >
                      <span className="font-medium text-portada-tinta">{red.texto}</span>
                      <span className="text-portada-tinta-3"> · {red.red}</span>
                    </a>
                  </p>
                )}
              </div>
            )}

            <p className="portada-entrada mt-8 max-w-[56ch] text-portada-tinta-2">
              {m.nombre} acepta Helios: pagas tu consulta en 2 cuotas, a los 7 y 14 días, sin inicial.
              Escríbele por WhatsApp para agendar tu cita.
            </p>

            <div className="mt-8 flex flex-wrap items-center gap-3">
              <a
                href={chat}
                target="_blank"
                rel="noopener noreferrer"
                onClick={() => apuntarContacto(m.id)}
                className="portada-boton inline-flex h-12 items-center gap-2.5 whitespace-nowrap rounded-full bg-portada-tinta pl-6 pr-2 text-[0.98rem] font-medium tracking-[-0.01em] text-white shadow-[0_10px_30px_-12px_rgba(0,39,112,0.55)] transition-colors duration-300 hover:bg-portada-marino"
              >
                Agendar cita por WhatsApp
                <span aria-hidden className="grid size-8 place-items-center rounded-full bg-[#25D366] text-white">
                  <LogoWhatsApp className="size-4" />
                </span>
              </a>
              <span className="directorio-sello inline-flex h-9 items-center gap-1 rounded-full px-3 text-[0.85rem] font-medium tracking-[-0.01em] text-portada-azul">
                <span className="font-[family-name:var(--font-portada-mono)] tabular-nums">0%</span>
                inicial
              </span>
            </div>
          </div>
        </div>
      </Lienzo>
    </section>
  )
}

/** Otros médicos de la misma especialidad, y el enlace a todos. */
function Otros({ medico: m, otros }: { medico: MedicoDelDirectorio; otros: MedicoDelDirectorio[] }) {
  return (
    <section className="relative border-t border-portada-linea bg-portada-niebla">
      <Lienzo className="py-20 sm:py-24">
        <Revelar>
          <Rotulo>{nombreDeEspecialidad(m.clave)}</Rotulo>
          <h2 className="mt-5 text-[clamp(1.5rem,1.2rem+1.2vw,2.2rem)] font-medium leading-tight tracking-[-0.035em] text-portada-tinta">
            Otros {profesionales(m.clave).toLowerCase()} con pago en cuotas
          </h2>
        </Revelar>
        <ul className="mt-8 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {otros.map((o) => (
            <li key={o.id}>
              <Link
                to={rutaDeFicha(o.slug ?? '')}
                className="group flex h-full flex-col gap-1 rounded-[22px] border border-portada-linea bg-white px-5 py-4 transition-[border-color,box-shadow] duration-300 hover:border-portada-azul/30 hover:shadow-[0_24px_50px_-30px_rgba(0,39,112,0.3)]"
              >
                <span className="flex items-center justify-between gap-3 text-[1.02rem] font-medium tracking-[-0.02em] text-portada-tinta">
                  {o.nombre}
                  <ArrowUpRight className="size-4 shrink-0 text-portada-azul" aria-hidden />
                </span>
                <span className="line-clamp-1 text-[0.88rem] text-portada-tinta-2">
                  {[especialidadDeTarjeta(o), o.ciudad].filter(Boolean).join(' · ')}
                </span>
              </Link>
            </li>
          ))}
        </ul>
        {m.clave !== 'otra' && (
          <p className="mt-6 text-[0.95rem]">
            <Link
              to={rutaDeEspecialidad(m.clave)}
              className="font-medium text-portada-azul underline-offset-4 hover:underline"
            >
              Ver todos los {profesionales(m.clave).toLowerCase()} del directorio
            </Link>
          </p>
        )}
      </Lienzo>
    </section>
  )
}
