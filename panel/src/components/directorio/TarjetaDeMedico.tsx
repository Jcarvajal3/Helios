import { Link } from '@tanstack/react-router'
import { AtSign, MapPin } from 'lucide-react'

import { IlustracionDeEspecialidad } from './IlustracionDeEspecialidad'
import { rutaDeFicha } from '@/features/directorio/paginas'
import {
  CONDICIONES_DE_CONSULTAS,
  PRECIO_DE_CONSULTAS,
  TEXTOS_DE_CONSULTAS,
  lugarEnConsultas,
} from '@/features/directorio/consultas'
import {
  ROTULO_DE_PRECIO,
  enlaceDeRed,
  enlaceDeWhatsApp,
  especialidadDeTarjeta,
  lugarDeTarjeta,
  precioDeTarjeta,
} from '@/features/directorio/directorio'
import type { MedicoDelDirectorio, VarianteDelDirectorio } from '@/features/directorio/directorio'

/** El sello de la inicial, junto al botón: el mismo sitio en A y en B, con su oferta. */
const SELLO_DE_INICIAL: Record<VarianteDelDirectorio, { cifra: string; texto: string }> = {
  a: { cifra: '50%', texto: 'inicial' },
  b: TEXTOS_DE_CONSULTAS.sello,
}

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
 * nombre, su especialidad, dónde atiende, su red social y el precio de su
 * consulta (si los tiene), el «50% inicial», las «2 cuotas» y el botón para
 * escribirle.
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
 *
 * En `/consultas` (`variante` `'b'`, docs/06) el nombre no enlaza a la ficha
 * (la ficha es de A), el precio es el mismo para todos («Consulta a partir
 * de: $30», `PRECIO_DE_CONSULTAS`), de dónde atiende solo sale la zona
 * (`lugarEnConsultas`), debajo del precio va «Inicial $15 y el resto en 2
 * cuotas quincenales», el sello dice «$15 inicial» y el código del mensaje a
 * Helios lleva «-B».
 */
export function TarjetaDeMedico({
  medico,
  whatsappHelios,
  onContacto,
  variante = 'a',
}: {
  medico: MedicoDelDirectorio
  whatsappHelios?: string | null
  onContacto?: () => void
  variante?: VarianteDelDirectorio
}) {
  const especialidad = especialidadDeTarjeta(medico)
  // En B, solo la zona (`ZONA_EN_CONSULTAS`), no la dirección entera.
  const lugar = variante === 'b' ? lugarEnConsultas(medico) : lugarDeTarjeta(medico)
  const red = enlaceDeRed(medico)
  const enB = variante === 'b'
  // En B, el mismo precio para todos (`PRECIO_DE_CONSULTAS`), no el del médico.
  const precio = enB ? PRECIO_DE_CONSULTAS : precioDeTarjeta(medico)
  const enlace = enlaceDeWhatsApp(medico, whatsappHelios, variante)
  const sello = SELLO_DE_INICIAL[variante]

  return (
    // Como la maqueta aprobada (2026-11-12), blanca y sólida, con una luz azul
    // que sigue al puntero (`--mx`, `--my`). En vez del orbe, el icono 3D de
    // la especialidad (Javier, 2026-11-12).
    <article
      onMouseMove={seguirLaLuz}
      className="directorio-tarjeta group relative flex h-full flex-col gap-[22px] overflow-hidden rounded-[34px] border p-[26px]"
    >
      {/* Toda la tarjeta lleva al chat. Para el teclado y el lector de
          pantalla, el enlace es el botón de abajo. */}
      <a
        href={enlace}
        target="_blank"
        rel="noopener noreferrer"
        onClick={onContacto}
        aria-hidden
        tabIndex={-1}
        className="absolute inset-0 z-[1] rounded-[inherit]"
      />

      <div className="relative flex items-center gap-4">
        <IlustracionDeEspecialidad clave={medico.clave} />
        <div className="min-w-0">
          <h3 className="text-[21px] font-medium leading-[1.15] tracking-[-0.03em] text-portada-tinta [overflow-wrap:anywhere]">
            {/* El nombre lleva a su ficha (2026-10-30), por encima del enlace
                al chat: es el enlace que Google sigue hasta cada médico. La
                vista previa del superadmin no tiene ficha, y `/consultas`
                no lleva a ella. */}
            {medico.slug && !enB ? (
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
            <p className="mt-1 line-clamp-2 text-[15px] leading-[1.35] text-portada-tinta-2">{especialidad}</p>
          )}
        </div>
      </div>

      {(lugar || red) && (
        <div className="relative flex flex-col gap-2.5 text-[14.5px] leading-[1.35] text-portada-tinta-2">
          {lugar && (
            <p className="flex items-center gap-2.5" title={lugar}>
              <MapPin aria-hidden className="size-[17px] shrink-0" strokeWidth={1.6} />
              <span className="line-clamp-2 [overflow-wrap:anywhere]">{lugar}</span>
            </p>
          )}
          {red && (
            <p className="flex items-center gap-2.5">
              <AtSign aria-hidden className="size-[17px] shrink-0" strokeWidth={1.6} />
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

      {/* El precio grande y las condiciones, y debajo el botón entero. */}
      <div className="relative mt-auto flex flex-col gap-[18px] border-t border-portada-tinta/[0.08] pt-[22px]">
        <div className="flex flex-wrap items-end justify-between gap-3">
          {(precio || enB) && (
            <div className="text-[13.5px] text-portada-tinta-2">
              {precio && (
                <p>
                  {ROTULO_DE_PRECIO}
                  <span className="directorio-precio-grande block tabular-nums">{precio}</span>
                </p>
              )}
              {/* En B, la oferta debajo del precio (o sola, si no lo tiene). */}
              {enB && (
                <p className={`max-w-[22ch] font-medium text-portada-azul ${precio ? 'mt-1.5' : ''}`}>
                  {CONDICIONES_DE_CONSULTAS}
                </p>
              )}
            </div>
          )}
          <p className="mb-1 ml-auto flex gap-1.5">
            <span className="directorio-sello inline-flex h-7 shrink-0 items-center gap-1 rounded-full px-[11px] text-[12.5px] font-semibold">
              <span className="tabular-nums">{sello.cifra}</span>
              {sello.texto}
            </span>
            <span className="directorio-sello inline-flex h-7 shrink-0 items-center gap-1 rounded-full px-[11px] text-[12.5px] font-semibold">
              <span className="tabular-nums">2</span>
              cuotas
            </span>
          </p>
        </div>
        <a
          href={enlace}
          target="_blank"
          rel="noopener noreferrer"
          onClick={onContacto}
          aria-label={`Agendar cita por WhatsApp con ${medico.nombre}`}
          className="directorio-agendar relative z-10 flex h-[54px] items-center justify-between gap-2 whitespace-nowrap rounded-full pl-6 pr-2 text-[16px] font-medium tracking-[-0.015em] text-white"
        >
          Agendar cita
          <span aria-hidden className="directorio-agendar-icono grid size-[38px] place-items-center rounded-full">
            <LogoWhatsApp className="size-[17px]" />
          </span>
        </a>
      </div>
    </article>
  )
}

/** La luz de la tarjeta sigue al puntero. */
function seguirLaLuz(evento: React.MouseEvent<HTMLElement>) {
  const el = evento.currentTarget
  const r = el.getBoundingClientRect()
  el.style.setProperty('--mx', `${evento.clientX - r.left}px`)
  el.style.setProperty('--my', `${evento.clientY - r.top}px`)
}
