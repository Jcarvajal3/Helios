import { useState } from 'react'
import { Link, createFileRoute, useNavigate } from '@tanstack/react-router'
import {
  ArrowLeft,
  ArrowRight,
  CircleAlert,
  Eye,
  EyeOff,
  Loader2,
} from 'lucide-react'

import type { CSSProperties, ReactNode } from 'react'
import { HeliosLogo } from '@/components/HeliosLogo'
import { CampoDePuntos } from '@/components/portada/CampoDePuntos'
import { Rotulo } from '@/components/portada/piezas'
import { NO_INDEXAR } from '@/config/sitio'
import { fetchPlatformAdmin } from '@/features/admin/api'
import { FUENTES_DE_LA_PORTADA } from '@/lib/fuentes'
import { describeError, supabase } from '@/lib/supabase'

/**
 * Login del panel: correo y contraseña, sin verificación de correo.
 *
 * Decisión 2026-08-22: el panel deja el teléfono+OTP de la app de
 * consumidores. La cuenta la crea siempre el super admin — no hay "crear
 * cuenta" aquí (docs/00-BASES §2.9).
 *
 * Lleva el aspecto de la portada y no el del panel: es la puerta de entrada
 * desde `/`, así que va siempre en claro (`portada-raiz`, paleta fija) y con
 * su tipografía. No se indexa. A la derecha, en escritorio, un bloque oscuro
 * con el fondo de puntos de la portada y una sola frase.
 */
export const Route = createFileRoute('/login')({
  head: () => ({
    meta: [
      { title: 'Entrar · Helios' },
      ...NO_INDEXAR.meta,
      { name: 'color-scheme', content: 'light' },
    ],
    links: [FUENTES_DE_LA_PORTADA],
  }),
  component: Login,
})

const NOCHE = '#020B24'

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

/** Un campo con el aspecto de la portada: etiqueta arriba, píldora suave. */
function Campo({
  id,
  etiqueta,
  children,
}: {
  id: string
  etiqueta: string
  children: ReactNode
}) {
  return (
    <div>
      <label
        htmlFor={id}
        className="block text-[0.85rem] font-medium tracking-[-0.01em] text-portada-tinta"
      >
        {etiqueta}
      </label>
      <div className="relative mt-2">{children}</div>
    </div>
  )
}

const ENTRADA =
  'login-entrada h-[52px] w-full rounded-2xl border border-portada-linea bg-white px-4 text-[1rem] tracking-[-0.01em] text-portada-tinta placeholder:text-portada-tinta-3/60 transition-[border-color,box-shadow] duration-300 outline-none hover:border-portada-tinta/20 focus:border-portada-azul focus:shadow-[0_0_0_4px_rgba(4,94,243,0.12)]'

