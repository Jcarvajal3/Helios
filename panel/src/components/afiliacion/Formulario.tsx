import { useRef, useState } from 'react'
import type { FormEvent } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation } from '@tanstack/react-query'
import { ArrowLeft, CircleAlert, CircleCheck } from 'lucide-react'

import {
  BotonPrincipal,
  CampoDeDocumento,
  CampoDeSeleccion,
  CampoDeTexto,
  Opcion,
  Opcionales,
  Progreso,
  Sugerencia,
} from './piezas'
import { sumarDias } from '@/components/kit/rango'
import {
  ALTA_VACIA,
  CAPACITACION_HASTA_DIAS,
  REDES_SOCIALES,
  SIN_CAPACITACION,
  TITULOS_DEL_MEDICO,
  capacitacionParaEnviar,
  comoLoNombran,
  datosDeAlta,
  digitosDeCuenta,
  formatoCuenta,
  motivoDeAlta,
  motivoDeCapacitacion,
} from '@/features/admin/clinicas/clinicas'
import type {
  AltaDeClinica,
  Capacitacion,
} from '@/features/admin/clinicas/clinicas'
import {
  PASOS,
  LETRAS_CEDULA_O_RIF,
  altaParaEnviar,
  bancoDeCuenta,
  erroresDelPaso,
  esRifDeEmpresa,
  primerError,
} from '@/features/afiliacion/pasos'
import type { CampoDeAfiliacion, Paso } from '@/features/afiliacion/pasos'
import { LETRAS_CEDULA, LETRAS_TITULAR } from '@/lib/documento'
import { describeError, supabase } from '@/lib/supabase'

/** Lo que el aviso de «Recibimos tu solicitud» necesita saber. */
export type SolicitudEnviada = {
  email: string
  phone: string
  /** La capacitación pedida (instante ISO), o `null`. */
  capacitacion: string | null
}

const ESPECIALIDADES_SUGERIDAS = [
  'Medicina general',
  'Odontología',
  'Cosmetología',
] as const

/** El `id` de un campo en la página (el foco va ahí cuando tiene un error). */
const idDe = (c: CampoDeAfiliacion) => `afiliacion-${c}`

/**
 * EL FORMULARIO DE AFILIACIÓN — tres pasos cortos (`PASOS`): tus datos, tu
 * consultorio y dónde te pagamos, con lo opcional plegado.
 *
 * Manda lo mismo que antes a `helios_solicitar_afiliacion`: el `p` de
 * `datosDeAlta` en modo portada, la capacitación y el campo trampa. Lo que
 * cambia es cómo se pide (ver `features/afiliacion/pasos.ts`).
 *
 * Los errores salen al lado de cada campo: el de un campo mal escrito al
 * dejarlo, el de uno vacío al pulsar «Continuar» (y entonces el foco va al
 * primero que falta).
 */
