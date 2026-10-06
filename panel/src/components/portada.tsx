import { Link } from '@tanstack/react-router'

import type { CSSProperties, ReactNode } from 'react'
import { HeliosLogo } from '@/components/HeliosLogo'
import { enlaceAfiliacion, operador } from '@/config/legal'

/**
 * LA PORTADA — todo lo que se lee en `/`.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Versión corta de la portada de Ronda (`Ronda-panel/src/components/portada`)
 * con la información del negocio que publicó Javier el 2026-10-06. Le habla a
 * dos públicos, cada uno con su sección:
 *
 *   · para todos: qué es Helios, qué cubre y los tres pasos;
 *   · médicos y centros: pago garantizado, a los 8 y 15 días, sin costo,
 *     registro simple, sin permanencia, «Quiero afiliarme»;
 *   · pacientes: dos cuotas a los 7 y 14 días, comisión del 12% explicada,
 *     límite inicial de $150 y un ejemplo con números.
 *
 * Las cifras salen de las reglas vigentes (docs/00 §1 y §1.1). Si una cambia,
 * esta página miente y hay que venir a arreglarla:
 *
 *   · 0 al registrar, 2 cuotas a +7 y +14 días
 *   · Comisión de servicio 12% + IVA 16% sobre la comisión, la paga el paciente
 *   · Límite inicial $150 (no decir que «crece»: no hay reglas para subirlo)
 *   · $2 por cuota vencida tras 3 días de gracia
 *   · La clínica cobra el 100%, en dos mitades, a los 8 y 15 días
 *
 * Lo que NO se dice aquí (decisión de 2026-10-06): «préstamo» ni
 * «financiamiento» (se dice «pago en cuotas» y «comisión de servicio»), la
 * tasa del euro, cómo se verifica o no al paciente, quién firma los contratos
 * ni nada interno del equipo.
 */

// ── El ejemplo ────────────────────────────────────────────────────────────

const CONSULTA = 100
const COMISION_PCT = 12
const IVA_PCT = 16

/** Al céntimo, al estilo venezolano: 113.92 → «$113,92». */
function dolares(n: number): string {
  const [entero, centimos] = (Math.round(n * 100) / 100).toFixed(2).split('.')
  return `$${entero.replace(/\B(?=(\d{3})+(?!\d))/g, '.')},${centimos}`
}

const comision = Math.round(CONSULTA * COMISION_PCT) / 100
const iva = Math.round(comision * IVA_PCT) / 100
const total = CONSULTA + comision + iva
const cuota = Math.round((total / 2) * 100) / 100

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
  externo = false,
  tono = 'lleno',
}: {
  children: ReactNode
  to?: string
  href?: string
  externo?: boolean
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
    <a
      href={href}
      className={forma}
      {...(externo ? { target: '_blank', rel: 'noopener noreferrer' } : {})}
    >
      {children}
    </a>
  )
}

