import { Link } from '@tanstack/react-router'

import type { CSSProperties, ReactNode } from 'react'
import { HeliosLogo } from '@/components/HeliosLogo'
import { RESPONSABLE } from '@/config/legal'

/**
 * LA PORTADA — todo lo que se lee en `/`.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Versión corta de la portada de Ronda (`Ronda-panel/src/components/portada`):
 * el mismo orden —qué es, cómo se usa, las reglas enteras, preguntas— sin la
 * app, porque Helios no la tiene. Le habla al PACIENTE; la clínica tiene una
 * tarjeta abajo, como el local en Ronda.
 *
 * Las cifras salen de las reglas confirmadas (docs/00 §1 y §1.1). Si una
 * cambia, esta página miente y hay que venir a arreglarla:
 *
 *   · 0% inicial, 2 cuotas a +7 y +14 días
 *   · Servicio 20% + IVA 16% sobre el servicio, solo al paciente
 *   · Disponible del nivel 1: $350; se libera al pagar las dos cuotas
 *   · $2 por cuota vencida tras 3 días de gracia; congelado desde el día 1
 *   · La clínica cobra el 100%, en dos mitades, los lunes
 *
 * Y la regla de Helios que aquí también vale: **ningún total incluye el
 * servicio.** El ejemplo enseña las cuotas y el servicio como línea aparte,
 * nunca "total a pagar".
 */

// ── Piezas ────────────────────────────────────────────────────────────────

function Seccion({
  id,
  children,
  className = '',
}: {
  id?: string
  children: ReactNode
  className?: string
}) {
  return (
    <section
      id={id}
      className={`mx-auto w-full max-w-[var(--portada-ancho)] px-4 py-16 sm:px-8 lg:py-24 ${className}`}
    >
      {children}
    </section>
  )
}

function Rotulo({ children }: { children: ReactNode }) {
  return (
    <p className="type-portada-eyebrow text-primary">
      <span className="mr-2 inline-block size-1.5 translate-y-[-2px] rounded-full bg-primary align-middle" />
      {children}
    </p>
  )
}

function Cabecera({
  rotulo,
  titulo,
  children,
}: {
  rotulo: string
  titulo: ReactNode
  children?: ReactNode
}) {
  return (
    <div>
      <Rotulo>{rotulo}</Rotulo>
      <h2 className="type-portada-headline mt-5 max-w-[22ch] text-balance text-on-surface">
        {titulo}
      </h2>
      {children ? (
        <p className="type-portada-lead mt-5 max-w-[var(--portada-lectura)] text-on-surface-variant">
          {children}
        </p>
      ) : null}
    </div>
  )
}

function Boton({
  children,
  to,
  href,
  tono = 'lleno',
}: {
  children: ReactNode
  to?: string
  href?: string
  tono?: 'lleno' | 'contorno'
}) {
  const tonos = {
    lleno: 'bg-primary text-on-primary hover:bg-primary-dim',
    contorno:
      'border border-outline-variant text-on-surface hover:border-outline hover:bg-surface-container',
  }
  const forma = `inline-flex h-12 items-center justify-center rounded-[var(--radius-portada-control)] px-6 type-portada-body font-semibold transition-colors duration-[var(--transition-fast)] ${tonos[tono]}`

  return to ? (
    <Link to={to} className={forma}>
      {children}
    </Link>
  ) : (
    <a href={href} className={forma}>
      {children}
    </a>
  )
}

/** Entra al cargar, escalonado. Solo en la primera pantalla. */
function Entra({
  retraso = 0,
  children,
}: {
  retraso?: number
  children: ReactNode
}) {
  return (
    <div
      className="portada-entra"
      style={{ '--retraso': `${retraso}ms` } as CSSProperties}
    >
      {children}
    </div>
  )
}

// ══════════════════════════════════════════════════════════════════════════
// 1 · El menú
// ══════════════════════════════════════════════════════════════════════════

const MENU = [
  { href: '#como-funciona', texto: 'Cómo funciona' },
  { href: '#reglas', texto: 'Las reglas' },
  { href: '#preguntas', texto: 'Preguntas' },
]

