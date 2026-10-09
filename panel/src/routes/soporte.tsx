import { createFileRoute, Link } from '@tanstack/react-router'

import { HeliosLogo } from '@/components/HeliosLogo'
import { P } from '@/components/prose'
import { Card } from '@/components/ui'
import { RESPONSABLE } from '@/config/legal'
import { cabeceraPublica } from '@/config/sitio'

export const Route = createFileRoute('/soporte')({
  head: () =>
    cabeceraPublica({
      titulo: 'Soporte · Helios',
      descripcion: 'Cómo contactar a Helios si tienes dudas sobre tus cuotas, tu comprobante o la afiliación de tu consultorio o centro de salud.',
      ruta: '/soporte',
    }),
  component: Soporte,
})

/**
 * SOPORTE — `/soporte`. Marcador hasta la fase 4 (plan §11).
 *
 * Helios no tiene app ni cuentas de pacientes: el paciente habla con Helios
 * por WhatsApp, al número que se configura en Ajustes › Contacto (H11). Esta
 * página existirá para quien llegue desde el pie del comprobante por correo,
 * o desde un centro. Mientras no haya canal decidido, no promete ninguno; a
 * los médicos los manda al formulario de `/afiliacion`.
 */
function Soporte() {
  return (
    <div className="min-h-screen bg-shell-canvas px-6 py-12">
      <div className="mx-auto w-full max-w-3xl">
        <header className="flex flex-col items-start">
          <HeliosLogo height={32} />
          <h1 className="mt-[var(--spacing-shell-gap-block)] type-headline-medium-emphasized text-on-surface">
            Soporte
          </h1>
        </header>

        <Card className="mt-[var(--spacing-shell-gap-block)]">
          <P>
            {RESPONSABLE.soporte
              ? `Escríbenos a ${RESPONSABLE.soporte} y te contestamos.`
              : 'Estamos preparando nuestros canales de atención. Si estás pagando una consulta en cuotas con Helios, escríbenos al WhatsApp que aparece en tu comprobante.'}
          </P>
          <P>
            ¿Eres médico o tienes un centro de salud?{' '}
            <Link to="/afiliacion" className="text-primary underline-offset-4 hover:underline">
              Manda tu solicitud de afiliación
            </Link>
            .
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
            to="/legal/privacidad"
            className="type-body-small text-on-surface-variant underline-offset-4 hover:underline"
          >
            Política de privacidad
          </Link>
        </div>
      </div>
    </div>
  )
}