export function FormularioDeAfiliacion({
  hoy,
  alEnviar,
}: {
  /** El día de Caracas, 'YYYY-MM-DD'. */
  hoy: string
  alEnviar: (solicitud: SolicitudEnviada) => void
}) {
  const [paso, setPaso] = useState<Paso>(0)
  const [alta, setAlta] = useState<AltaDeClinica>(ALTA_VACIA)
  // «Cédula o RIF»: con J o G se pide además la cédula (`alta.ownerDocument`).
  const [documento, setDocumento] = useState('')
  const [cuentaPropia, setCuentaPropia] = useState(true)
  const [capacitacion, setCapacitacion] =
    useState<Capacitacion>(SIN_CAPACITACION)
  // El campo que no se ve: si llega con algo, lo rellenó un robot.
  const [sitioWeb, setSitioWeb] = useState('')
  const [tocados, setTocados] = useState<ReadonlySet<CampoDeAfiliacion>>(
    new Set(),
  )
  const [intentados, setIntentados] = useState<ReadonlySet<Paso>>(new Set())
  const [motivoFinal, setMotivoFinal] = useState<string | null>(null)
  const tarjeta = useRef<HTMLDivElement>(null)
  const titulo = useRef<HTMLHeadingElement>(null)

  const borrador = {
    alta,
    documento,
    cuentaPropia,
    capacitacion: capacitacion,
  }
  const errores = erroresDelPaso(paso, borrador, hoy)
  const final = altaParaEnviar(borrador)
  const banco = bancoDeCuenta(alta.accountNumber)
  const digitos = digitosDeCuenta(alta.accountNumber).length

  /** El error de un campo, si ya toca enseñarlo. */
  function error(c: CampoDeAfiliacion): string | null {
    const e = errores[c]
    if (!e) return null
    // La cuenta de un banco que no conocemos se avisa en cuanto se escribe.
    const enVivo = c === 'accountNumber' && digitos >= 4 && !banco
    return intentados.has(paso) || tocados.has(c) || enVivo ? e : null
  }

  const tocar = (c: CampoDeAfiliacion) => () =>
    setTocados((t) => (t.has(c) ? t : new Set(t).add(c)))

  const campo = (k: keyof AltaDeClinica) => (v: string) =>
    setAlta((a) => ({ ...a, [k]: v }))

  const envio = useMutation({
    mutationFn: async (p: Record<string, unknown>) => {
      const { error: e } = await supabase.rpc('helios_solicitar_afiliacion', {
        p,
      })
      if (e) throw e
    },
  })

  function irAlPaso(siguiente: Paso) {
    setPaso(siguiente)
    setMotivoFinal(null)
    envio.reset()
    // Arriba del formulario, y el foco en el título del paso nuevo.
    requestAnimationFrame(() => {
      const caja = tarjeta.current
      if (caja && caja.getBoundingClientRect().top < 0) {
        caja.scrollIntoView({ behavior: 'smooth', block: 'start' })
      }
      titulo.current?.focus({ preventScroll: true })
    })
  }

  function enviar(e: FormEvent) {
    e.preventDefault()
    if (envio.isPending) return

    const falla = primerError(paso, errores)
    if (falla) {
      setIntentados((i) => new Set(i).add(paso))
      // Al centro, para que se lea también el error de debajo.
      const el = document.getElementById(idDe(falla))
      el?.focus({ preventScroll: true })
      el?.scrollIntoView({ behavior: 'smooth', block: 'center' })
      return
    }
    if (paso < 2) {
      irAlPaso((paso + 1) as Paso)
      return
    }

    // El freno final: el mismo que el alta del equipo y que la base.
    const motivo =
      motivoDeAlta(final, 'portada') ?? motivoDeCapacitacion(capacitacion, hoy)
    setMotivoFinal(motivo)
    if (motivo) return

    const instante = capacitacionParaEnviar(capacitacion)
    envio.mutate(
      {
        ...datosDeAlta(final, 'portada'),
        training_at: instante,
        sitio_web: sitioWeb,
      },
      {
        onSuccess: () =>
          alEnviar({
            email: final.email.trim().toLowerCase(),
            phone: final.phone.trim(),
            capacitacion: instante,
          }),
      },
    )
  }

  const p = PASOS[paso]

  return (
    <div
      ref={tarjeta}
      className="scroll-mt-6 rounded-[28px] border border-portada-linea bg-white p-5 shadow-[0_30px_60px_-40px_rgba(0,39,112,0.35)] sm:p-8"
    >
      <Progreso pasos={PASOS.map((x) => x.corto)} actual={paso} />

      <h2
        ref={titulo}
        tabIndex={-1}
        className="afiliacion-titulo mt-7 text-[1.45rem] font-medium leading-tight tracking-[-0.03em] text-portada-tinta"
      >
        {p.titulo}
      </h2>
      <p className="mt-1.5 text-[0.95rem] leading-relaxed text-portada-tinta-2">
        {p.nota}
      </p>

      <form onSubmit={enviar} noValidate className="mt-7 flex flex-col gap-5">
        {paso === 0 && (
          <>
            <CampoDeTexto
              id={idDe('ownerName')}
              etiqueta="Nombre y apellido"
              value={alta.ownerName}
              onChange={campo('ownerName')}
              alSalir={tocar('ownerName')}
              error={error('ownerName')}
              autoComplete="name"
              autoCapitalize="words"
              enterKeyHint="next"
              placeholder="Ana María Pérez"
            />
            {/* Obligatorio (Javier, 2026-10-28): el foco de «Continuar»
                viene al grupo cuando falta. */}
            <fieldset
              id={idDe('doctorTitle')}
              tabIndex={-1}
              aria-describedby={
                error('doctorTitle')
                  ? `${idDe('doctorTitle')}-error`
                  : undefined
              }
              className="flex min-w-0 flex-col outline-none"
            >
              <legend className="mb-2 text-[0.9rem] font-medium tracking-[-0.01em] text-portada-tinta">
                ¿Cómo quieres que te nombren tus pacientes?
              </legend>
              <div className="flex flex-wrap gap-2">
                {TITULOS_DEL_MEDICO.map((t) => (
                  <Sugerencia
                    key={t}
                    activa={alta.doctorTitle === t}
                    onClick={() => setAlta((a) => ({ ...a, doctorTitle: t }))}
                  >
                    {t}
                  </Sugerencia>
                ))}
              </div>
              {error('doctorTitle') ? (
                <p
                  id={`${idDe('doctorTitle')}-error`}
                  className="mt-2 flex gap-1.5 text-[0.85rem] leading-snug text-[#B3261E]"
                >
                  <CircleAlert
                    aria-hidden
                    className="mt-[0.1rem] size-3.5 shrink-0"
                  />
                  {error('doctorTitle')}
                </p>
              ) : (
                <p className="mt-2 text-[0.85rem] leading-snug text-portada-tinta-3">
                  {alta.ownerName.trim().length >= 3 && alta.doctorTitle ? (
                    <>
                      En los mensajes a tus pacientes dirá:{' '}
                      <span className="font-medium text-portada-tinta">
                        {comoLoNombran(alta.doctorTitle, alta.ownerName)}
                      </span>
                    </>
                  ) : (
                    'Va delante de tu nombre en los mensajes a tus pacientes. Od. es para odontólogos.'
                  )}
                </p>
              )}
            </fieldset>
            <CampoDeDocumento
              id={idDe('documento')}
              etiqueta="Cédula o RIF"
              value={documento}
              onChange={setDocumento}
              alSalir={tocar('documento')}
              error={error('documento')}
              ayuda="Cambia la letra para escribir un RIF (J o G) o un pasaporte (P)."
              letras={LETRAS_CEDULA_O_RIF}
            />
            {esRifDeEmpresa(documento) && (
              <CampoDeDocumento
                id={idDe('ownerDocument')}
                etiqueta="Tu cédula"
                value={alta.ownerDocument}
                onChange={campo('ownerDocument')}
                alSalir={tocar('ownerDocument')}
                error={error('ownerDocument')}
                ayuda="Con el RIF del consultorio necesitamos también tu cédula."
                letras={LETRAS_CEDULA}
              />
            )}
            <div>
              <CampoDeTexto
                id={idDe('specialty')}
                etiqueta="Especialidad"
                value={alta.specialty}
                onChange={campo('specialty')}
                alSalir={tocar('specialty')}
                error={error('specialty')}
                autoCapitalize="sentences"
                enterKeyHint="next"
                placeholder="Pediatría, odontología…"
              />
              <div className="mt-3 flex flex-wrap gap-2">
                {ESPECIALIDADES_SUGERIDAS.map((s) => (
                  <Sugerencia
                    key={s}
                    activa={alta.specialty.trim() === s}
                    onClick={() => setAlta((a) => ({ ...a, specialty: s }))}
                  >
                    {s}
                  </Sugerencia>
                ))}
              </div>
            </div>
            <Opcionales
              texto="Añadir N.º de Colegio o MPPS"
              conDatos={!!(alta.collegeNumber || alta.mppsNumber)}
            >
              <div className="grid gap-5 sm:grid-cols-2">
                <CampoDeTexto
                  id={idDe('collegeNumber')}
                  etiqueta="N.º de Colegio o Federación"
                  opcional
                  value={alta.collegeNumber}
                  onChange={campo('collegeNumber')}
                  autoComplete="off"
                  enterKeyHint="next"
                  placeholder="12345"
                />
                <CampoDeTexto
                  id={idDe('mppsNumber')}
                  etiqueta="Matrícula o MPPS"
                  opcional
                  value={alta.mppsNumber}
                  onChange={campo('mppsNumber')}
                  autoComplete="off"
                  enterKeyHint="next"
                  placeholder="54321"
                />
              </div>
            </Opcionales>
          </>
        )}

        {paso === 1 && (
          <>
            <CampoDeTexto
              id={idDe('clinicName')}
              etiqueta="Nombre del consultorio o centro"
              value={alta.clinicName}
              onChange={campo('clinicName')}
              alSalir={tocar('clinicName')}
              error={error('clinicName')}
              autoComplete="organization"
              autoCapitalize="words"
              enterKeyHint="next"
              placeholder="Consultorio Los Palos Grandes"
            />
            <CampoDeTexto
              id={idDe('address')}
              etiqueta="Dirección"
              value={alta.address}
              onChange={campo('address')}
              alSalir={tocar('address')}
              error={error('address')}
              autoComplete="street-address"
              enterKeyHint="next"
              placeholder="Av. Miranda, Torre Médica, piso 3"
            />
            <div className="grid gap-5 sm:grid-cols-2">
              <CampoDeTexto
                id={idDe('phone')}
                etiqueta="Teléfono"
                type="tel"
                value={alta.phone}
                onChange={campo('phone')}
                alSalir={tocar('phone')}
                error={error('phone')}
                inputMode="tel"
                autoComplete="tel"
                enterKeyHint="next"
                placeholder="0414 1234567"
              />
              <CampoDeTexto
                id={idDe('email')}
                etiqueta="Correo electrónico"
                type="email"
                value={alta.email}
                onChange={campo('email')}
                alSalir={tocar('email')}
                error={error('email')}
                inputMode="email"
                autoComplete="email"
                autoCapitalize="none"
                autoCorrect="off"
                spellCheck={false}
                enterKeyHint="next"
                placeholder="consultorio@correo.com"
              />
            </div>
            <p className="-mt-2 text-[0.85rem] leading-snug text-portada-tinta-3">
              Por aquí te escribimos para activar tu cuenta.
            </p>
            <Opcionales
              texto="Añadir red social"
              conDatos={!!(alta.socialNetwork || alta.socialUser)}
            >
              <div className="grid gap-5 sm:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)]">
                <CampoDeSeleccion
                  id={idDe('socialNetwork')}
                  etiqueta="Red social"
                  opcional
                  value={alta.socialNetwork}
                  vacio="Ninguna"
                  opciones={REDES_SOCIALES}
                  onChange={(v) => setAlta((a) => ({ ...a, socialNetwork: v }))}
                  error={error('socialNetwork')}
                />
                <CampoDeTexto
                  id={idDe('socialUser')}
                  etiqueta="Usuario o enlace"
                  opcional
                  value={alta.socialUser}
                  onChange={campo('socialUser')}
                  alSalir={tocar('socialUser')}
                  error={error('socialUser')}
                  autoComplete="off"
                  autoCapitalize="none"
                  autoCorrect="off"
                  spellCheck={false}
                  placeholder="@consultorio.perez"
                />
              </div>
            </Opcionales>
          </>
        )}

        {paso === 2 && (
          <>
            <fieldset className="flex min-w-0 flex-col gap-2.5">
              <legend className="mb-2 text-[0.9rem] font-medium tracking-[-0.01em] text-portada-tinta">
                ¿A nombre de quién está la cuenta?
              </legend>
              <Opcion
                tipo="radio"
                nombre="titular"
                marcada={cuentaPropia}
                onChange={() => setCuentaPropia(true)}
                titulo="A mi nombre"
                nota={`${alta.ownerName.trim()} · ${final.ownerDocument}`}
              />
              <Opcion
                tipo="radio"
                nombre="titular"
                marcada={!cuentaPropia}
                onChange={() => setCuentaPropia(false)}
                titulo="De mi consultorio u otra persona"
                nota="Escribe a nombre de quién está y su cédula o RIF."
              />
            </fieldset>

            {!cuentaPropia && (
              <>
                <CampoDeTexto
                  id={idDe('accountHolder')}
                  etiqueta="Titular de la cuenta"
                  value={alta.accountHolder}
                  onChange={campo('accountHolder')}
                  alSalir={tocar('accountHolder')}
                  error={error('accountHolder')}
                  autoComplete="off"
                  autoCapitalize="words"
                  enterKeyHint="next"
                  placeholder="Consultorio Pérez C.A."
                />
                <CampoDeDocumento
                  id={idDe('holderDocument')}
                  etiqueta="Cédula o RIF del titular"
                  value={alta.holderDocument}
                  onChange={campo('holderDocument')}
                  alSalir={tocar('holderDocument')}
                  error={error('holderDocument')}
                  letras={LETRAS_TITULAR}
                />
              </>
            )}

            <CampoDeTexto
              id={idDe('accountNumber')}
              etiqueta="Número de cuenta"
              value={formatoCuenta(alta.accountNumber)}
              onChange={(v) =>
                setAlta((a) => ({ ...a, accountNumber: digitosDeCuenta(v) }))
              }
              alSalir={tocar('accountNumber')}
              error={error('accountNumber')}
              ayuda={
                banco ? (
                  <span className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
                    <span className="inline-flex items-center gap-1.5 font-medium text-portada-tinta">
                      <CircleCheck
                        aria-hidden
                        className="size-3.5 text-portada-azul"
                      />
                      {banco}
                    </span>
                    <span className="tabular-nums">
                      {digitos} de 20 dígitos
                    </span>
                  </span>
                ) : (
                  'Los 20 dígitos: el banco lo reconocemos por los 4 primeros.'
                )
              }
              inputMode="numeric"
              autoComplete="off"
              enterKeyHint="next"
              placeholder="0134 0000 0000 0000 0000"
            />

            {/* A la vista y no detrás de una casilla (Javier, 2026-10-26):
                día y hora vacíos son «sin capacitación». */}
            <div className="flex flex-col gap-4 border-t border-portada-linea pt-6">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <p className="text-[0.97rem] font-medium leading-snug tracking-[-0.01em] text-portada-tinta">
                    ¿Quieres que te enseñemos a usar Helios en persona?{' '}
                    <span className="font-normal text-portada-tinta-3">
                      (opcional)
                    </span>
                  </p>
                  <p className="mt-1 text-[0.88rem] leading-snug text-portada-tinta-2">
                    Elige el día y la hora que te queden mejor. Si no, déjalo en
                    blanco.
                  </p>
                </div>
                {(capacitacion.dia || capacitacion.hora) && (
                  <button
                    type="button"
                    onClick={() => setCapacitacion(SIN_CAPACITACION)}
                    className="shrink-0 text-[0.88rem] font-medium text-portada-azul underline-offset-4 hover:underline"
                  >
                    Borrar
                  </button>
                )}
              </div>
              <div className="grid gap-5 sm:grid-cols-2">
                <CampoDeTexto
                  id={idDe('capacitacionDia')}
                  etiqueta="Día"
                  type="date"
                  min={sumarDias(hoy, 1)}
                  max={sumarDias(hoy, CAPACITACION_HASTA_DIAS)}
                  value={capacitacion.dia}
                  onChange={(dia) => setCapacitacion((c) => ({ ...c, dia }))}
                  alSalir={tocar('capacitacionDia')}
                  error={error('capacitacionDia')}
                />
                <CampoDeTexto
                  id={idDe('capacitacionHora')}
                  etiqueta="Hora"
                  type="time"
                  step={900}
                  value={capacitacion.hora}
                  onChange={(hora) => setCapacitacion((c) => ({ ...c, hora }))}
                  alSalir={tocar('capacitacionHora')}
                  error={error('capacitacionHora')}
                />
              </div>
            </div>
          </>
        )}

        {/* Fuera de la vista y del tabulador: solo lo rellena un robot. */}
        <div
          aria-hidden
          className="absolute -left-[9999px] h-px w-px overflow-hidden"
        >
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

        {(motivoFinal || envio.isError) && (
          <div
            role="alert"
            className="flex gap-3 rounded-2xl border border-[#F4C7C3] bg-[#FDF2F1] px-4 py-3.5 text-[0.9rem] leading-snug text-[#8A1C12]"
          >
            <CircleAlert aria-hidden className="mt-0.5 size-4 shrink-0" />
            <span>
              <span className="block font-medium">
                No pudimos enviar tu solicitud
              </span>
              <span className="mt-0.5 block text-[#8A1C12]/85">
                {motivoFinal ?? describeError(envio.error)}
              </span>
            </span>
          </div>
        )}

        <div className="mt-2 flex flex-col-reverse gap-3 sm:flex-row sm:items-center sm:justify-between">
          {paso > 0 ? (
            <button
              type="button"
              onClick={() => irAlPaso((paso - 1) as Paso)}
              className="group inline-flex h-12 items-center justify-center gap-1.5 rounded-full px-5 text-[0.95rem] font-medium tracking-[-0.01em] text-portada-tinta-2 transition-colors duration-300 hover:bg-portada-tinta/[0.05] hover:text-portada-tinta"
            >
              <ArrowLeft
                aria-hidden
                className="size-4 transition-transform duration-300 group-hover:-translate-x-0.5"
              />
              Atrás
            </button>
          ) : (
            <span className="hidden sm:block" />
          )}
          <BotonPrincipal
            ocupado={envio.isPending}
            className="w-full sm:w-auto sm:min-w-[220px]"
          >
            {paso < 2
              ? 'Continuar'
              : envio.isPending
                ? 'Enviando…'
                : 'Enviar solicitud'}
          </BotonPrincipal>
        </div>

        {paso === 2 && (
          <p className="text-center text-[0.82rem] leading-relaxed text-portada-tinta-3 sm:text-right">
            Al enviarla aceptas que tratemos estos datos según nuestra{' '}
            <Link
              to="/legal/privacidad"
              className="font-medium text-portada-azul underline-offset-4 hover:underline"
            >
              política de privacidad
            </Link>
            .
          </p>
        )}
      </form>
    </div>
  )
}