/** «Quiero afiliarme»: al WhatsApp de Helios, o a soporte si aún no hay número. */
function BotonAfiliarme({ tono = 'lleno' }: { tono?: 'lleno' | 'contorno' }) {
  const { href, externo } = enlaceAfiliacion()
  return externo ? (
    <Boton href={href} externo tono={tono}>
      Quiero afiliarme
    </Boton>
  ) : (
    <Boton to={href} tono={tono}>
      Quiero afiliarme
    </Boton>
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

/** Una cuadrícula de tarjetas de texto, con las líneas finas entre ellas. */
function Rejilla({
  items,
  columnas = 'sm:grid-cols-2 lg:grid-cols-3',
}: {
  items: ReadonlyArray<{ titulo: string; texto: string }>
  columnas?: string
}) {
  return (
    <div
      className={`grid gap-px overflow-hidden rounded-[var(--radius-portada-card)] border border-outline-variant bg-outline-variant ${columnas}`}
    >
      {items.map((item) => (
        <div key={item.titulo} className="bg-shell-canvas p-6 sm:p-7">
          <h3 className="type-portada-title text-on-surface">{item.titulo}</h3>
          <p className="type-portada-body mt-3 text-on-surface-variant">
            {item.texto}
          </p>
        </div>
      ))}
    </div>
  )
}

// ══════════════════════════════════════════════════════════════════════════
// 1 · El menú
// ══════════════════════════════════════════════════════════════════════════

const MENU = [
  { href: '#como-funciona', texto: 'Cómo funciona' },
  { href: '#medicos', texto: 'Médicos y centros' },
  { href: '#pacientes', texto: 'Pacientes' },
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

        <ul className="hidden items-center gap-8 lg:flex">
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

        {/* "Entrar" es de los médicos y del personal de los centros. */}
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
// 2 · La primera pantalla: qué es
// ══════════════════════════════════════════════════════════════════════════

const ESPECIALIDADES = ['Medicina', 'Odontología', 'Cosmetología']

const RESUMEN_EJEMPLO = [
  { concepto: 'Hoy, en la consulta', monto: dolares(0) },
  { concepto: 'Cuota 1 · a los 7 días', monto: dolares(cuota) },
  { concepto: 'Cuota 2 · a los 14 días', monto: dolares(cuota) },
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
            <Rotulo>Salud privada en cuotas</Rotulo>
          </Entra>

          <Entra retraso={80}>
            <h1 className="type-portada-display mt-6 text-balance text-on-surface">
              <span className="block">Tu consulta hoy.</span>
              <span className="block text-primary">Págala en dos cuotas.</span>
            </h1>
          </Entra>

          <Entra retraso={160}>
            <p className="type-portada-lead mt-6 max-w-[52ch] text-on-surface-variant">
              Helios es una forma de pagar consultas y tratamientos de salud
              privada en cuotas. Hoy no pagas nada: pagas en dos cuotas, a los
              7 y a los 14 días.
            </p>
          </Entra>

          <Entra retraso={200}>
            <ul
              aria-label="Especialidades"
              className="mt-6 flex flex-wrap gap-2"
            >
              {ESPECIALIDADES.map((e) => (
                <li
                  key={e}
                  className="rounded-full border border-outline-variant bg-surface px-3.5 py-1.5 type-portada-body text-on-surface"
                >
                  {e}
                </li>
              ))}
            </ul>
          </Entra>

          <Entra retraso={240}>
            <div className="mt-9 flex flex-wrap gap-3">
              <Boton href="#como-funciona">Ver cómo funciona</Boton>
              <BotonAfiliarme tono="contorno" />
            </div>
          </Entra>
        </div>

        <Entra retraso={320}>
          <div className="rounded-[var(--radius-portada-card)] border border-outline-variant bg-surface p-6 shadow-[0_24px_60px_-28px_color-mix(in_srgb,var(--color-shadow)_35%,transparent)] sm:p-7">
            <p className="type-portada-eyebrow text-on-surface-faint">
              Ejemplo
            </p>
            <p className="type-portada-title mt-3 text-on-surface">
              Una consulta de {dolares(CONSULTA).replace(',00', '')}
            </p>

            <ul className="mt-6 divide-y divide-outline-variant border-y border-outline-variant">
              {RESUMEN_EJEMPLO.map((fila) => (
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
              Las cuotas incluyen la comisión de servicio: {COMISION_PCT}% de la
              consulta más el IVA de la comisión ({dolares(comision + iva)} en
              este ejemplo).{' '}
              <a
                href="#pacientes"
                className="text-primary underline-offset-4 hover:underline"
              >
                Ver el detalle
              </a>
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
    titulo: 'El médico registra la consulta',
    texto:
      'Desde la plataforma de Helios o por WhatsApp, con la cédula del paciente y el monto. Toma un par de minutos.',
  },
  {
    n: '02',
    titulo: 'El paciente confirma',
    texto:
      'Le llega un WhatsApp con el monto, la comisión de servicio y sus dos cuotas con fecha. Responde «Sí» y el comprobante le llega por correo.',
  },
  {
    n: '03',
    titulo: 'Paga en dos cuotas',
    texto:
      'A los 7 y a los 14 días, por Pago Móvil o transferencia. Le recordamos cada fecha por WhatsApp.',
  },
]

export function ComoFunciona() {
  return (
    <Seccion id="como-funciona">
      <Cabecera rotulo="Cómo funciona" titulo="Tres pasos, y listo.">
        Sin app, sin cuenta y sin contraseña, ni para el médico ni para el
        paciente.
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
// 4 · Para médicos y centros
// ══════════════════════════════════════════════════════════════════════════

const PARA_MEDICOS = [
  {
    titulo: 'Cobras a los 8 y a los 15 días',
    texto:
      'Recibes el precio de la consulta en dos partes: la mitad a los 8 días y la otra mitad a los 15.',
  },
  {
    titulo: 'No te cuesta nada',
    texto:
      'La comisión de servicio la paga el paciente. Tú recibes el 100% del precio, sin descuentos.',
  },
  {
    titulo: 'Registro simple',
    texto:
      'Registras la consulta desde la plataforma de Helios o por WhatsApp. Sin equipos ni puntos de venta.',
  },
  {
    titulo: 'Sin permanencia',
    texto: 'Puedes cancelar tu afiliación cuando quieras, con aviso previo.',
  },
]

export function Medicos() {
  return (
    <Seccion id="medicos">
      <div className="rounded-[var(--radius-portada-card)] border border-primary-container bg-primary-container/50 p-7 sm:p-10">
        <Rotulo>Para médicos y centros</Rotulo>
        <h2 className="type-portada-headline mt-5 max-w-[24ch] text-balance text-on-surface">
          Tu pago está garantizado, aunque el paciente no pague.
        </h2>
        <p className="type-portada-lead mt-5 max-w-[var(--portada-lectura)] text-on-surface-variant">
          Atiendes hoy y Helios te paga la consulta completa. El cobro al
          paciente corre por nuestra cuenta.
        </p>

        <div className="mt-10">
          <Rejilla items={PARA_MEDICOS} columnas="sm:grid-cols-2 lg:grid-cols-4" />
        </div>

        <div className="mt-9 flex flex-wrap gap-3">
          <BotonAfiliarme />
          <Boton to="/login" tono="contorno">
            Entrar a la plataforma
          </Boton>
        </div>
      </div>
    </Seccion>
  )
}

// ══════════════════════════════════════════════════════════════════════════
// 5 · Para pacientes
// ══════════════════════════════════════════════════════════════════════════

const DETALLE_EJEMPLO = [
  { concepto: 'Consulta', monto: dolares(CONSULTA) },
  { concepto: `Comisión de servicio (${COMISION_PCT}%)`, monto: dolares(comision) },
  { concepto: `IVA de la comisión (${IVA_PCT}%)`, monto: dolares(iva) },
]

const PARA_PACIENTES = [
  {
    titulo: 'Dos cuotas, a los 7 y a los 14 días',
    texto:
      'Sin inicial. Las fechas van en el mensaje que confirmas y en tu comprobante, y no se mueven.',
  },
  {
    titulo: `Comisión de servicio del ${COMISION_PCT}%`,
    texto: `Es el ${COMISION_PCT}% del monto de la consulta, más el IVA de esa comisión, y va incluida en tus cuotas. Sin inscripción ni mensualidad.`,
  },
  {
    titulo: 'Límite inicial de $150',
    texto:
      'Es lo máximo que puedes tener en cuotas a la vez. Lo que usaste vuelve a estar disponible cuando pagas las dos cuotas.',
  },
  {
    titulo: 'Pagas en bolívares',
    texto:
      'Las cuotas están en dólares. Pagas en bolívares a la tasa oficial del BCV del día en que pagas.',
  },
  {
    titulo: 'Si te retrasas',
    texto:
      'No puedes registrar otro pago en cuotas hasta ponerte al día. Tras 3 días de gracia se suman $2 por cada cuota vencida.',
  },
  {
    titulo: 'Mayor de 18, con cédula',
    texto:
      'Si quien se atiende es menor de edad, el pago en cuotas va a nombre de su representante.',
  },
]

export function Pacientes() {
  return (
    <Seccion id="pacientes">
      <div className="grid gap-10 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)] lg:items-end lg:gap-16">
        <Cabecera
          rotulo="Para pacientes"
          titulo="Lo que pagas, con todos sus números."
        >
          Una sola comisión, dicha desde el principio. Antes de confirmar ves
          el monto, la comisión y tus dos cuotas.
        </Cabecera>

        <div className="rounded-[var(--radius-portada-card)] border border-outline-variant bg-surface p-6 sm:p-7">
          <p className="type-portada-eyebrow text-on-surface-faint">
            Ejemplo · una consulta de {dolares(CONSULTA).replace(',00', '')}
          </p>

          <ul className="mt-4 divide-y divide-outline-variant border-y border-outline-variant">
            {DETALLE_EJEMPLO.map((fila) => (
              <li
                key={fila.concepto}
                className="flex items-baseline justify-between gap-4 py-3"
              >
                <span className="type-portada-body text-on-surface-variant">
                  {fila.concepto}
                </span>
                <span className="font-display font-semibold tabular-nums text-on-surface">
                  {fila.monto}
                </span>
              </li>
            ))}
            <li className="flex items-baseline justify-between gap-4 py-3">
              <span className="type-portada-body font-semibold text-on-surface">
                Total
              </span>
              <span className="font-display text-lg font-semibold tabular-nums text-on-surface">
                {dolares(total)}
              </span>
            </li>
          </ul>

          <p className="mt-4 type-portada-body text-on-surface-variant">
            Pagas <strong className="text-on-surface">{dolares(cuota)}</strong>{' '}
            a los 7 días y{' '}
            <strong className="text-on-surface">{dolares(cuota)}</strong> a los
            14. Hoy, nada.
          </p>
        </div>
      </div>

      <div className="mt-12">
        <Rejilla items={PARA_PACIENTES} />
      </div>
    </Seccion>
  )
}

// ══════════════════════════════════════════════════════════════════════════
// 6 · Preguntas
// ══════════════════════════════════════════════════════════════════════════

const PREGUNTAS = [
  {
    pregunta: '¿Dónde puedo usarlo?',
    respuesta:
      'En los consultorios y centros de salud afiliados a Helios, de medicina, odontología y cosmetología. Pregunta antes de tu consulta.',
  },
  {
    pregunta: '¿Tengo que descargar algo o crear una cuenta?',
    respuesta:
      'No. El médico te registra con tu cédula, tu correo y tu teléfono. Confirmas por WhatsApp y el comprobante te llega por correo.',
  },
  {
    pregunta: '¿Cuánto pago en bolívares?',
    respuesta:
      'Las cuotas están en dólares. Pagas en bolívares a la tasa oficial del BCV del día en que haces el pago.',
  },
  {
    pregunta: '¿El médico ve lo que debo?',
    respuesta:
      'No. Ningún médico ni centro ve tus cuotas, si estás al día ni dónde te atendiste antes. Solo sabe si puedes pagar esa consulta en cuotas.',
  },
  {
    pregunta: 'Soy médico: ¿qué pasa si el paciente no paga?',
    respuesta:
      'Te pagamos igual, a los 8 y a los 15 días. El cobro al paciente es responsabilidad de Helios.',
  },
  {
    pregunta: 'Soy médico: ¿cuánto me cuesta afiliarme?',
    respuesta:
      'Nada. No hay inscripción ni mensualidad, y la comisión de servicio la paga el paciente. Tampoco hay permanencia: puedes cancelar con aviso previo.',
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
            <Link to="/legal/terminos" className={enlace}>
              Términos y condiciones
            </Link>
          </li>
          <li>
            <Link to="/legal/privacidad" className={enlace}>
              Política de privacidad
            </Link>
          </li>
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
        </ul>
      </div>

      <div className="mx-auto w-full max-w-[var(--portada-ancho)] px-4 pb-12 sm:px-8">
        <p className="border-t border-outline-variant pt-6 text-[0.8125rem] leading-relaxed text-on-surface-faint">
          Helios es operado por {operador()} · Venezuela · Solo para mayores de
          18 años.
        </p>
      </div>
    </footer>
  )
}