function Login() {
  const navigate = useNavigate()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [showPassword, setShowPassword] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function signIn() {
    setBusy(true)
    setError(null)

    const { error: err } = await supabase.auth.signInWithPassword({
      email,
      password,
    })
    if (err) {
      setBusy(false)

      // Unas credenciales malas se contestan en genérico A PROPÓSITO: decir
      // "ese correo no existe" convierte el formulario en un comprobador de
      // cuentas ajenas.
      //
      // Cualquier OTRO fallo —límite de intentos, proyecto caído, sin red— sí
      // se dice tal cual. Aplastarlos todos en "contraseña incorrecta" manda a
      // quien está en la barra a probar contraseñas durante un rato cuando el
      // problema no era esa.
      const credencialesMalas =
        err.code === 'invalid_credentials' ||
        /invalid login credentials/i.test(err.message)

      setError(
        credencialesMalas
          ? 'Correo o contraseña incorrectos.'
          : (describeError(err) ?? 'No pudimos entrar.'),
      )
      return
    }

    // Un mismo login sirve a dos paneles. Sin esto, el equipo de Helios
    // aterriza en el panel de la clínica y recibe un "esta cuenta no es de
    // una clínica" que parece un error cuando en realidad se entró bien.
    const admin = await fetchPlatformAdmin().catch(() => null)
    setBusy(false)

    void navigate({ to: admin ? '/admin' : '/registrar' })
  }

  const listo = !busy && email !== '' && password !== ''

  return (
    <div className="portada-raiz flex min-h-dvh bg-white lg:p-4">
      {/* ── El formulario ─────────────────────────────────────────────── */}
      <div className="relative isolate flex min-h-dvh flex-1 flex-col overflow-hidden px-5 sm:px-10 lg:min-h-0 lg:px-14">
        <div
          aria-hidden
          className="portada-aurora absolute -left-[30%] -top-[25%] -z-10 size-[720px] rounded-full"
        />

        <header className="flex items-center justify-between py-6">
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

        <main className="flex flex-1 items-center py-10">
          <div className="mx-auto w-full max-w-[420px]">
            <Entra>
              <Rotulo>Panel de Helios</Rotulo>
            </Entra>
            <h1 className="portada-titular mt-6 !text-[clamp(2.4rem,1.6rem+2.4vw,3.4rem)] text-portada-tinta">
              <span className="portada-linea">
                <span style={{ '--retraso': '100ms' } as CSSProperties}>
                  Entra a tu
                </span>
              </span>
              <span className="portada-linea">
                <span style={{ '--retraso': '180ms' } as CSSProperties}>
                  <em className="portada-serif portada-degradado pr-[0.06em]">
                    panel.
                  </em>
                </span>
              </span>
            </h1>
            <Entra retraso={300}>
              <p className="portada-entrada mt-5 text-portada-tinta-2">
                Usa el correo y la contraseña de tu cuenta de Helios.
              </p>
            </Entra>

            <Entra retraso={400}>
              <form
                className="mt-10 flex flex-col gap-5"
                onSubmit={(e) => {
                  e.preventDefault()
                  if (listo) void signIn()
                }}
              >
                <Campo id="email" etiqueta="Correo electrónico">
                  <input
                    id="email"
                    type="email"
                    autoComplete="email"
                    inputMode="email"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    placeholder="tu@clinica.com"
                    autoFocus
                    required
                    className={ENTRADA}
                  />
                </Campo>

                <Campo id="password" etiqueta="Contraseña">
                  <input
                    id="password"
                    type={showPassword ? 'text' : 'password'}
                    autoComplete="current-password"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    placeholder="Tu contraseña"
                    required
                    className={`${ENTRADA} pr-14`}
                  />
                  <button
                    type="button"
                    onClick={() => setShowPassword((v) => !v)}
                    aria-label={
                      showPassword ? 'Ocultar contraseña' : 'Mostrar contraseña'
                    }
                    className="absolute inset-y-0 right-1.5 my-auto grid size-10 place-items-center rounded-xl text-portada-tinta-3 transition-colors duration-300 hover:bg-portada-niebla hover:text-portada-tinta"
                  >
                    {showPassword ? <EyeOff size={18} /> : <Eye size={18} />}
                  </button>
                </Campo>

                {error ? (
                  <div
                    role="alert"
                    className="portada-burbuja-entra flex gap-3 rounded-2xl border border-[#F4C7C3] bg-[#FDF2F1] px-4 py-3.5 text-[0.9rem] leading-snug text-[#8A1C12]"
                  >
                    <CircleAlert className="mt-0.5 size-4 shrink-0" />
                    <span>
                      <span className="block font-medium">
                        No pudimos entrar
                      </span>
                      <span className="mt-0.5 block text-[#8A1C12]/85">
                        {error}
                      </span>
                    </span>
                  </div>
                ) : null}

                <button
                  type="submit"
                  disabled={!listo}
                  className="portada-boton group mt-2 inline-flex h-[52px] w-full items-center justify-center gap-2 rounded-full bg-portada-tinta pl-6 pr-2 text-[0.98rem] font-medium tracking-[-0.01em] text-white shadow-[0_10px_30px_-12px_rgba(0,39,112,0.55)] transition-[background-color,transform,box-shadow,opacity] duration-300 hover:bg-portada-marino active:scale-[0.99] disabled:cursor-not-allowed disabled:opacity-45 disabled:shadow-none disabled:hover:bg-portada-tinta"
                >
                  <span className="flex-1 text-center">
                    {busy ? 'Entrando…' : 'Iniciar sesión'}
                  </span>
                  <span
                    aria-hidden
                    className="grid size-9 place-items-center overflow-hidden rounded-full bg-white/12"
                  >
                    {busy ? (
                      <Loader2 className="size-4 animate-spin" />
                    ) : (
                      <span className="portada-boton-flecha relative block size-4">
                        <ArrowRight
                          className="absolute inset-0 size-4"
                          strokeWidth={2}
                        />
                        <ArrowRight
                          className="absolute inset-0 size-4"
                          strokeWidth={2}
                        />
                      </span>
                    )}
                  </span>
                </button>
              </form>
            </Entra>

            <Entra retraso={520}>
              <p className="mt-8 border-t border-portada-linea pt-6 text-[0.92rem] text-portada-tinta-2">
                ¿Tu consultorio aún no está afiliado?{' '}
                <Link
                  to="/afiliacion"
                  className="font-medium text-portada-azul underline-offset-4 hover:underline"
                >
                  Quiero afiliarme
                </Link>
              </p>
            </Entra>
          </div>
        </main>

        {/* La puerta pública al texto legal desde el panel. */}
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

      {/* ── El bloque oscuro (solo escritorio) ────────────────────────── */}
      <aside
        aria-hidden
        className="relative isolate hidden w-[min(46%,720px)] shrink-0 flex-col justify-between overflow-hidden rounded-[36px] p-12 lg:flex xl:p-14"
        style={{ backgroundColor: NOCHE }}
      >
        <div className="portada-aparece absolute inset-0 -z-10 opacity-90">
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
          <Rotulo tono="oscuro">Para médicos y centros</Rotulo>
        </Entra>

        <Entra retraso={360}>
          <p className="portada-titular max-w-[12ch] !text-[clamp(2.6rem,1.4rem+2.6vw,4.2rem)] text-white">
            Atiendes hoy.{' '}
            <em className="portada-serif text-portada-cielo-2">
              Cobras completo.
            </em>
          </p>
          <p className="portada-entrada mt-6 max-w-[36ch] text-white/65">
            Recibes el 100% de cada consulta, pague o no el paciente.
          </p>
        </Entra>
      </aside>
    </div>
  )
}