export function Menu() {
  return (
    <header className="sticky top-0 z-50 px-4 pt-4">
      <nav className="mx-auto flex w-full max-w-[var(--portada-ancho)] items-center justify-between gap-6 rounded-[var(--radius-portada-control)] border border-outline-variant bg-[color-mix(in_srgb,var(--color-shell-canvas)_80%,transparent)] py-2.5 pl-5 pr-2.5 backdrop-blur-xl">
        <a
          href="#arriba"
          aria-label="Helios, volver arriba"
          className="flex shrink-0 items-center"
        >
          <HeliosLogo height={26} />
        </a>

        <ul className="hidden items-center gap-8 md:flex">
          {MENU.map((item) => (
            <li key={item.href}>
              <a
                href={item.href}
                className="type-portada-body text-on-surface-variant transition-colors duration-[var(--transition-fast)] hover:text-on-surface"
              >
                {item.texto}
              </a>
            </li>
          ))}
        </ul>

        {/* "Entrar" es del personal de la clínica: el panel no tiene otra puerta. */}
        <Link
          to="/login"
          className="inline-flex h-10 shrink-0 items-center rounded-[var(--radius-portada-control)] bg-primary px-5 type-portada-body font-semibold text-on-primary transition-colors duration-[var(--transition-fast)] hover:bg-primary-dim"
        >
          Entrar
        </Link>
      </nav>
    </header>
  )
}

// ══════════════════════════════════════════════════════════════════════════
// 2 · La primera pantalla
// ══════════════════════════════════════════════════════════════════════════

/** El ejemplo del plan (docs/00 §1.1): una consulta de $100. */
const EJEMPLO = [
  { concepto: 'Hoy, en la clínica', monto: '$0,00' },
  { concepto: 'Cuota 1 · a los 7 días', monto: '$61,60' },
  { concepto: 'Cuota 2 · a los 14 días', monto: '$61,60' },
]

export function Heroe() {
  return (
    <div id="arriba" className="relative overflow-hidden">
      <div
        aria-hidden
        className="portada-resplandor pointer-events-none absolute left-1/2 top-[-20%] -z-10 size-[760px] -translate-x-1/2 rounded-full blur-3xl"
      />

      <Seccion className="relative grid items-center gap-12 pt-14 lg:grid-cols-[1.15fr_0.85fr] lg:gap-16 lg:pt-20">
        <div>
          <Entra>
            <Rotulo>Para tus consultas médicas</Rotulo>
          </Entra>

          <Entra retraso={80}>
            <h1 className="type-portada-display mt-6 text-balance text-on-surface">
              <span className="block">Tu consulta hoy.</span>
              <span className="block text-primary">Págala en dos semanas.</span>
            </h1>
          </Entra>

          <Entra retraso={160}>
            <p className="type-portada-lead mt-6 max-w-[52ch] text-on-surface-variant">
              En las clínicas afiliadas pides pagar con Helios en recepción y la
              consulta se divide en dos cuotas: una a los 7 días y otra a los
              14. Hoy no pagas nada, y no hay app que descargar.
            </p>
          </Entra>

          <Entra retraso={240}>
            <div className="mt-9 flex flex-wrap gap-3">
              <Boton href="#como-funciona">Ver cómo funciona</Boton>
              <Boton href="#clinicas" tono="contorno">
                Tengo una clínica
              </Boton>
            </div>
          </Entra>
        </div>

        <Entra retraso={320}>
          <div className="rounded-[var(--radius-portada-card)] border border-outline-variant bg-surface p-6 shadow-[0_24px_60px_-28px_color-mix(in_srgb,var(--color-shadow)_35%,transparent)] sm:p-7">
            <p className="type-portada-eyebrow text-on-surface-faint">
              Ejemplo
            </p>
            <p className="type-portada-title mt-3 text-on-surface">
              Una consulta de $100
            </p>

            <ul className="mt-6 divide-y divide-outline-variant border-y border-outline-variant">
              {EJEMPLO.map((fila) => (
                <li
                  key={fila.concepto}
                  className="flex items-baseline justify-between gap-4 py-3.5"
                >
                  <span className="type-portada-body text-on-surface-variant">
                    {fila.concepto}
                  </span>
                  <span className="font-display text-lg font-semibold tabular-nums text-on-surface">
                    {fila.monto}
                  </span>
                </li>
              ))}
            </ul>

            <p className="mt-5 text-sm leading-relaxed text-on-surface-faint">
              Cada cuota incluye el servicio de Helios: 20% de la consulta más
              IVA ($23,20 en este ejemplo). En dólares BCV; pagas en bolívares a
              la tasa del día en que pagas.
            </p>
          </div>
        </Entra>
      </Seccion>
    </div>
  )
}

// ══════════════════════════════════════════════════════════════════════════
// 3 · Cómo funciona
// ══════════════════════════════════════════════════════════════════════════

const PASOS = [
  {
    n: '01',
    titulo: 'Lo pides en recepción',
    texto:
      'La secretaria te registra con tu cédula en un par de minutos y te enseña las dos cuotas con sus fechas antes de confirmar.',
  },
  {
    n: '02',
    titulo: 'Te llega el comprobante',
    texto:
      'Por correo, en segundos: la consulta, tus dos cuotas, cuándo vence cada una y cómo pagarlas.',
  },
  {
    n: '03',
    titulo: 'Pagas y nos avisas',
    texto:
      'Por Pago Móvil o transferencia, y nos mandas el comprobante por WhatsApp. Te escribimos antes de cada fecha.',
  },
]

