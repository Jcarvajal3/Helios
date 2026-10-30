import { Link } from '@tanstack/react-router'
import { AtSign, MapPin } from 'lucide-react'

import { IconoDeEspecialidad } from './IconoDeEspecialidad'
import { rutaDeFicha } from '@/features/directorio/paginas'
import {
  enlaceDeRed,
  enlaceDeWhatsApp,
  especialidadDeTarjeta,
  lugarDeTarjeta,
} from '@/features/directorio/directorio'
import type { MedicoDelDirectorio } from '@/features/directorio/directorio'

/** El globo de WhatsApp, para que el botón se reconozca sin leerlo. */
export function LogoWhatsApp({ className = 'size-4' }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" fill="currentColor" className={className} aria-hidden>
      <path d="M17.472 14.382c-.297-.149-1.758-.867-2.03-.967-.273-.099-.471-.148-.67.15-.197.297-.767.966-.94 1.164-.173.199-.347.223-.644.075-.297-.15-1.255-.463-2.39-1.475-.883-.788-1.48-1.761-1.653-2.059-.173-.297-.018-.458.13-.606.134-.133.298-.347.446-.52.149-.174.198-.298.298-.497.099-.198.05-.371-.025-.52-.075-.149-.669-1.612-.916-2.207-.242-.579-.487-.5-.669-.51-.173-.008-.371-.01-.57-.01-.198 0-.52.074-.792.372-.272.297-1.04 1.016-1.04 2.479 0 1.462 1.065 2.875 1.213 3.074.149.198 2.096 3.2 5.077 4.487.709.306 1.262.489 1.694.625.712.227 1.36.195 1.871.118.571-.085 1.758-.719 2.006-1.413.248-.694.248-1.289.173-1.413-.074-.124-.272-.198-.57-.347m-5.421 7.403h-.004a9.87 9.87 0 0 1-5.031-1.378l-.361-.214-3.741.982.998-3.648-.235-.374a9.86 9.86 0 0 1-1.51-5.26c.001-5.45 4.436-9.884 9.888-9.884 2.64 0 5.122 1.03 6.988 2.898a9.825 9.825 0 0 1 2.893 6.994c-.003 5.45-4.437 9.884-9.885 9.884m8.413-18.297A11.815 11.815 0 0 0 12.05 0C5.495 0 .16 5.335.157 11.892c0 2.096.547 4.142 1.588 5.945L.057 24l6.305-1.654a11.882 11.882 0 0 0 5.683 1.448h.005c6.554 0 11.89-5.335 11.893-11.893a11.821 11.821 0 0 0-3.48-8.413Z" />
    </svg>
  )
}

/**
 * La tarjeta de un médico del directorio: el icono de su especialidad, su
 * nombre, su especialidad, dónde atiende, su red social (si la tiene), el
 * «0% inicial» y el botón para escribirle.
 *
 * Compacta, para que en el teléfono se vean varias de un vistazo, y entera
 * clicable: tocar cualquier parte abre el mismo chat que el botón. Solo el
 * nombre (a su ficha, `/medico/<slug>`) y el enlace a la red social quedan
 * por encima y llevan a otro sitio.
 *
 * Es la misma en `/directorio` y en la vista previa del superadmin, así que
 * lo que el equipo ve al editar es lo que verá el paciente. `onContacto`
 * apunta el clic; la vista previa no lo pasa. Con `whatsappHelios` (y el
 * código de la tarjeta), el botón lleva al chat de Helios; si no, directo al
 * médico (`enlaceDeWhatsApp`).
 */
