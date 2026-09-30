import { useState } from 'react'
import { Link, createFileRoute, useNavigate } from '@tanstack/react-router'
import { Eye, EyeOff } from 'lucide-react'

import { Button, Card, ErrorBox, Input } from '@/components/ui'
import { HeliosLogo } from '@/components/HeliosLogo'
import { fetchPlatformAdmin } from '@/features/admin/api'
import { describeError, supabase } from '@/lib/supabase'

export const Route = createFileRoute('/login')({ component: Login })

/**
 * Login del panel: correo y contraseña, sin verificación de correo.
 *
 * Decisión 2026-08-22: el panel deja el teléfono+OTP de la app de
 * consumidores. La cuenta la crea siempre el super admin — no hay "crear
 * cuenta" aquí (docs/00-BASES §2.9).
 */
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

    const { error: err } = await supabase.auth.signInWithPassword({ email, password })
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
        err.code === 'invalid_credentials' || /invalid login credentials/i.test(err.message)

      setError(
        credencialesMalas
          ? 'Correo o contraseña incorrectos.'
          : (describeError(err) ?? 'No pudimos entrar.'),
      )
      return
    }

    // Un mismo login sirve a dos paneles. Sin esto, el equipo de Ronda
    // aterriza en el panel de comercios y recibe un "esta cuenta no es de un
    // comercio" que parece un error cuando en realidad se entró bien.
    const admin = await fetchPlatformAdmin().catch(() => null)
    setBusy(false)

    void navigate({ to: admin ? '/admin' : '/registrar' })
  }

  return (
    <div className="flex min-h-dvh flex-col items-center bg-shell-canvas px-6 py-10 sm:py-16">
      <header className="flex w-full max-w-md flex-col items-center pb-[var(--spacing-shell-gap-block)]">
        <HeliosLogo height={40} />
        <span className="mt-[var(--spacing-shell-gap-stack)] type-label-medium uppercase tracking-[0.3em] text-on-surface-variant">
          Panel
        </span>
      </header>

      <div className="flex w-full max-w-md flex-1 items-start">
        <Card className="w-full" tone="brand">
          <h1 className="type-panel-page text-on-surface">Iniciar sesión</h1>
          <p className="mt-[var(--spacing-shell-gap-tight)] type-body-medium text-on-surface-variant">
            Con la cuenta que te dio tu administrador.
          </p>

          <form
            className="mt-[var(--spacing-shell-gap-group)] flex flex-col gap-[var(--spacing-shell-gap-group)]"
            onSubmit={(e) => {
              e.preventDefault()
              void signIn()
            }}
          >
            {/* Los campos son los del kit, no dos inputs a mano: antes tenían
                borde permanente y fondo del lienzo, o sea el contrario exacto
                del contrato del sistema —superficie de control, borde solo en
                foco o error— y eran los únicos así en todo el panel. */}
            <Input
              id="email"
              label="Correo electrónico"
              type="email"
              value={email}
              onChange={setEmail}
              placeholder="tu@clinica.com"
              autoFocus
            />

            <div className="relative">
              <Input
                id="password"
                label="Contraseña"
                type={showPassword ? 'text' : 'password'}
                value={password}
                onChange={setPassword}
                placeholder="Tu contraseña"
              />
              {/* Alineado al alto del campo (40) y no a la caja entera, que
                  incluye la etiqueta de arriba.

                  `en-linea` porque el mínimo táctil de la tablet —44— lo
                  sacaba 4 px por encima del campo, montado sobre la etiqueta
                  «Contraseña». Este botón no flota: ocupa el extremo de su
                  propio campo, y ahí el objetivo que se toca es el alto del
                  campo entero, que son 40 y se aciertan igual. */}
              <button
                type="button"
                onClick={() => setShowPassword((v) => !v)}
                aria-label={showPassword ? 'Ocultar contraseña' : 'Mostrar contraseña'}
                className="en-linea absolute bottom-0 right-0 flex size-10 items-center justify-center rounded-[var(--radius-panel-control)] text-on-surface-variant transition-colors duration-[var(--transition-fast)] hover:text-on-surface"
              >
                {showPassword ? <EyeOff size={18} /> : <Eye size={18} />}
              </button>
            </div>

            {error && <ErrorBox title="No pudimos entrar" detail={error} />}

            <Button type="submit" disabled={busy || !email || !password}>
              {busy ? 'Entrando…' : 'Iniciar sesión'}
            </Button>
          </form>
        </Card>
      </div>

      {/* La única puerta pública al texto legal desde el panel: no hay más
          pantallas sin sesión, y la ficha de la tienda pide la URL. */}
      <Link
        to="/legal/privacidad"
        className="mt-[var(--spacing-shell-gap-block)] type-body-small text-on-surface-faint underline-offset-4 transition-colors duration-[var(--transition-fast)] hover:text-on-surface-variant hover:underline"
      >
        Política de privacidad
      </Link>
    </div>
  )
}