export function ComoFunciona() {
  return (
    <Seccion id="como-funciona">
      <Cabecera
        rotulo="Cómo funciona"
        titulo="Tres pasos, y el primero lo da la clínica."
      >
        Sin cuenta, sin contraseña y sin app. Todo lo que necesitas saber llega
        a tu correo.
      </Cabecera>

      <div className="mt-12 grid gap-4 md:grid-cols-3">
        {PASOS.map((paso) => (
          <div
            key={paso.n}
            className="rounded-[var(--radius-portada-card)] border border-outline-variant bg-surface p-6 sm:p-7"
          >
            <p className="font-display text-sm font-semibold tracking-[0.06em] text-primary">
              {paso.n}
            </p>
            <h3 className="type-portada-title mt-5 text-on-surface">
              {paso.titulo}
            </h3>
            <p className="type-portada-body mt-3 text-on-surface-variant">
              {paso.texto}
            </p>
          </div>
        ))}
      </div>
    </Seccion>
  )
}

// ══════════════════════════════════════════════════════════════════════════
// 4 · Las reglas
// ══════════════════════════════════════════════════════════════════════════

const REGLAS = [
  {
    titulo: 'Lo que cuesta, dicho una vez',
    texto:
      'El 20% de la consulta más el IVA de ese 20%, repartido en las dos cuotas. Sin inscripción ni mensualidad.',
  },
  {
    titulo: 'Las dos fechas no se mueven',
    texto:
      'A los 7 y a los 14 días de la consulta. Quedan escritas en el comprobante desde el primer minuto.',
  },
  {
    titulo: 'Si te retrasas',
    texto:
      'Desde el día siguiente no puedes financiar otra consulta hasta ponerte al día. Tras 3 días de gracia se suman $2 por cada cuota vencida.',
  },
  {
    titulo: 'Nada se cobra solo',
    texto:
      'No guardamos tarjetas ni sacamos dinero de ninguna cuenta. Tú pagas cuando toca y nos mandas el comprobante.',
  },
  {
    titulo: 'Hasta $350 disponibles',
    texto:
      'Lo que usaste en una consulta vuelve a estar disponible cuando pagas sus dos cuotas.',
  },
  {
    titulo: 'Mayor de 18, con cédula',
    texto:
      'Si quien se atiende es menor de edad, el financiamiento va a nombre de su representante.',
  },
]

export function Reglas() {
  return (
    <Seccion id="reglas">
      <Cabecera rotulo="Sin letra pequeña" titulo="Las reglas, todas, aquí.">
        Son seis y caben en una pantalla. Las mismas van en tu comprobante.
      </Cabecera>

      <div className="mt-12 grid gap-px overflow-hidden rounded-[var(--radius-portada-card)] border border-outline-variant bg-outline-variant sm:grid-cols-2 lg:grid-cols-3">
        {REGLAS.map((regla) => (
          <div key={regla.titulo} className="bg-shell-canvas p-6 sm:p-7">
            <h3 className="type-portada-title text-on-surface">
              {regla.titulo}
            </h3>
            <p className="type-portada-body mt-3 text-on-surface-variant">
              {regla.texto}
            </p>
          </div>
        ))}
      </div>
    </Seccion>
  )
}

// ══════════════════════════════════════════════════════════════════════════
// 5 · Preguntas
// ══════════════════════════════════════════════════════════════════════════

const PREGUNTAS = [
  {
    pregunta: '¿Dónde puedo usarlo?',
    respuesta:
      'En las clínicas y consultorios afiliados a Helios. Pregunta en recepción antes de la consulta.',
  },
  {
    pregunta: '¿Tengo que descargar algo o crear una cuenta?',
    respuesta:
      'No. La secretaria te registra con tu cédula, tu correo y tu teléfono. El comprobante te llega por correo y hablamos contigo por WhatsApp.',
  },
  {
    pregunta: '¿Cuánto pago en bolívares?',
    respuesta:
      'Las cuotas están en dólares BCV. Pagas en bolívares a la tasa oficial del día en que haces el pago.',
  },
  {
    pregunta: '¿La clínica ve lo que debo?',
    respuesta:
      'No. Ninguna clínica ve tus cuotas, si estás al día ni dónde te atendiste antes. Solo sabe si Helios puede financiar esa consulta.',
  },
]

