import { MapPin } from 'lucide-react'

import { IconoDeEspecialidad } from './IconoDeEspecialidad'
import { enlaceDeWhatsApp, especialidadDeTarjeta, lugarDeTarjeta } from '@/features/directorio/directorio'
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
 * nombre, su especialidad, dónde atiende y el botón para escribirle.
 *
 * Es la misma en `/directorio` y en la vista previa del superadmin, así que
 * lo que el equipo ve al editar es lo que verá el paciente. `onContacto`
 * apunta el clic; la vista previa no lo pasa.
 */
export function TarjetaDeMedico({
  medico,
  onContacto,
}: {
  medico: MedicoDelDirectorio
  onContacto?: () => void
}) {
  const especialidad = especialidadDeTarjeta(medico)
  const lugar = lugarDeTarjeta(medico)

  return (
    <article className="directorio-tarjeta group relative flex h-full flex-col rounded-[28px] border border-portada-linea bg-white p-6 sm:p-7">
      <div className="flex items-start gap-4">
        <span className="directorio-icono relative grid size-14 shrink-0 place-items-center rounded-[18px] text-portada-azul">
          <IconoDeEspecialidad clave={medico.clave} className="size-6" />
        </span>
        <div className="min-w-0 pt-1">
          <h3 className="text-[1.16rem] font-medium leading-snug tracking-[-0.025em] text-portada-tinta [overflow-wrap:anywhere]">
            {medico.nombre}
          </h3>
          {especialidad && (
            <p className="mt-1 text-[0.95rem] leading-snug text-portada-azul">{especialidad}</p>
          )}
        </div>
      </div>

      {lugar && (
        <p className="mt-5 flex gap-2.5 border-t border-portada-linea pt-5 text-[0.93rem] leading-relaxed text-portada-tinta-2">
          <MapPin aria-hidden className="mt-[0.2em] size-4 shrink-0 text-portada-tinta-3" />
          <span className="[overflow-wrap:anywhere]">{lugar}</span>
        </p>
      )}

      <div className="mt-auto pt-6">
        <a
          href={enlaceDeWhatsApp(medico)}
          target="_blank"
          rel="noopener noreferrer"
          onClick={onContacto}
          aria-label={`Escribir por WhatsApp a ${medico.nombre}`}
          className="portada-boton group/boton inline-flex h-12 w-full items-center justify-between gap-2 whitespace-nowrap rounded-full bg-portada-tinta pl-5 pr-2 text-[0.95rem] font-medium tracking-[-0.01em] text-white shadow-[0_10px_30px_-12px_rgba(0,39,112,0.55)] transition-[background-color,transform] duration-300 hover:bg-portada-marino active:scale-[0.98]"
        >
          Escribir por WhatsApp
          <span
            aria-hidden
            className="grid size-8 place-items-center rounded-full bg-[#25D366] text-white transition-transform duration-300 group-hover/boton:scale-105"
          >
            <LogoWhatsApp />
          </span>
        </a>
      </div>
    </article>
  )
}