export function TarjetaDeMedico({
  medico,
  whatsappHelios,
  onContacto,
}: {
  medico: MedicoDelDirectorio
  whatsappHelios?: string | null
  onContacto?: () => void
}) {
  const especialidad = especialidadDeTarjeta(medico)
  const lugar = lugarDeTarjeta(medico)
  const red = enlaceDeRed(medico)
  const enlace = enlaceDeWhatsApp(medico, whatsappHelios)

  return (
    <article className="directorio-tarjeta group relative flex h-full flex-col gap-3 rounded-[22px] border border-portada-linea bg-white p-4 sm:p-5">
      {/* Toda la tarjeta lleva al chat. Para el teclado y el lector de
          pantalla, el enlace es el botón de abajo. */}
      <a
        href={enlace}
        target="_blank"
        rel="noopener noreferrer"
        onClick={onContacto}
        aria-hidden
        tabIndex={-1}
        className="absolute inset-0 rounded-[inherit]"
      />

      <div className="flex items-start gap-3.5">
        <span className="directorio-icono grid size-11 shrink-0 place-items-center rounded-[14px] text-portada-azul">
          <IconoDeEspecialidad clave={medico.clave} className="size-5" />
        </span>
        <div className="min-w-0">
          <h3 className="text-[1.02rem] font-medium leading-snug tracking-[-0.02em] text-portada-tinta [overflow-wrap:anywhere]">
            {/* El nombre lleva a su ficha (2026-10-30), por encima del enlace
                al chat: es el enlace que Google sigue hasta cada médico. La
                vista previa del superadmin no tiene ficha. */}
            {medico.slug ? (
              <Link
                to={rutaDeFicha(medico.slug)}
                className="relative z-10 underline-offset-4 hover:text-portada-azul hover:underline"
              >
                {medico.nombre}
              </Link>
            ) : (
              medico.nombre
            )}
          </h3>
          {especialidad && (
            <p className="mt-0.5 line-clamp-2 text-[0.88rem] leading-snug text-portada-azul">{especialidad}</p>
          )}
        </div>
      </div>

      {(lugar || red) && (
        <div className="flex flex-col gap-1 text-[0.86rem] leading-snug text-portada-tinta-2">
          {lugar && (
            <p className="flex gap-2" title={lugar}>
              <MapPin aria-hidden className="mt-[0.15em] size-3.5 shrink-0 text-portada-tinta-3" />
              <span className="line-clamp-1 [overflow-wrap:anywhere]">{lugar}</span>
            </p>
          )}
          {red && (
            <p className="flex gap-2">
              <AtSign aria-hidden className="mt-[0.15em] size-3.5 shrink-0 text-portada-tinta-3" />
              <a
                href={red.url}
                target="_blank"
                rel="noopener noreferrer nofollow"
                aria-label={`${red.texto} en ${red.red}, abre en otra pestaña`}
                className="relative z-10 min-w-0 truncate underline-offset-4 hover:text-portada-azul hover:underline"
              >
                <span className="font-medium text-portada-tinta">{red.texto}</span>
                <span className="text-portada-tinta-3"> · {red.red}</span>
              </a>
            </p>
          )}
        </div>
      )}

      {/* El «0% inicial» junto al botón, como el precio junto a «Comprar». */}
      <div className="mt-auto flex items-center justify-between gap-2 pt-1">
        <span className="directorio-sello inline-flex h-7 shrink-0 items-center gap-1 rounded-full px-2.5 text-[0.78rem] font-medium tracking-[-0.01em] text-portada-azul">
          <span className="font-[family-name:var(--font-portada-mono)] tabular-nums">0%</span>
          inicial
        </span>
        <a
          href={enlace}
          target="_blank"
          rel="noopener noreferrer"
          onClick={onContacto}
          aria-label={`Agendar cita por WhatsApp con ${medico.nombre}`}
          className="portada-boton group/boton relative z-10 inline-flex h-10 items-center gap-2 whitespace-nowrap rounded-full bg-portada-tinta pl-4 pr-1.5 text-[0.88rem] font-medium tracking-[-0.01em] text-white shadow-[0_10px_30px_-12px_rgba(0,39,112,0.55)] transition-[background-color,transform] duration-300 hover:bg-portada-marino active:scale-[0.98] group-hover:bg-portada-marino"
        >
          Agendar cita
          <span
            aria-hidden
            className="grid size-7 place-items-center rounded-full bg-[#25D366] text-white transition-transform duration-300 group-hover:scale-105"
          >
            <LogoWhatsApp className="size-3.5" />
          </span>
        </a>
      </div>
    </article>
  )
}
