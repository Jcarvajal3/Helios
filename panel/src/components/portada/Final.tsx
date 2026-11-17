import { Link } from '@tanstack/react-router'
import { ArrowUpRight, Plus } from 'lucide-react'

import { PREGUNTAS } from './datos'
import { Boton, Lienzo, Revelar, Rotulo } from './piezas'
import { HeliosLogo } from '@/components/HeliosLogo'
import { operador } from '@/config/legal'
import { REDES } from '@/config/sitio'

/**
 * PREGUNTAS, EL CIERRE Y EL PIE.
 */

/**
 * Las preguntas frecuentes. La portada usa las suyas; cada página para
 * buscadores (`Guia`) pasa su lista y su titular. Las respuestas van en el
 * HTML aunque estén cerradas: Google las lee igual.
 */
export function Preguntas({
  lista = PREGUNTAS,
  titular = { antes: 'Lo que todo el mundo', enfasis: 'pregunta.' },
}: {
  lista?: ReadonlyArray<{ pregunta: string; respuesta: string }>
  titular?: { antes: string; enfasis: string }
} = {}) {
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
                {titular.antes}{' '}
                <em className="portada-serif portada-acento pr-[0.06em]">
                  {titular.enfasis}
                </em>
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
            {lista.map((p, i) => (
              <Revelar key={p.pregunta} retraso={i * 60}>
                {/* `<details>` nativo, como en Ronda: se abre sin JavaScript y el
                    teclado ya sabe manejarlo. El CSS anima la altura donde se puede. */}
                <details className="portada-pregunta group rounded-[28px] bg-white shadow-[0_0_0_1px_rgba(2,11,36,0.04),0_10px_24px_-18px_rgba(10,60,160,0.3)] transition-shadow duration-500 open:shadow-[0_0_0_1px_rgba(21,126,253,0.25),0_30px_60px_-30px_rgba(10,60,160,0.45)]">
                  <summary className="flex cursor-pointer list-none items-center justify-between gap-6 px-6 py-6 sm:px-7 [&::-webkit-details-marker]:hidden">
                    {/* La pregunta es un `<h3>`: buscadores y lectores de
                        pantalla la leen como pregunta, no como texto suelto. */}
                    <h3 className="flex items-baseline gap-4">
                      <span aria-hidden className="portada-numero portada-acento w-7 shrink-0 text-[1.6rem] leading-none">
                        {i + 1}
                      </span>
                      <span className="text-[1.12rem] font-medium leading-snug tracking-[-0.025em] text-portada-tinta">
                        {p.pregunta}
                      </span>
                    </h3>
                    <span
                      aria-hidden
                      className="grid size-10 shrink-0 place-items-center rounded-full bg-portada-niebla text-portada-tinta transition-all duration-500 group-open:rotate-[135deg] group-open:bg-portada-tinta group-open:text-white"
                    >
                      <Plus className="size-4" />
                    </span>
                  </summary>
                  <p className="max-w-[60ch] px-6 pb-7 pl-[4.25rem] text-[1rem] leading-relaxed text-portada-tinta-2 sm:pl-[4.5rem]">
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
    <section className="directorio-cielo portada-cierre relative isolate overflow-clip">
      {/* El amanecer del sistema (el mismo de /directorio): el sol de Helios
          sale detrás del horizonte, al final de la página. */}
      <div aria-hidden className="directorio-rayos" />
      <div aria-hidden className="directorio-sol" />
      <div aria-hidden className="directorio-horizonte" />
      <Lienzo className="relative flex flex-col items-center pb-[clamp(15rem,24vw,21rem)] pt-28 text-center sm:pt-40">
        <Revelar>
          <Rotulo>Medicina · Odontología · Cosmetología</Rotulo>
        </Revelar>
        <Revelar retraso={100}>
          <h2 className="directorio-titular mt-7 max-w-[13ch] text-portada-tinta">
            La mitad hoy,{' '}
            <em className="portada-serif portada-acento pr-[0.06em]">
              el resto en dos cuotas.
            </em>
          </h2>
        </Revelar>
        <Revelar retraso={200}>
          <div className="mt-10 flex flex-wrap justify-center gap-3">
            <Boton to="/directorio">Encuentra tu médico</Boton>
            <Boton to="/medicos" tono="contorno">
              Soy médico
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
              Tu salud hoy: la mitad en la consulta y el resto en dos cuotas.
            </p>
          </div>

          <nav
            aria-label="Enlaces del pie"
            className="grid grid-cols-2 gap-x-12 gap-y-10 sm:flex sm:flex-wrap sm:gap-x-16"
          >
            <div>
              <p className="portada-etiqueta text-portada-tinta-3">Pacientes</p>
              <ul className="mt-4 flex flex-col gap-3">
                <li>
                  <Link to="/pacientes" className={enlace}>
                    Pagar en cuotas
                  </Link>
                </li>
                <li>
                  <Link to="/directorio" className={enlace}>
                    Directorio de médicos
                  </Link>
                </li>
                <li>
                  <Link to="/consulta-medica-en-cuotas" className={enlace}>
                    Consulta médica en cuotas
                  </Link>
                </li>
                <li>
                  <Link to="/odontologia-en-cuotas" className={enlace}>
                    Odontología en cuotas
                  </Link>
                </li>
                <li>
                  <Link to="/cosmetologia-en-cuotas" className={enlace}>
                    Cosmetología en cuotas
                  </Link>
                </li>
              </ul>
            </div>
            <div>
              <p className="portada-etiqueta text-portada-tinta-3">
                Médicos y centros
              </p>
              <ul className="mt-4 flex flex-col gap-3">
                <li>
                  <Link to="/medicos" className={enlace}>
                    Cómo funciona
                  </Link>
                </li>
                <li>
                  <Link to="/afiliacion" className={enlace}>
                    Quiero afiliarme
                  </Link>
                </li>
                <li>
                  <Link to="/login" className={enlace}>
                    Entrar
                  </Link>
                </li>
              </ul>
            </div>
            <div>
              <p className="portada-etiqueta text-portada-tinta-3">Helios</p>
              <ul className="mt-4 flex flex-col gap-3">
                <li>
                  <Link to="/soporte" className={enlace}>
                    Soporte
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
