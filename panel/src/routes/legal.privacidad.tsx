import { createFileRoute, Link } from '@tanstack/react-router'

import { HeliosLogo } from '@/components/HeliosLogo'
import { P } from '@/components/prose'
import { Callout, Card } from '@/components/ui'
import { operador } from '@/config/legal'
import { cabeceraPublica } from '@/config/sitio'

export const Route = createFileRoute('/legal/privacidad')({
  head: () =>
    cabeceraPublica({
      titulo: 'Política de privacidad · Helios',
      descripcion: 'Cómo trata Helios los datos de pacientes, médicos y centros de salud.',
      ruta: '/legal/privacidad',
    }),
  component: Privacidad,
})

/**
 * POLÍTICA DE PRIVACIDAD — `/legal/privacidad`. Marcador hasta la fase 4.
 *
 * El texto de Ronda describía una app (KYC, PIN, dispositivos, push) que
 * Helios no tiene. El de Helios se escribe con un abogado antes del piloto
 * (plan §12: datos de salud, hábeas data del art. 28 CRBV). El responsable
 * ya está decidido —Quarto Latam, C.A.—; falta el RIF (D-H10). Hasta
 * entonces esta página solo dice que existe y que está en preparación: una
 * política inventada sería peor que ninguna.
 */
function Privacidad() {
  return (
    <div className="min-h-screen bg-shell-canvas px-6 py-12">
      <div className="mx-auto w-full max-w-3xl">
        <header className="flex flex-col items-start">
          <HeliosLogo height={32} />
          <h1 className="mt-[var(--spacing-shell-gap-block)] type-headline-medium-emphasized text-on-surface">
            Política de privacidad
          </h1>
        </header>

        <Card className="mt-[var(--spacing-shell-gap-block)]">
          <Callout tone="info" titulo="Documento en preparación" />
          <P>
            Helios es operado por {operador()}, que publicará aquí su política de
            privacidad antes de empezar a operar. Mientras tanto, los datos que el
            médico o el centro registra para un pago en cuotas se usan solo para
            gestionarlo y cobrarlo, y no se comparten con otros centros.
          </P>
        </Card>

        <div className="mt-[var(--spacing-shell-gap-block)] flex flex-wrap gap-x-6 gap-y-2">
          <Link
            to="/legal/terminos"
            className="type-body-small text-on-surface-variant underline-offset-4 hover:underline"
          >
            Términos y condiciones
          </Link>
          <Link
            to="/soporte"
            className="type-body-small text-on-surface-variant underline-offset-4 hover:underline"
          >
            Soporte
          </Link>
        </div>
      </div>
    </div>
  )
}
