import { Link } from '@tanstack/react-router'
import { ArrowUpRight } from 'lucide-react'

import { Boton, Lienzo, Revelar, Rotulo } from './piezas'
import { IlustracionDeEspecialidad } from '@/components/directorio/IlustracionDeEspecialidad'
import { TarjetaDeMedico } from '@/components/directorio/TarjetaDeMedico'
import { apuntarContacto } from '@/features/directorio/api'
import type { EspecialidadPresente, MedicoDelDirectorio } from '@/features/directorio/directorio'
import { rutaDeEspecialidad } from '@/features/directorio/paginas'

/**
 * LO QUE EL HOME LE ENSEÑA AL PACIENTE (2026-11-12, Javier: el home se
 * enfoca en el paciente): las especialidades del directorio y médicos de
 * verdad a los que puede escribirles. Las dos salen de la base al cargar la
 * página; si el directorio no contesta o está vacío, no salen.
 */

/** Cuántas especialidades caben antes de «Ver todas». */
const ESPECIALIDADES_EN_EL_HOME = 7

/** Las especialidades con médicos: cada una lleva a su página del directorio. */
export function Especialidades({
  especialidades,
  total,
}: {
  especialidades: ReadonlyArray<EspecialidadPresente>
  total: number
}) {
  // «Otras» no dice nada en una baldosa: se llega por «Ver todas».
  const lista = especialidades.filter((e) => e.clave !== 'otra').slice(0, ESPECIALIDADES_EN_EL_HOME)
  if (lista.length === 0) return null

  return (
    <section id="especialidades" className="relative bg-white">
      <Lienzo className="py-20 sm:py-28">
        <Revelar className="text-center">
          <Rotulo>Directorio de médicos</Rotulo>
          <h2 className="directorio-titular-2 mx-auto mt-6 max-w-[16ch] text-portada-tinta">
            Elige tu especialidad{' '}
            <em className="directorio-enfasis">y escríbele a tu médico.</em>
          </h2>
        </Revelar>

        <ul className="mt-12 grid grid-cols-2 gap-3 sm:mt-16 sm:grid-cols-3 lg:grid-cols-4 lg:gap-4">
          {lista.map((e, i) => (
            <Revelar key={e.clave} como="li" retraso={(i % 4) * 60}>
              <Link
                to={rutaDeEspecialidad(e.clave)}
                className="portada-especialidad group flex h-full flex-col items-start gap-6 rounded-[32px] bg-portada-niebla p-5 sm:p-7"
              >
                <IlustracionDeEspecialidad clave={e.clave} grande />
                <span>
                  <span className="block text-[1.2rem] font-medium leading-tight tracking-[-0.03em] text-portada-tinta sm:text-[1.35rem]">
                    {e.nombre}
                  </span>
                  <span className="mt-1.5 block text-[0.92rem] text-portada-tinta-2">
                    {e.cuantos} {e.cuantos === 1 ? 'médico' : 'médicos'}
                  </span>
                </span>
              </Link>
            </Revelar>
          ))}
          <Revelar como="li" retraso={180}>
            <Link
              to="/directorio"
              className="portada-especialidad portada-especialidad-todas group flex h-full flex-col items-start justify-between gap-6 rounded-[32px] p-5 text-white sm:p-7"
            >
              <span className="grid size-12 place-items-center rounded-full bg-white text-portada-tinta transition-transform duration-500 group-hover:rotate-45">
                <ArrowUpRight className="size-5" />
              </span>
              <span>
                <span className="block text-[1.2rem] font-medium leading-tight tracking-[-0.03em] sm:text-[1.35rem]">
                  Ver todas
                </span>
                <span className="mt-1.5 block text-[0.92rem] text-white/85">
                  {total} {total === 1 ? 'médico' : 'médicos'} en el directorio
                </span>
              </span>
            </Link>
          </Revelar>
        </ul>
      </Lienzo>
    </section>
  )
}

/** Cuántas tarjetas de médico enseña el home. */
const MEDICOS_EN_EL_HOME = 6

/** Médicos de verdad, con su tarjeta del directorio y su botón de WhatsApp. */
export function MedicosDelDirectorio({
  medicos,
  whatsappHelios,
}: {
  medicos: ReadonlyArray<MedicoDelDirectorio>
  whatsappHelios: string | null
}) {
  if (medicos.length === 0) return null
  const lista = medicos.slice(0, MEDICOS_EN_EL_HOME)

  return (
    <section id="medicos" className="relative bg-portada-niebla">
      <Lienzo className="py-24 sm:py-32">
        <Revelar className="text-center">
          <Rotulo>Directorio</Rotulo>
          <h2 className="directorio-titular-2 mx-auto mt-6 max-w-[16ch] text-portada-tinta">
            Médicos que <em className="directorio-enfasis">ya aceptan Helios.</em>
          </h2>
          <p className="mx-auto mt-6 max-w-[52ch] text-[clamp(1.05rem,0.98rem+0.3vw,1.2rem)] leading-relaxed text-portada-tinta-2">
            Escríbeles por WhatsApp para agendar tu cita y paga el 50% el día de la consulta y el
            resto en 2 cuotas, a los 14 y 28 días.
          </p>
        </Revelar>

        <ul className="mt-12 grid gap-4 sm:mt-16 sm:grid-cols-2 sm:gap-5 lg:grid-cols-3">
          {lista.map((m, i) => (
            <Revelar key={m.id} como="li" retraso={(i % 3) * 60}>
              <TarjetaDeMedico
                medico={m}
                whatsappHelios={whatsappHelios}
                onContacto={() => apuntarContacto(m.id)}
              />
            </Revelar>
          ))}
        </ul>

        {medicos.length > lista.length && (
          <Revelar className="mt-10 flex justify-center">
            <Boton to="/directorio">Ver los {medicos.length} del directorio</Boton>
          </Revelar>
        )}
      </Lienzo>
    </section>
  )
}
