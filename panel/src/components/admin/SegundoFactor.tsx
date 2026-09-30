import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import QRCode from 'qrcode'
import { ShieldAlert, ShieldCheck } from 'lucide-react'

import {
  Badge,
  Button,
  Callout,
  Card,
  ConfirmDialog,
  ErrorBox,
  Input,
  Seccion,
  SkeletonBlock,
} from '@/components/ui'
import { useToast } from '@/components/Toast'
import { describeError, supabase } from '@/lib/supabase'

/**
 * El segundo factor de la cuenta de quien está mirando.
 *
 * El panel está en una URL pública y mueve dinero: aprueba pagos, registra
 * transferencias a locales y cambia cupos. Con solo correo y contraseña, la
 * seguridad de todo eso es la de la contraseña más débil del equipo.
 *
 * Cada persona activa el suyo: nadie puede activarlo por otro, porque el
 * secreto tiene que nacer en su teléfono.
 *
 * ⚠️ Esto lo **ofrece**, no lo exige. Exigirlo es una comprobación en el
 * servidor —que `is_platform_admin()` pida nivel `aal2`— y encenderla antes de
 * que todo el equipo lo tenga activado deja a todo el mundo fuera del panel a
 * la vez. El orden es: activarlo todos, comprobarlo aquí, y después encender
 * la exigencia.
 */
export function SegundoFactor() {
  const client = useQueryClient()
  const [enrolando, setEnrolando] = useState(false)
  const [quitando, setQuitando] = useState<string | null>(null)

  const factores = useQuery({
    queryKey: ['mfa-factors'],
    queryFn: async () => {
      const { data, error } = await supabase.auth.mfa.listFactors()
      if (error) throw error
      return data.totp
    },
  })

  const nivel = useQuery({
    queryKey: ['mfa-level'],
    queryFn: async () => {
      const { data, error } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel()
      if (error) throw error
      return data
    },
  })

  const avisar = useToast()

  const quitar = useMutation({
    mutationFn: async (factorId: string) => {
      const { error } = await supabase.auth.mfa.unenroll({ factorId })
      if (error) throw error
    },
    onSuccess: () => {
      avisar('Segundo factor quitado de tu cuenta')
      setQuitando(null)
      void client.invalidateQueries({ queryKey: ['mfa-factors'] })
      void client.invalidateQueries({ queryKey: ['mfa-level'] })
    },
  })

  // `listFactors()` ya devuelve solo los verificados, pero el primero es el
  // que hay que poder quitar y conviene nombrarlo.
  const factorActivo = factores.data?.[0] ?? null
  const activo = !!factorActivo
  // `aal1` con un factor verificado significa que la sesión es de antes de
  // activarlo: hay que volver a entrar para que cuente.
  const sesionAlDia = nivel.data?.currentLevel === 'aal2'

  return (
    <Seccion
      titulo="Tu segundo factor"
      info="Cada persona activa el suyo, porque el secreto nace en su teléfono y nadie más lo ve. Que el panel lo exija se decide más abajo, cuando todo el equipo lo tenga activado: encenderlo antes dejaría a todos fuera a la vez."
      controles={
        factores.isLoading ? (
          <SkeletonBlock className="h-9 w-32" />
        ) : activo ? (
          <>
            <Badge tone={sesionAlDia ? 'success' : 'warning'} icono>
              {sesionAlDia ? 'Activo' : 'Activo, falta volver a entrar'}
            </Badge>
            <Button size="sm" variant="text" onClick={() => setQuitando(factorActivo.id)}>
              Quitarlo
            </Button>
          </>
        ) : (
          <Button size="sm" onClick={() => setEnrolando(true)}>
            Activar el segundo factor
          </Button>
        )
      }
    >
      {/* Mientras carga o si no se pudo leer no se afirma nada de la cuenta. */}
      {!factores.isLoading && !factores.isError && (
        <Card className="flex items-start gap-3">
          {activo ? (
            <ShieldCheck size={20} aria-hidden className="mt-px shrink-0 text-success" />
          ) : (
            <ShieldAlert size={20} aria-hidden className="mt-px shrink-0 text-warning" />
          )}
          <p className="type-panel-body text-on-surface-variant">
            {activo
              ? 'Tu cuenta pide un código de tu app de autenticación además de la contraseña.'
              : 'Tu cuenta entra solo con la contraseña, y este panel aprueba pagos y registra transferencias.'}
          </p>
        </Card>
      )}

      {activo && !sesionAlDia && (
        <Callout tone="warning" titulo="Esta sesión todavía cuenta como de un solo factor">
          Se abrió antes de activarlo: cierra la sesión y vuelve a entrar para que cuente.
        </Callout>
      )}

      {factores.isError && (
        <ErrorBox
          title="No se pudo leer tu segundo factor"
          detail={describeError(factores.error)}
        />
      )}

      {enrolando && (
        <Enrolar
          onClose={() => setEnrolando(false)}
          onDone={() => {
            setEnrolando(false)
            void client.invalidateQueries({ queryKey: ['mfa-factors'] })
            void client.invalidateQueries({ queryKey: ['mfa-level'] })
          }}
        />
      )}

      {quitando && (
        <ConfirmDialog
          title="Quitar el segundo factor"
          summary="Tu cuenta volverá a entrar solo con la contraseña."
          detail={
            <p className="type-panel-body text-on-surface-variant">
              Quítalo solo si cambiaste de teléfono y vas a activarlo ahora mismo.
            </p>
          }
          confirmLabel="Quitarlo"
          danger
          busy={quitar.isPending}
          error={quitar.isError ? describeError(quitar.error) : undefined}
          onConfirm={() => quitar.mutate(quitando)}
          onClose={() => setQuitando(null)}
        />
      )}
    </Seccion>
  )
}

