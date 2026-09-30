import { useEffect, useRef } from 'react'
import { MessageCircle, Search, UserCheck, UserPlus } from 'lucide-react'

import { Callout, Card, DataLabel, ErrorBox, Tecla, formatUsd, whatsappNumber } from '@/components/ui'
import { cedulaLegible, problemaDeCedula } from '@/features/merchant/paciente'
import type { Nacionalidad } from '@/features/merchant/paciente'
import { codigoDeError } from '@/features/merchant/registro'
import type { Elegibilidad } from '@/features/merchant/registro'
import { describeError } from '@/lib/supabase'

import { BotonConFoco, Campo, Opciones } from './Campo'

const NACIONALIDADES: Array<{ value: Nacionalidad; label: string }> = [
  { value: 'V', label: 'V' },
  { value: 'E', label: 'E' },
]

/**
 * PASO 1 · LA CÉDULA.
 *
 * Una pregunta y tres respuestas posibles (contrato §1.1):
 *
 *   nuevo          Helios no lo conoce: se piden todos sus datos.
 *   disponible     lo conoce y puede financiarle hasta $X. Se le leen al
 *                  paciente su nombre, su teléfono y su correo enmascarados
 *                  para confirmar que es él.
 *   no_disponible  no se le puede financiar. NUNCA se dice por qué: mora,
 *                  lista negra o cupo agotado se ven igual desde la clínica.
 *
 * Cada consulta cuenta contra el límite diario de la secretaria, así que no
 * se repite sola: solo al pulsar Consultar (o Enter).
 */
export function PasoCedula({
  nacionalidad,
  numero,
  onNacionalidad,
  onNumero,
  consultando,
  error,
  elegibilidad,
  noCoincide,
  intentado,
  onConsultar,
  onSeguir,
  onNoCoincide,
}: {
  nacionalidad: Nacionalidad
  numero: string
  onNacionalidad: (n: Nacionalidad) => void
  onNumero: (n: string) => void
  consultando: boolean
  error: unknown
  /** La respuesta para la cédula que está escrita; null si no se ha consultado. */
  elegibilidad: Elegibilidad | null
  noCoincide: boolean
  /** Ya se intentó consultar: a partir de aquí se dice qué le falta a la cédula. */
  intentado: boolean
  onConsultar: () => void
  onSeguir: () => void
  onNoCoincide: () => void
}) {
  const campoRef = useRef<HTMLInputElement>(null)
  const seguirRef = useRef<HTMLButtonElement>(null)

  // Al abrir el paso, el cursor ya está en la cédula: es lo único que hay
  // que teclear para empezar.
  useEffect(() => {
    campoRef.current?.focus()
  }, [])

  // Llegada la respuesta, el foco salta al botón de seguir: Enter otra vez y
  // se continúa, sin buscar el ratón. No al volver a este paso desde otro:
  // quien vuelve viene a cambiar la cédula, y el foco se queda en ella.
  const primeraPintada = useRef(true)
  useEffect(() => {
    if (primeraPintada.current) {
      primeraPintada.current = false
      return
    }
    if (elegibilidad && elegibilidad.estado !== 'no_disponible') seguirRef.current?.focus()
  }, [elegibilidad])

  const problema = problemaDeCedula(numero)
  const legible = cedulaLegible(numero)

  return (
    <div className="flex flex-col gap-5">
      <Card variant="hero">
        <form
          noValidate
          onSubmit={(e) => {
            e.preventDefault()
            if (problema) campoRef.current?.focus()
            onConsultar()
          }}
          className="flex flex-col gap-4"
        >
          <div className="flex flex-wrap items-start gap-3">
            <Opciones
              id="alta-nacionalidad"
              label="Nacionalidad"
              value={nacionalidad}
              opciones={NACIONALIDADES}
              onChange={onNacionalidad}
              grande
            />
            <Campo
              id="alta-cedula"
              label="Cédula del titular"
              value={numero}
              // Solo dígitos y los puntos que se escriben de costumbre.
              onChange={(v) => onNumero(v.replace(/[^\d.\s]/g, ''))}
              inputRef={campoRef}
              inputMode="numeric"
              autoComplete="off"
              maxLength={14}
              placeholder="12.345.678"
              grande
              error={intentado ? problema : null}
              hint={
                legible && !problema
                  ? `${nacionalidad}-${legible} · léesela en voz alta al paciente para confirmarla`
                  : 'Quien paga las cuotas. Si el paciente es menor, la de su representante.'
              }
              className="min-w-0 flex-1 basis-64"
            />
          </div>

          <div>
            <BotonConFoco type="submit" disabled={consultando}>
              <Search size={16} aria-hidden />
              {consultando ? 'Consultando…' : 'Consultar'}
              <Tecla enBoton>Enter</Tecla>
            </BotonConFoco>
          </div>
        </form>
      </Card>

      {error ? <ErrorDeConsulta error={error} /> : null}

      {elegibilidad?.estado === 'nuevo' && (
        <Card className="flex flex-col gap-4">
          <div className="flex items-start gap-3">
            <UserPlus size={22} aria-hidden className="mt-0.5 shrink-0 text-on-surface-variant" />
            <div>
              <p role="status" className="type-panel-section text-on-surface">
                Paciente nuevo en Helios
              </p>
              <p className="mt-1 type-panel-body text-on-surface-variant">
                Vas a registrar sus datos. Puede financiar desde{' '}
                <strong className="text-on-surface">{formatUsd(elegibilidad.minChargeUsd)}</strong>{' '}
                hasta <strong className="text-on-surface">{formatUsd(elegibilidad.limiteUsd)}</strong>.
              </p>
            </div>
          </div>
          <div>
            <BotonConFoco botonRef={seguirRef} onClick={onSeguir}>
              Continuar con sus datos
              <Tecla enBoton>Enter</Tecla>
            </BotonConFoco>
          </div>
        </Card>
      )}

      {elegibilidad?.estado === 'disponible' && (
        <Card className="flex flex-col gap-4">
          <div className="flex items-start gap-3">
            <UserCheck size={22} aria-hidden className="mt-0.5 shrink-0 text-on-surface-variant" />
            <div className="min-w-0 flex-1">
              <p role="status" className="type-panel-section text-on-surface">
                Helios ya conoce a este paciente
              </p>
              <p className="mt-1 type-panel-body text-on-surface-variant">
                Pregúntale si estos datos son los suyos. Sus datos no se vuelven a pedir.
              </p>
            </div>
          </div>

          <dl className="grid gap-3 sm:grid-cols-3">
            <DatoEnmascarado rotulo="Nombre" valor={elegibilidad.nombreEnmascarado} />
            <DatoEnmascarado rotulo="Teléfono" valor={elegibilidad.telefonoEnmascarado} />
            <DatoEnmascarado rotulo="Correo" valor={elegibilidad.emailEnmascarado} />
          </dl>

          <div className="rounded-panel-card bg-panel-raised p-4">
            <DataLabel>Disponible para financiar</DataLabel>
            <p className="mt-1 type-panel-hero text-on-surface">
              {formatUsd(elegibilidad.disponibleUsd)}
            </p>
          </div>

          {noCoincide ? (
            <Callout tone="warning" titulo="No sigas con este financiamiento">
              Revisa que la cédula esté bien escrita. Si lo está y los datos no son los del
              paciente, pídele que escriba a Helios para aclararlo antes de financiar.
            </Callout>
          ) : (
            <div className="flex flex-wrap gap-3">
              <BotonConFoco botonRef={seguirRef} onClick={onSeguir}>
                Sí, son sus datos
                <Tecla enBoton>Enter</Tecla>
              </BotonConFoco>
              <BotonConFoco variant="text" onClick={onNoCoincide}>
                No coinciden
              </BotonConFoco>
            </div>
          )}
        </Card>
      )}

      {elegibilidad?.estado === 'no_disponible' && (
        <NoDisponible mensaje={elegibilidad.mensaje} whatsapp={elegibilidad.whatsappHelios} />
      )}
    </div>
  )
}

