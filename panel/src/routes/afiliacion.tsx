import { useState } from 'react'
import type { CSSProperties, ReactNode } from 'react'
import { createFileRoute, Link } from '@tanstack/react-router'
import { ArrowLeft, Check, CircleCheck } from 'lucide-react'

import { FormularioDeAfiliacion } from '@/components/afiliacion/Formulario'
import type { SolicitudEnviada } from '@/components/afiliacion/Formulario'
import { HeliosLogo } from '@/components/HeliosLogo'
import { CampoDePuntos } from '@/components/portada/CampoDePuntos'
import { Boton, Rotulo } from '@/components/portada/piezas'
import { hoyCaracas } from '@/components/ui'
import { cabeceraPublica } from '@/config/sitio'

export const Route = createFileRoute('/afiliacion')({
  head: () => {
    const base = cabeceraPublica({
      titulo: 'Afilia tu consultorio y ofrece pago en cuotas | Helios',
      descripcion:
        'Solicita la afiliación de tu consultorio o centro de salud: tus pacientes pagan en 2 cuotas y tú cobras el 100% a los 8 y 15 días. Sin costo ni permanencia.',
      ruta: '/afiliacion',
      migas: [
        { nombre: 'Médicos y centros', ruta: '/medicos' },
        { nombre: 'Quiero afiliarme', ruta: '/afiliacion' },
      ],
      aspecto: 'portada',
    })
    return {
      ...base,
      meta: [...base.meta, { name: 'color-scheme', content: 'light' }],
    }
  },
  component: Afiliacion,
})

const NOCHE = '#020B24'

/** Lo que gana el médico, en el bloque oscuro y, en el teléfono, en píldoras. */
const PROMESAS = [
  {
    corta: '100% de cada consulta',
    larga: 'Recibes el 100% de cada consulta, pague o no el paciente.',
  },
  {
    corta: 'Cobras a los 8 y 15 días',
    larga: 'En dos mitades: a los 8 y a los 15 días.',
  },
  {
    corta: 'Sin costo ni permanencia',
    larga: 'No te cuesta nada y no hay permanencia.',
  },
] as const

/**
 * AFILIACIÓN — `/afiliacion`, a donde lleva «Quiero afiliarme».
 *
 * Con el aspecto de la portada y el molde del login: el formulario a la
 * izquierda y, en escritorio, el bloque oscuro con lo que gana el médico.
 * El formulario va en tres pasos cortos (`FormularioDeAfiliacion`) y pide lo
 * mismo que el alta del equipo. La solicitud queda pendiente en Clínicas ›
 * Pendientes del superadmin; al aprobarla nace la clínica. La base valida lo
 * mismo que aquí y frena el abuso (`helios_solicitar_afiliacion`).
 *
 * Si quiere, pide además su capacitación presencial: entra a la agenda del
 * equipo como su visita.
 */
