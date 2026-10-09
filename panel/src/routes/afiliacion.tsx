import { useState } from 'react'
import type { FormEvent } from 'react'
import { createFileRoute, Link } from '@tanstack/react-router'
import { useMutation } from '@tanstack/react-query'
import { CircleCheck } from 'lucide-react'

import { CamposDeAlta } from '@/components/afiliacion/CamposDeAlta'
import { HeliosLogo } from '@/components/HeliosLogo'
import { Button, Card, ErrorBox } from '@/components/ui'
import { cabeceraPublica } from '@/config/sitio'
import { ALTA_VACIA, datosDeAlta, motivoDeAlta } from '@/features/admin/clinicas/clinicas'
import type { AltaDeClinica } from '@/features/admin/clinicas/clinicas'
import { describeError, supabase } from '@/lib/supabase'

export const Route = createFileRoute('/afiliacion')({
  head: () =>
    cabeceraPublica({
      titulo: 'Quiero afiliarme · Helios',
      descripcion:
        'Afilia tu consultorio o centro de salud a Helios y ofrece a tus pacientes pagar sus consultas en cuotas. Sin costo para ti.',
      ruta: '/afiliacion',
    }),
  component: Afiliacion,
})

/**
 * AFILIACIÓN — `/afiliacion`, a donde lleva «Quiero afiliarme».
 *
 * El médico manda los mismos datos que pide el alta del equipo
 * (`CamposDeAlta`). La solicitud queda pendiente en Clínicas › Pendientes
 * del superadmin; al aprobarla nace la clínica. La base valida lo mismo que
 * aquí y frena el abuso (`helios_solicitar_afiliacion`).
 */
function Afiliacion() {
  const [alta, setAlta] = useState<AltaDeClinica>(ALTA_VACIA)
  // El campo que no se ve: si llega con algo, lo rellenó un robot.
  const [sitioWeb, setSitioWeb] = useState('')
  const [intentado, setIntentado] = useState(false)

  const envio = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc('helios_solicitar_afiliacion', {
        p: { ...datosDeAlta(alta), sitio_web: sitioWeb },
      })
      if (error) throw error
    },
  })

  const motivo = motivoDeAlta(alta)

  function enviar(e: FormEvent) {
    e.preventDefault()
    setIntentado(true)
    if (motivo || envio.isPending) return
    envio.mutate()
  }

  return (
    <div className="min-h-screen bg-shell-canvas px-4 py-12 sm:px-6">
      <div className="mx-auto w-full max-w-3xl">
        <header className="flex flex-col items-start">
          <Link to="/" aria-label="Helios, ir a la portada">
            <HeliosLogo height={32} />
          </Link>
          <h1 className="mt-[var(--spacing-shell-gap-block)] type-headline-medium-emphasized text-on-surface">
            Quiero afiliarme
          </h1>
          <p className="mt-2 type-body-medium text-on-surface-variant">
            Ofrece a tus pacientes pagar sus consultas en dos cuotas. Tú recibes el 100% de cada consulta, a los 8 y
            a los 15 días, pague o no el paciente. No te cuesta nada y no hay permanencia.
          </p>
        </header>

        {envio.isSuccess ? (
          <Card className="mt-[var(--spacing-shell-gap-block)]">
            <div className="flex flex-col items-start gap-3">
              <CircleCheck size={32} className="text-success" aria-hidden />
              <h2 className="type-title-medium text-on-surface">Recibimos tu solicitud</h2>
              <p className="type-body-medium text-on-surface-variant">
                La revisamos y te escribimos a {alta.email.trim().toLowerCase()} o al {alta.phone.trim()} para
                activar tu cuenta.
              </p>
              <Link to="/" className="type-body-medium text-primary underline-offset-4 hover:underline">
                Volver a la portada
              </Link>
            </div>
          </Card>
        ) : (
          <form onSubmit={enviar} noValidate>
            <Card className="mt-[var(--spacing-shell-gap-block)]">
              <div className="flex flex-col gap-6">
                <CamposDeAlta id="afiliacion" valor={alta} onChange={setAlta} />

                {/* Fuera de la vista y del tabulador: solo lo rellena un robot. */}
                <div aria-hidden className="absolute -left-[9999px] h-px w-px overflow-hidden">
                  <label htmlFor="afiliacion-sitio-web">Sitio web</label>
                  <input
                    id="afiliacion-sitio-web"
                    name="sitio_web"
                    tabIndex={-1}
                    autoComplete="off"
                    value={sitioWeb}
                    onChange={(e) => setSitioWeb(e.target.value)}
                  />
                </div>

                {intentado && motivo && <p className="type-body-small text-error">{motivo}</p>}
                {envio.isError && (
                  <ErrorBox title="No se pudo enviar la solicitud" detail={describeError(envio.error)} />
                )}

                <div className="flex flex-col items-start gap-3">
                  <Button type="submit" size="md" disabled={envio.isPending}>
                    {envio.isPending ? 'Enviando…' : 'Enviar solicitud'}
                  </Button>
                  <p className="type-body-small text-on-surface-variant">
                    Al enviarla aceptas que tratemos estos datos según nuestra{' '}
                    <Link to="/legal/privacidad" className="text-primary underline-offset-4 hover:underline">
                      política de privacidad
                    </Link>
                    .
                  </p>
                </div>
              </div>
            </Card>
          </form>
        )}
      </div>
    </div>
  )
}
