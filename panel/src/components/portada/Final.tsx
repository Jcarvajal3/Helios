import { Link } from '@tanstack/react-router'
import { ArrowUpRight, Plus } from 'lucide-react'

import { CampoDePuntos } from './CampoDePuntos'
import { PREGUNTAS } from './datos'
import { Boton, BotonAfiliarme, Lienzo, Revelar, Rotulo } from './piezas'
import { HeliosLogo } from '@/components/HeliosLogo'
import { operador } from '@/config/legal'
import { REDES } from '@/config/sitio'

/**
 * PREGUNTAS, EL CIERRE Y EL PIE.
 */

export function Preguntas() {
  return (
    <section id="preguntas" className="relative bg-portada-niebla">
      <Lienzo className="py-24 sm:py-32">
        <div className="grid gap-12 lg:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)] lg:gap-20">
          <div className="lg:sticky lg:top-32 lg:self-start">
            <Revelar>
              <Rotulo>Preguntas</Rotulo>
            </Revelar>
            <Revelar retraso={80}>
              <h2 className="portada-titular mt-6 text-portada-tinta">
                Lo que todo el mundo{' '}
                <em className="portada-serif text-portada-azul">pregunta.</em>
              </h2>
            </Revelar>
            <Revelar retraso={160}>
              <p className="mt-7 text-[0.97rem] text-portada-tinta-2">
                ¿Te queda otra duda?{' '}
                <Link
                  to="/soporte"
                  className="inline-flex items-center gap-0.5 font-medium text-portada-azul underline-offset-4 hover:underline"
                >
                  Escríbenos <ArrowUpRight className="size-3.5" />
                </Link>
              </p>
            </Revelar>
          </div>

          <div className="flex flex-col gap-3">
            {PREGUNTAS.map((p, i) => (
              <Revelar key={p.pregunta} retraso={i * 60}>
                {/* `<details>` nativo, como en Ronda: se abre sin JavaScript y el
                    teclado ya sabe manejarlo. El CSS anima la altura donde se puede. */}
                <details className="portada-pregunta group rounded-[22px] border border-portada-linea bg-white transition-[border-color,box-shadow] duration-500 open:border-portada-azul/20 open:shadow-[0_24px_50px_-30px_rgba(0,39,112,0.3)]">
                  <summary className="flex cursor-pointer list-none items-center justify-between gap-6 px-6 py-5 [&::-webkit-details-marker]:hidden">
                    <span className="flex items-baseline gap-4">
                      <span className="portada-etiqueta text-portada-tinta-3/70">
                        0{i + 1}
                      </span>
                      <span className="text-[1.06rem] font-medium leading-snug tracking-[-0.02em] text-portada-tinta">
                        {p.pregunta}
                      </span>
                    </span>
                    <span
                      aria-hidden
                      className="grid size-9 shrink-0 place-items-center rounded-full bg-portada-niebla text-portada-tinta transition-all duration-500 group-open:rotate-[135deg] group-open:bg-portada-tinta group-open:text-white"
                    >
                      <Plus className="size-4" />
                    </span>
                  </summary>
                  <p className="max-w-[60ch] px-6 pb-6 pl-[3.6rem] text-[0.97rem] leading-relaxed text-portada-tinta-2">
                    {p.respuesta}
                  </p>
                </details>
              </Revelar>
            ))}
          </div>
        </div>
      </Lienzo>
    </section>
  )
}

export function Cierre() {
  return (
    <section className="relative isolate overflow-hidden bg-white">
      <div aria-hidden className="absolute inset-0 -z-10">
        <CampoDePuntos
          escena="sol"
          foco={[0.5, -0.32]}
          radio={0.72}
          luz={[0, 1]}
          celda={6.5}
          semilla={4}
        />
        <div className="absolute inset-x-0 top-0 h-1/2 bg-gradient-to-b from-white via-white/80 to-transparent" />
      </div>
      <Lienzo className="flex min-h-[640px] flex-col items-center pb-64 pt-28 text-center sm:min-h-[760px] sm:pt-36">
        <Revelar>
          <Rotulo>Medicina · Odontología · Cosmetología</Rotulo>
        </Revelar>
        <Revelar retraso={100}>
          <h2 className="portada-display mt-7 max-w-[14ch] text-portada-tinta">
            Tu salud hoy,{' '}
            <em className="portada-serif portada-degradado pr-[0.06em]">
              en dos cuotas.
            </em>
          </h2>
        </Revelar>
        <Revelar retraso={200}>
          <div className="mt-10 flex flex-wrap justify-center gap-3">
            <BotonAfiliarme />
            <Boton to="/login" tono="contorno">
              Entrar a la plataforma
            </Boton>
          </div>
        </Revelar>
      </Lienzo>
    </section>
  )
}

export function Pie() {
  const enlace =
    'text-[0.95rem] text-portada-tinta-2 transition-colors duration-300 hover:text-portada-tinta'

  return (
    <footer className="relative overflow-hidden border-t border-portada-linea bg-white">
      <Lienzo className="pt-16">
        <div className="flex flex-col gap-10 md:flex-row md:items-start md:justify-between">
          <div>
            <HeliosLogo height={30} color="#002770" />
            <p className="mt-4 max-w-[30ch] text-[0.95rem] text-portada-tinta-3">
              Tu salud hoy, en dos cuotas.
            </p>
          </div>

          <nav
            aria-label="Enlaces del pie"
            className="flex flex-wrap gap-x-20 gap-y-10"
          >
            <div>
              <p className="portada-etiqueta text-portada-tinta-3">Helios</p>
              <ul className="mt-4 flex flex-col gap-3">
                <li>
                  <Link to="/soporte" className={enlace}>
                    Soporte
                  </Link>
                </li>
                <li>
                  <Link to="/login" className={enlace}>
                    Entrar
                  </Link>
                </li>
                {REDES.map((r) => (
                  <li key={r.url}>
                    <a
                      href={r.url}
                      target="_blank"
                      rel="me noopener"
                      className={`${enlace} inline-flex items-center gap-0.5`}
                    >
                      {r.nombre} <ArrowUpRight className="size-3.5" />
                    </a>
                  </li>
                ))}
              </ul>
            </div>
            <div>
              <p className="portada-etiqueta text-portada-tinta-3">Legal</p>
              <ul className="mt-4 flex flex-col gap-3">
                <li>
                  <Link to="/legal/terminos" className={enlace}>
                    Términos y condiciones
                  </Link>
                </li>
                <li>
                  <Link to="/legal/privacidad" className={enlace}>
                    Política de privacidad
                  </Link>
                </li>
              </ul>
            </div>
          </nav>
        </div>

        <p className="mt-14 border-t border-portada-linea pt-6 text-[0.82rem] leading-relaxed text-portada-tinta-3">
          Helios es operado por {operador()} · Venezuela · Solo para mayores de
          18 años.
        </p>
      </Lienzo>

      {/* La marca, enorme y cortada por el borde: firma la página. */}
      <div
        aria-hidden
        className="portada-firma pointer-events-none mx-auto mt-6 w-full max-w-[1400px] select-none px-5"
      >
        <HeliosLogo
          height="auto"
          color="#002770"
          style={{ width: '100%', height: 'auto', display: 'block' }}
        />
      </div>
    </footer>
  )
}