function Afiliacion() {
  const hoy = hoyCaracas()
  const [enviada, setEnviada] = useState<SolicitudEnviada | null>(null)

  return (
    <div className="portada-raiz flex min-h-dvh bg-white lg:items-start lg:p-4">
      {/* `overflow-clip` y no `hidden`: el halo de fondo es más ancho que el
          teléfono, y una caja `hidden` se deja desplazar de lado al llevar
          el foco a un campo con error. */}
      <div className="relative isolate flex min-h-dvh min-w-0 flex-1 flex-col overflow-clip px-4 sm:px-10 lg:min-h-[calc(100dvh-2rem)] lg:px-14">
        <div
          aria-hidden
          className="portada-aurora absolute -left-[30%] -top-[20%] -z-10 size-[720px] rounded-full"
        />

        <header className="flex items-center justify-between gap-3 py-5 sm:py-6">
          <Link
            to="/"
            aria-label="Helios, ir a la portada"
            className="flex items-center"
          >
            <HeliosLogo height={28} color="#002770" />
          </Link>
          <Link
            to="/"
            className="group inline-flex items-center gap-1.5 rounded-full px-3 py-2 text-[0.9rem] tracking-[-0.01em] text-portada-tinta-2 transition-colors duration-300 hover:bg-portada-tinta/[0.05] hover:text-portada-tinta"
          >
            <ArrowLeft className="size-4 transition-transform duration-300 group-hover:-translate-x-0.5" />
            Volver al inicio
          </Link>
        </header>

        <main className="flex flex-1 py-6 sm:py-10">
          <div className="mx-auto w-full max-w-[580px]">
            {enviada ? (
              <Recibida solicitud={enviada} />
            ) : (
              <>
                <Entra>
                  <Rotulo>Para médicos y centros</Rotulo>
                </Entra>
                <h1 className="portada-titular mt-5 !text-[clamp(2.2rem,1.5rem+2.4vw,3.4rem)] text-portada-tinta">
                  <span className="portada-linea">
                    <span style={{ '--retraso': '100ms' } as CSSProperties}>
                      Afilia tu{' '}
                      <em className="portada-serif portada-degradado pr-[0.06em]">
                        consultorio.
                      </em>
                    </span>
                  </span>
                </h1>
                <Entra retraso={260}>
                  <p className="portada-entrada mt-4 max-w-[46ch] text-portada-tinta-2">
                    Son tres pasos cortos. Ten a mano tu cédula y el número de
                    la cuenta donde quieres cobrar.
                  </p>
                  <ul
                    aria-label="Lo que recibes"
                    className="mt-5 flex flex-wrap gap-2 lg:hidden"
                  >
                    {PROMESAS.map((p) => (
                      <li
                        key={p.corta}
                        className="inline-flex items-center gap-1.5 rounded-full border border-portada-linea bg-white/70 px-3 py-1.5 text-[0.85rem] text-portada-tinta backdrop-blur"
                      >
                        <Check
                          aria-hidden
                          className="size-3.5 text-portada-azul"
                          strokeWidth={2.5}
                        />
                        {p.corta}
                      </li>
                    ))}
                  </ul>
                </Entra>
                <Entra retraso={360} className="mt-8">
                  <FormularioDeAfiliacion hoy={hoy} alEnviar={setEnviada} />
                </Entra>
                <p className="mt-6 text-center text-[0.92rem] text-portada-tinta-2">
                  ¿Ya tienes cuenta?{' '}
                  <Link
                    to="/login"
                    className="font-medium text-portada-azul underline-offset-4 hover:underline"
                  >
                    Entrar
                  </Link>
                </p>
              </>
            )}
          </div>
        </main>

        <footer className="flex flex-wrap items-center justify-between gap-3 py-6 text-[0.82rem] text-portada-tinta-3">
          <span>© Helios · Venezuela</span>
          <span className="flex gap-5">
            <Link
              to="/legal/privacidad"
              className="transition-colors hover:text-portada-tinta"
            >
              Política de privacidad
            </Link>
            <Link
              to="/soporte"
              className="transition-colors hover:text-portada-tinta"
            >
              Soporte
            </Link>
          </span>
        </footer>
      </div>

      {/* ── El bloque oscuro (solo escritorio; se queda mientras se baja) ── */}
      <aside
        className="sticky top-4 isolate hidden h-[calc(100dvh-2rem)] w-[min(42%,620px)] shrink-0 flex-col justify-between overflow-hidden rounded-[36px] p-12 lg:flex xl:p-14"
        style={{ backgroundColor: NOCHE }}
      >
        <div
          aria-hidden
          className="portada-aparece absolute inset-0 -z-10 opacity-90"
        >
          <CampoDePuntos
            escena="marea"
            fondo={NOCHE}
            tintas={['#062460', '#0D4CC0', '#2F86F0']}
            celda={7}
            semilla={11}
            intensidad={0.6}
          />
          <div className="absolute inset-0 bg-[radial-gradient(ellipse_at_top_left,rgba(2,11,36,0.95)_25%,transparent_70%)]" />
        </div>

        <Entra retraso={200}>
          <Rotulo tono="oscuro">Lo que recibes</Rotulo>
        </Entra>

        <Entra retraso={360}>
          <p className="portada-titular max-w-[12ch] !text-[clamp(2.4rem,1.3rem+2.4vw,3.8rem)] text-white">
            Atiendes hoy.{' '}
            <em className="portada-serif text-portada-cielo-2">
              Cobras completo.
            </em>
          </p>
          <ul className="mt-8 flex max-w-[38ch] flex-col gap-3.5">
            {PROMESAS.map((p) => (
              <li
                key={p.corta}
                className="flex gap-3 text-[1rem] leading-snug text-white/75"
              >
                <span
                  aria-hidden
                  className="mt-0.5 grid size-5 shrink-0 place-items-center rounded-full bg-white/10 text-portada-cielo-2"
                >
                  <Check className="size-3" strokeWidth={3} />
                </span>
                {p.larga}
              </li>
            ))}
          </ul>
        </Entra>
      </aside>
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

/** La solicitud ya llegó: qué pasa ahora. */
function Recibida({ solicitud }: { solicitud: SolicitudEnviada }) {
  return (
    <div role="status" className="portada-entra pt-4 sm:pt-10">
      <span
        aria-hidden
        className="grid size-14 place-items-center rounded-full bg-portada-cielo-3 text-portada-azul"
      >
        <CircleCheck className="size-7" />
      </span>
      <Rotulo className="mt-8">Solicitud enviada</Rotulo>
      <h1 className="portada-titular mt-5 !text-[clamp(2.2rem,1.5rem+2.4vw,3.4rem)] text-portada-tinta">
        Recibimos tu{' '}
        <em className="portada-serif portada-degradado pr-[0.06em]">
          solicitud.
        </em>
      </h1>
      <p className="portada-entrada mt-5 max-w-[48ch] text-portada-tinta-2">
        La revisamos y te escribimos a{' '}
        <span className="break-all font-medium text-portada-tinta">
          {solicitud.email}
        </span>{' '}
        o al{' '}
        <span className="whitespace-nowrap font-medium text-portada-tinta">
          {solicitud.phone}
        </span>{' '}
        para activar tu cuenta.
      </p>
      {solicitud.capacitacion && (
        <p className="mt-4 max-w-[48ch] rounded-2xl border border-portada-linea bg-portada-niebla px-4 py-3.5 text-[0.95rem] leading-relaxed text-portada-tinta-2">
          Anotamos tu capacitación presencial para el{' '}
          <span className="font-medium text-portada-tinta">
            {diaYHora(solicitud.capacitacion)}
          </span>
          .
        </p>
      )}
      <div className="mt-9">
        <Boton to="/">Volver a la portada</Boton>
      </div>
    </div>
  )
}
