import { createFileRoute, Link } from '@tanstack/react-router'

import { HeliosLogo } from '@/components/HeliosLogo'
import { Lista, P } from '@/components/prose'
import { Card } from '@/components/ui'
import { operador } from '@/config/legal'
import { cabeceraPublica } from '@/config/sitio'

export const Route = createFileRoute('/legal/terminos')({
  head: () =>
    cabeceraPublica({
      titulo: 'Términos y condiciones · Helios',
      descripcion: 'Las condiciones del pago en cuotas de Helios para pacientes y para médicos y centros de salud: cuotas, comisión de servicio, límite y pagos.',
      ruta: '/legal/terminos',
    }),
  component: Terminos,
})

/**
 * TÉRMINOS Y CONDICIONES — `/legal/terminos`.
 *
 * Las reglas del servicio que ya están decididas (Javier, 2026-10-06), dichas
 * en claro para el paciente y para el médico o centro. No inventa cláusulas:
 * lo que todavía no está decidido (RIF, domicilio, jurisdicción) no aparece.
 * Las mismas condiciones del paciente van en su comprobante
 * (`terms_versions`), y el centro firma además su contrato de afiliación.
 *
 * Mismo vocabulario que la portada: «pago en cuotas» y «comisión de
 * servicio», nunca «préstamo» ni «financiamiento».
 */
function Terminos() {
  return (
    <div className="min-h-screen bg-shell-canvas px-6 py-12">
      <div className="mx-auto w-full max-w-3xl">
        <header className="flex flex-col items-start">
          <Link to="/" aria-label="Helios, ir a la portada">
            <HeliosLogo height={32} />
          </Link>
          <h1 className="mt-[var(--spacing-shell-gap-block)] type-headline-medium-emphasized text-on-surface">
            Términos y condiciones
          </h1>
          <p className="mt-2 type-body-small text-on-surface-faint">
            Vigentes desde el 6 de octubre de 2026.
          </p>
        </header>

        <Card className="mt-[var(--spacing-shell-gap-block)]">
          <h2 className="type-title-medium text-on-surface">El servicio</h2>
          <P>
            Helios es una forma de pagar consultas y tratamientos de salud privada
            en cuotas, en los consultorios y centros afiliados de medicina,
            odontología y cosmetología. {operador()} opera Helios.
          </P>
        </Card>

        <Card className="mt-[var(--spacing-shell-gap-block)]">
          <h2 className="type-title-medium text-on-surface">Para pacientes</h2>
          <Lista>
            <li>
              El médico o el centro registra la consulta. Recibes un WhatsApp con
              el monto, la comisión de servicio y tus dos cuotas con sus fechas, y
              el pago en cuotas solo existe si respondes «Sí». Después te llega el
              comprobante por correo.
            </li>
            <li>
              Pagas en dos cuotas iguales, a los 7 y a los 14 días de la
              consulta, sin inicial.
            </li>
            <li>
              La comisión de servicio es del 12% del monto de la consulta, más el
              IVA de esa comisión, y va incluida en las cuotas. Por ejemplo, en
              una consulta de $100 la comisión es de $12 y su IVA de $1,92: pagas
              $113,92 en dos cuotas de $56,96.
            </li>
            <li>
              Los montos están en dólares. Se pagan en bolívares a la tasa oficial
              del BCV del día del pago, por Pago Móvil o transferencia a las
              cuentas que indica Helios. El comprobante del pago se envía por
              WhatsApp a Helios.
            </li>
            <li>
              El límite inicial es de $150: es lo máximo que puedes tener en
              cuotas a la vez. Lo que usaste vuelve a estar disponible cuando
              pagas las dos cuotas de esa consulta.
            </li>
            <li>
              Si una cuota vence sin pagarse, no puedes registrar otro pago en
              cuotas hasta ponerte al día. Con 30 días de atraso la cuenta se
              suspende, y con 60 se cierra.
              {/* Sin cargos por mora desde el 2026-10-07 (`late_fee_usd` = 0).
                  Si se retoman, aquí iba: «Tras 3 días de gracia se suma un
                  cargo de $2 por cada cuota vencida.» */}
            </li>
            <li>
              El servicio es solo para mayores de 18 años con cédula. Si quien se
              atiende es menor de edad, el pago en cuotas va a nombre de su
              representante.
            </li>
            <li>
              Ningún médico ni centro ve tus cuotas ni si estás al día: solo sabe
              si puedes pagar esa consulta en cuotas.
            </li>
          </Lista>
        </Card>

        <Card className="mt-[var(--spacing-shell-gap-block)]">
          <h2 className="type-title-medium text-on-surface">
            Para médicos y centros
          </h2>
          <Lista>
            <li>
              Helios le paga al médico o centro el 100% del precio de la consulta
              en dos partes: la mitad a los 8 días y la otra mitad a los 15 días
              de la consulta.
            </li>
            <li>
              El pago está garantizado: se hace aunque el paciente no pague. El
              cobro al paciente es responsabilidad de Helios.
            </li>
            <li>
              Afiliarse no tiene costo: la comisión de servicio la paga el
              paciente. Al médico o centro no se le descuenta nada.
            </li>
            <li>
              Las consultas se registran desde la plataforma de Helios o por
              WhatsApp.
            </li>
            <li>
              No hay permanencia: el médico o centro puede cancelar su afiliación
              con aviso previo.
            </li>
          </Lista>
        </Card>

        <div className="mt-[var(--spacing-shell-gap-block)] flex flex-wrap gap-x-6 gap-y-2">
          <Link
            to="/legal/privacidad"
            className="type-body-small text-on-surface-variant underline-offset-4 hover:underline"
          >
            Política de privacidad
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