export function Preguntas() {
  return (
    <Seccion id="preguntas">
      <div className="grid gap-10 lg:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)] lg:gap-16">
        <Cabecera rotulo="Preguntas" titulo="Lo que todo el mundo pregunta." />

        <div className="border-t border-outline-variant">
          {PREGUNTAS.map((p) => (
            // `<details>` nativo, como en Ronda: se abre sin JavaScript y el
            // teclado ya sabe manejarlo.
            <details
              key={p.pregunta}
              className="group border-b border-outline-variant py-5"
            >
              <summary className="flex cursor-pointer list-none items-center justify-between gap-6 [&::-webkit-details-marker]:hidden">
                <span className="type-portada-title text-on-surface">
                  {p.pregunta}
                </span>
                <span
                  aria-hidden
                  className="grid size-8 shrink-0 place-items-center rounded-full border border-outline-variant text-on-surface-variant transition-transform duration-[var(--transition-fast)] group-open:rotate-45"
                >
                  <svg viewBox="0 0 16 16" className="size-3.5">
                    <path
                      d="M8 1v14M1 8h14"
                      stroke="currentColor"
                      strokeWidth="1.6"
                      strokeLinecap="round"
                    />
                  </svg>
                </span>
              </summary>
              <p className="type-portada-body mt-4 max-w-[var(--portada-lectura)] text-on-surface-variant">
                {p.respuesta}
              </p>
            </details>
          ))}
        </div>
      </div>
    </Seccion>
  )
}

// ══════════════════════════════════════════════════════════════════════════
// 6 · Para clínicas
// ══════════════════════════════════════════════════════════════════════════

/**
 * La única tarjeta dirigida a la clínica. Mientras no haya canal de soporte
 * (`RESPONSABLE.soporte`, H11) no se ofrece un "Escríbenos" que no lleva a
 * ningún sitio: queda solo la puerta del panel.
 */
export function Clinicas() {
  return (
    <Seccion id="clinicas">
      <div className="flex flex-col gap-8 rounded-[var(--radius-portada-card)] border border-primary-container bg-primary-container/50 p-7 sm:p-10 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <Rotulo>Para clínicas</Rotulo>
          <h2 className="type-portada-headline mt-5 max-w-[20ch] text-on-surface">
            Cobras la consulta completa.
          </h2>
          <p className="type-portada-lead mt-4 max-w-[56ch] text-on-surface-variant">
            La clínica recibe el 100% del precio, sin comisión, en dos mitades
            que se pagan los lunes, pague el paciente a tiempo o no.
          </p>
        </div>

        <div className="flex shrink-0 flex-wrap gap-3">
          {RESPONSABLE.soporte ? (
            <Boton
              href={`mailto:${RESPONSABLE.soporte}?subject=${encodeURIComponent(
                'Quiero ofrecer Helios en mi clínica',
              )}`}
            >
              Escríbenos
            </Boton>
          ) : null}
          <Boton to="/login" tono={RESPONSABLE.soporte ? 'contorno' : 'lleno'}>
            Entrar al panel
          </Boton>
        </div>
      </div>
    </Seccion>
  )
}

// ══════════════════════════════════════════════════════════════════════════
// 7 · El pie
// ══════════════════════════════════════════════════════════════════════════

export function Pie() {
  const enlace =
    'type-portada-body text-on-surface-variant transition-colors duration-[var(--transition-fast)] hover:text-on-surface'

  return (
    <footer className="border-t border-outline-variant">
      <div className="mx-auto flex w-full max-w-[var(--portada-ancho)] flex-col gap-8 px-4 py-12 sm:px-8 md:flex-row md:items-start md:justify-between">
        <div>
          <HeliosLogo height={26} />
          <p className="type-portada-body mt-4 max-w-[30ch] text-on-surface-faint">
            Tu consulta hoy, en dos cuotas.
          </p>
        </div>

        <ul className="flex flex-wrap gap-x-8 gap-y-3">
          <li>
            <Link to="/soporte" className={enlace}>
              Soporte
            </Link>
          </li>
          <li>
            <Link to="/legal/privacidad" className={enlace}>
              Política de privacidad
            </Link>
          </li>
          <li>
            <Link to="/login" className={enlace}>
              Entrar al panel
            </Link>
          </li>
        </ul>
      </div>

      <div className="mx-auto w-full max-w-[var(--portada-ancho)] px-4 pb-12 sm:px-8">
        <p className="border-t border-outline-variant pt-6 text-[0.8125rem] leading-relaxed text-on-surface-faint">
          {RESPONSABLE.razonSocial
            ? `${RESPONSABLE.razonSocial} · RIF ${RESPONSABLE.rif} · `
            : ''}
          Venezuela · Solo para mayores de 18 años.
        </p>
      </div>
    </footer>
  )
}
