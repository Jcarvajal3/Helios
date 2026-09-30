import { createFileRoute, Link } from '@tanstack/react-router'

import { HeliosLogo } from '@/components/HeliosLogo'
import { P } from '@/components/prose'
import { Callout, Card } from '@/components/ui'
import { RESPONSABLE } from '@/config/legal'

export const Route = createFileRoute('/legal/privacidad')({
  head: () => ({ meta: [{ title: 'Política de privacidad · Helios' }] }),
  component: Privacidad,
})

/**
 * POLÍTICA DE PRIVACIDAD — `/legal/privacidad`. Marcador hasta la fase 4.
 *
 * El texto de Ronda describía una app (KYC, PIN, dispositivos, push) que
 * Helios no tiene. El de Helios se escribe con un abogado antes del piloto
 * (plan §12: datos de salud, hábeas data del art. 28 CRBV) y con la razón
 * social decidida (D-H10). Hasta entonces esta página solo dice que existe
 * y que está en preparación: una política inventada sería peor que ninguna.
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
            {RESPONSABLE.razonSocial
              ? `${RESPONSABLE.razonSocial} (RIF ${RESPONSABLE.rif}) publicará aquí su política de privacidad.`
              : 'Helios publicará aquí su política de privacidad antes de empezar a operar.'}{' '}
            Mientras tanto, los datos que la clínica registra para un financiamiento se usan solo
            para gestionarlo y cobrarlo, y no se comparten con otras clínicas.
          </P>
        </Card>

        <Link
          to="/soporte"
          className="mt-[var(--spacing-shell-gap-block)] inline-block type-body-small text-on-surface-variant underline-offset-4 hover:underline"
        >
          Soporte
        </Link>
      </div>
    </div>
  )
}
