import { useState } from 'react'
import type { CSSProperties, ReactNode } from 'react'
import { createFileRoute, Link } from '@tanstack/react-router'
import { CircleCheck } from 'lucide-react'

import { FormularioDeCapacitacion } from '@/components/afiliacion/FormularioDeCapacitacion'
import type { CapacitacionAgendada } from '@/components/afiliacion/FormularioDeCapacitacion'
import { HeliosLogo } from '@/components/HeliosLogo'
import { Rotulo } from '@/components/portada/piezas'
import { hoyCaracas } from '@/components/ui'
import { FUENTES_DE_LA_PORTADA } from '@/lib/fuentes'
import { NO_INDEXAR } from '@/config/sitio'

/**
 * AGENDA — `/agenda`, a donde lleva el QR impreso (`/qr`).
 *
 * La versión corta de la afiliación, con el mismo aspecto claro: un solo
 * paso con nombre, teléfono, especialidad, dirección del consultorio y el
 * día y la hora de la capacitación presencial. Entra a Superadmin › Agenda
 * como la visita del médico (`helios_agendar_capacitacion`). No sale en
 * Google: es la página del QR.
 */
export const Route = createFileRoute('/agenda')({
  head: () => ({
    meta: [
      { title: 'Agenda tu capacitación · Helios' },
      {
        name: 'description',
        content:
          'Agenda la capacitación presencial de Helios en tu consultorio: te enseñamos a ofrecer pago en cuotas a tus pacientes.',
      },
      ...NO_INDEXAR.meta,
      { name: 'color-scheme', content: 'light' },
    ],
    links: [FUENTES_DE_LA_PORTADA],
  }),
  component: Agenda,
})

function Agenda() {
  const hoy = hoyCaracas()
  const [agendada, setAgendada] = useState<CapacitacionAgendada | null>(null)

  return (
    <div className="portada-raiz flex min-h-dvh bg-white">
      <div className="relative isolate flex min-h-dvh min-w-0 flex-1 flex-col overflow-clip px-4 sm:px-10">
        <div
          aria-hidden
          className="portada-aurora absolute -left-[30%] -top-[20%] -z-10 size-[720px] rounded-full"
        />

        <header className="mx-auto flex w-full max-w-[520px] items-center py-5 sm:py-6">
          <Link
            to="/"
            aria-label="Helios, ir a la portada"
            className="flex items-center"
          >
            <HeliosLogo height={28} color="#002770" />
          </Link>
        </header>

        <main className="flex flex-1 py-4 sm:py-8">
          <div className="mx-auto w-full max-w-[520px]">
            {agendada ? (
              <Agendada agendada={agendada} />
            ) : (
              <>
                <Entra>
                  <Rotulo>Para médicos y centros</Rotulo>
                </Entra>
                <h1 className="portada-titular mt-5 !text-[clamp(2.1rem,1.5rem+2.2vw,3rem)] text-portada-tinta">
                  <span className="portada-linea">
                    <span style={{ '--retraso': '100ms' } as CSSProperties}>
                      Agenda tu{' '}
                      <em className="portada-serif portada-degradado pr-[0.06em]">
                        capacitación.
                      </em>
                    </span>
                  </span>
                </h1>
                <Entra retraso={260}>
                  <p className="portada-entrada mt-4 max-w-[44ch] text-portada-tinta-2">
                    Te enseñamos en tu consultorio a ofrecer pago en cuotas a
                    tus pacientes. Déjanos tus datos y elige cuándo.
                  </p>
                </Entra>
                <Entra retraso={360} className="mt-7">
                  <FormularioDeCapacitacion hoy={hoy} alEnviar={setAgendada} />
                </Entra>
                <p className="mt-6 text-center text-[0.82rem] leading-relaxed text-portada-tinta-3">
                  Al enviarlo aceptas que tratemos estos datos según nuestra{' '}
                  <Link
                    to="/legal/privacidad"
                    className="font-medium text-portada-azul underline-offset-4 hover:underline"
                  >
                    política de privacidad
                  </Link>
                  .
                </p>
              </>
            )}
          </div>
        </main>

        <footer className="mx-auto flex w-full max-w-[520px] flex-wrap items-center justify-between gap-3 py-6 text-[0.82rem] text-portada-tinta-3">
          <span>© Helios · Venezuela</span>
          <Link
            to="/soporte"
            className="transition-colors hover:text-portada-tinta"
          >
            Soporte
          </Link>
        </footer>
      </div>
    </div>
  )
}

/** Entra al cargar, escalonado (la animación es la de la portada). */
function Entra({
  retraso = 0,
  children,
  className = '',
}: {
  retraso?: number
  children: ReactNode
  className?: string
}) {
  return (
    <div
      className={`portada-entra ${className}`}
      style={{ '--retraso': `${retraso}ms` } as CSSProperties}
    >
      {children}
    </div>
  )
}

/** «jueves 30 de octubre, a las 10:00 a. m.», en Caracas. */
function diaYHora(instante: string): string {
  const fecha = new Date(instante)
  const dia = fecha.toLocaleDateString('es-VE', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    timeZone: 'America/Caracas',
  })
  const hora = fecha.toLocaleTimeString('es-VE', {
    hour: 'numeric',
    minute: '2-digit',
    timeZone: 'America/Caracas',
  })
  return `${dia}, a las ${hora}`
}

/** La capacitación quedó anotada. */
function Agendada({ agendada }: { agendada: CapacitacionAgendada }) {
  return (
    <div role="status" className="portada-entra pt-4 sm:pt-8">
      <span
        aria-hidden
        className="grid size-14 place-items-center rounded-full bg-portada-cielo-3 text-portada-azul"
      >
        <CircleCheck className="size-7" />
      </span>
      <Rotulo className="mt-8">Capacitación agendada</Rotulo>
      <h1 className="portada-titular mt-5 !text-[clamp(2.1rem,1.5rem+2.2vw,3rem)] text-portada-tinta">
        ¡Nos{' '}
        <em className="portada-serif portada-degradado pr-[0.06em]">vemos!</em>
      </h1>
      <p className="mt-5 max-w-[46ch] rounded-2xl border border-portada-linea bg-portada-niebla px-4 py-3.5 text-[0.95rem] leading-relaxed text-portada-tinta-2">
        Anotamos tu capacitación presencial para el{' '}
        <span className="font-medium text-portada-tinta">
          {diaYHora(agendada.capacitacion)}
        </span>
        .
      </p>
      <p className="portada-entrada mt-4 max-w-[46ch] text-portada-tinta-2">
        Te escribimos al{' '}
        <span className="whitespace-nowrap font-medium text-portada-tinta">
          {agendada.phone}
        </span>{' '}
        para confirmarla.
      </p>
    </div>
  )
}