function DatoEnmascarado({ rotulo, valor }: { rotulo: string; valor: string | null }) {
  return (
    <div className="rounded-panel-card border border-panel-hairline px-4 py-3">
      <dt>
        <DataLabel>{rotulo}</DataLabel>
      </dt>
      <dd className="mt-1 truncate type-panel-section tracking-wide text-on-surface" title={valor ?? undefined}>
        {valor ?? <span className="text-panel-muted">No registrado</span>}
      </dd>
    </div>
  )
}

/**
 * «No se puede financiar», en neutro.
 *
 * Gris y no rojo: no es un error de la secretaria ni del sistema, es una
 * respuesta. Y sin motivo, porque la base no lo manda (privacidad entre
 * clínicas). Lo único accionable es el WhatsApp de Helios, si está
 * configurado, para que sea el paciente quien pregunte.
 */
function NoDisponible({ mensaje, whatsapp }: { mensaje: string; whatsapp: string | null }) {
  const numero = whatsappNumber(whatsapp)

  return (
    <Callout
      tone="info"
      titulo="No se puede financiar con Helios"
      accion={
        numero ? (
          <a
            href={`https://wa.me/${numero}`}
            target="_blank"
            rel="noreferrer"
            className="inline-flex h-panel-control-sm items-center gap-2 rounded-panel-control bg-panel-control px-3.5 type-panel-control text-on-surface transition-colors hover:bg-shell-inset"
          >
            <MessageCircle size={16} aria-hidden />
            WhatsApp de Helios
          </a>
        ) : undefined
      }
    >
      <p>{mensaje}</p>
      <p className="mt-2">Para consultar otra cédula, cambia el número de arriba.</p>
    </Callout>
  )
}

/**
 * Un fallo de la consulta, con el texto de la base delante.
 *
 * El título cambia con el código para que se entienda qué hacer sin leer el
 * detalle: el límite diario y el mantenimiento no se arreglan reintentando.
 */
function ErrorDeConsulta({ error }: { error: unknown }) {
  const code = codigoDeError(error)

  const titulo =
    code === '55000'
      ? 'Helios no está registrando financiamientos en este momento'
      : code === '22023'
        ? 'No se pudo consultar la cédula'
        : code === '42501'
          ? 'Tu cuenta no puede registrar en esta clínica'
          : code === '28000'
            ? 'Tu sesión se cerró: vuelve a entrar'
            : 'No pudimos consultar la cédula'

  return <ErrorBox title={titulo} detail={describeError(error)} />
}