/**
 * Los tres pasos: crear el factor, enseñar el QR, comprobar un código.
 *
 * Un factor queda en `unverified` hasta que se confirma con un código. Si
 * alguien cierra esta ventana a medias, el factor a medias se borra: dejarlo
 * ahí llenaría la cuenta de factores que no sirven y ninguno diría cuál es el
 * bueno.
 */
function Enrolar({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const [codigo, setCodigo] = useState('')

  const factor = useQuery({
    queryKey: ['mfa-enroll'],
    // Sin reintentos ni refresco: cada llamada crea un factor nuevo.
    retry: false,
    refetchOnWindowFocus: false,
    staleTime: Infinity,
    queryFn: async () => {
      const { data, error } = await supabase.auth.mfa.enroll({
        factorType: 'totp',
        friendlyName: `Helios panel · ${new Date().toISOString().slice(0, 10)}`,
      })
      if (error) throw error

      // El QR se dibuja aquí y no se usa el que manda el servidor: llega como
      // SVG en unas versiones y como data-URI en otras, y una imagen que no
      // aparece en el momento de configurar el segundo factor es un callejón.
      const qr = await QRCode.toDataURL(data.totp.uri, { margin: 1, width: 240 })
      return { factorId: data.id, secret: data.totp.secret, qr }
    },
  })

  const avisar = useToast()
  const verificar = useMutation({
    mutationFn: async () => {
      const { data: reto, error: retoError } = await supabase.auth.mfa.challenge({
        factorId: factor.data!.factorId,
      })
      if (retoError) throw retoError

      const { error } = await supabase.auth.mfa.verify({
        factorId: factor.data!.factorId,
        challengeId: reto.id,
        code: codigo.replace(/\D/g, ''),
      })
      if (error) throw error
    },
    onSuccess: () => {
      avisar('Segundo factor activado en tu cuenta')
      onDone()
    },
  })

  async function cancelar() {
    // Un factor sin verificar no sirve para nada y estorba en la lista.
    if (factor.data?.factorId) {
      await supabase.auth.mfa.unenroll({ factorId: factor.data.factorId })
    }
    onClose()
  }

  const listo = codigo.replace(/\D/g, '').length === 6

  return (
    <ConfirmDialog
      title="Activar el segundo factor"
      summary="Escanea el código con Google Authenticator, Authy u otra aplicación de autenticación, y escribe el número de seis dígitos que te muestre."
      detail={
        <div className="flex flex-col gap-4">
          {factor.isLoading && <SkeletonBlock className="mx-auto size-60" />}

          {factor.isError && (
            <ErrorBox
              title="No se pudo empezar"
              detail={describeError(factor.error)}
            />
          )}

          {factor.data && (
            <>
              <img
                src={factor.data.qr}
                alt="Código para tu app de autenticación"
                className="mx-auto rounded-panel-control bg-white p-2"
                width={240}
                height={240}
              />

              <div className="rounded-panel-control bg-shell-canvas p-3">
                <p className="type-panel-label text-on-surface-variant">
                  Si no puedes escanear, escribe esta clave
                </p>
                <p className="mt-1 break-all font-mono type-panel-body text-on-surface">
                  {factor.data.secret}
                </p>
              </div>

              <Input
                id="mfa-codigo"
                label="El código de seis dígitos"
                value={codigo}
                onChange={setCodigo}
                inputMode="numeric"
                placeholder="123456"
                autoFocus
              />
            </>
          )}
        </div>
      }
      bloqueo={
        !factor.data
          ? 'Espera a que aparezca el código.'
          : !listo
            ? 'Escribe los seis dígitos.'
            : undefined
      }
      confirmLabel="Activar"
      busy={verificar.isPending}
      error={
        verificar.isError
          ? 'El código no es válido. Los códigos cambian cada 30 segundos; prueba con el siguiente.'
          : undefined
      }
      onConfirm={() => verificar.mutate()}
      onClose={() => void cancelar()}
    />
  )
}
