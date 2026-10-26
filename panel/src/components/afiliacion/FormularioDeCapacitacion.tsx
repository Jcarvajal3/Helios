import { useState } from 'react'
import type { FormEvent } from 'react'
import { useMutation } from '@tanstack/react-query'
import { CircleAlert } from 'lucide-react'

import { BotonPrincipal, CampoDeTexto, Sugerencia } from './piezas'
import { sumarDias } from '@/components/kit/rango'
import {
  CAPACITACION_HASTA_DIAS,
  capacitacionParaEnviar,
  motivoDeCapacitacion,
  telefonoAE164,
} from '@/features/admin/clinicas/clinicas'
import { describeError, supabase } from '@/lib/supabase'

/** Lo que el aviso de «Capacitación agendada» necesita saber. */
export type CapacitacionAgendada = {
  phone: string
  /** La capacitación (instante ISO). */
  capacitacion: string
}

type Datos = {
  nombre: string
  telefono: string
  especialidad: string
  direccion: string
  dia: string
  hora: string
}

type Campo = keyof Datos

const VACIO: Datos = {
  nombre: '',
  telefono: '',
  especialidad: '',
  direccion: '',
  dia: '',
  hora: '',
}

const ORDEN: readonly Campo[] = [
  'nombre',
  'telefono',
  'especialidad',
  'direccion',
  'dia',
  'hora',
]

const ESPECIALIDADES_SUGERIDAS = [
  'Medicina general',
  'Odontología',
  'Cosmetología',
] as const

const idDe = (c: Campo) => `capacitacion-${c}`

/** Qué falta o está mal en cada campo (lo mismo que valida la base). */
function erroresDe(d: Datos, hoy: string): Partial<Record<Campo, string>> {
  const e: Partial<Record<Campo, string>> = {}
  const nombre = d.nombre.trim()
  if (nombre.length < 3) e.nombre = 'Escribe tu nombre y apellido.'
  else if (nombre.length > 120) e.nombre = 'El nombre es demasiado largo.'
  if (!d.telefono.trim()) e.telefono = 'Escribe tu teléfono.'
  else if (!telefonoAE164(d.telefono))
    e.telefono = 'No parece venezolano: 0414 1234567 o 0212 5551234.'
  if (!d.especialidad.trim()) e.especialidad = 'Escribe tu especialidad.'
  else if (d.especialidad.trim().length > 80)
    e.especialidad = 'La especialidad es demasiado larga.'
  if (d.direccion.trim().length < 5)
    e.direccion = 'Escribe la dirección de tu consultorio.'
  else if (d.direccion.trim().length > 300)
    e.direccion = 'La dirección es demasiado larga.'
  if (!d.dia) e.dia = 'Elige el día.'
  if (!d.hora) e.hora = 'Elige la hora.'
  if (d.dia && d.hora) {
    const motivo = motivoDeCapacitacion({ dia: d.dia, hora: d.hora }, hoy)
    if (motivo) e.dia = motivo
  }
  return e
}

/**
 * EL FORMULARIO DEL QR — un solo paso: nombre, teléfono, especialidad,
 * dirección del consultorio y el día y la hora de la capacitación
 * presencial. Va a `helios_agendar_capacitacion`, que lo deja en
 * Superadmin › Agenda como la visita del médico.
 *
 * Los errores salen como en la afiliación: el de un campo mal escrito al
 * dejarlo, el de uno vacío al pulsar el botón (y el foco va al primero).
 */
export function FormularioDeCapacitacion({
  hoy,
  alEnviar,
}: {
  /** El día de Caracas, 'YYYY-MM-DD'. */
  hoy: string
  alEnviar: (agendada: CapacitacionAgendada) => void
}) {
  const [datos, setDatos] = useState<Datos>(VACIO)
  // El campo que no se ve: si llega con algo, lo rellenó un robot.
  const [sitioWeb, setSitioWeb] = useState('')
  const [tocados, setTocados] = useState<ReadonlySet<Campo>>(new Set())
  const [intentado, setIntentado] = useState(false)

  const errores = erroresDe(datos, hoy)

  function error(c: Campo): string | null {
    const e = errores[c]
    return e && (intentado || tocados.has(c)) ? e : null
  }

  const tocar = (c: Campo) => () =>
    setTocados((t) => (t.has(c) ? t : new Set(t).add(c)))

  const campo = (c: Campo) => (v: string) => setDatos((d) => ({ ...d, [c]: v }))

  const envio = useMutation({
    mutationFn: async (p: Record<string, unknown>) => {
      const { error: e } = await supabase.rpc('helios_agendar_capacitacion', {
        p,
      })
      if (e) throw e
    },
  })

  function enviar(e: FormEvent) {
    e.preventDefault()
    if (envio.isPending) return

    const falla = ORDEN.find((c) => errores[c])
    if (falla) {
      setIntentado(true)
      const el = document.getElementById(idDe(falla))
      el?.focus({ preventScroll: true })
      el?.scrollIntoView({ behavior: 'smooth', block: 'center' })
      return
    }

    const instante = capacitacionParaEnviar({ dia: datos.dia, hora: datos.hora })
    if (!instante) return
    envio.mutate(
      {
        name: datos.nombre.trim(),
        phone: telefonoAE164(datos.telefono),
        specialty: datos.especialidad.trim(),
        address: datos.direccion.trim(),
        training_at: instante,
        sitio_web: sitioWeb,
      },
      {
        onSuccess: () =>
          alEnviar({ phone: datos.telefono.trim(), capacitacion: instante }),
      },
    )
  }

  return (
    <div className="rounded-[28px] border border-portada-linea bg-white p-5 shadow-[0_30px_60px_-40px_rgba(0,39,112,0.35)] sm:p-8">
      <form onSubmit={enviar} noValidate className="flex flex-col gap-5">
        <CampoDeTexto
          id={idDe('nombre')}
          etiqueta="Nombre y apellido"
          value={datos.nombre}
          onChange={campo('nombre')}
          alSalir={tocar('nombre')}
          error={error('nombre')}
          autoComplete="name"
          autoCapitalize="words"
          enterKeyHint="next"
          placeholder="Ana María Pérez"
        />
        <CampoDeTexto
          id={idDe('telefono')}
          etiqueta="Teléfono"
          type="tel"
          value={datos.telefono}
          onChange={campo('telefono')}
          alSalir={tocar('telefono')}
          error={error('telefono')}
          inputMode="tel"
          autoComplete="tel"
          enterKeyHint="next"
          placeholder="0414 1234567"
        />
        <div>
          <CampoDeTexto
            id={idDe('especialidad')}
            etiqueta="Especialidad"
            value={datos.especialidad}
            onChange={campo('especialidad')}
            alSalir={tocar('especialidad')}
            error={error('especialidad')}
            autoCapitalize="sentences"
            enterKeyHint="next"
            placeholder="Pediatría, odontología…"
          />
          <div className="mt-3 flex flex-wrap gap-2">
            {ESPECIALIDADES_SUGERIDAS.map((s) => (
              <Sugerencia
                key={s}
                activa={datos.especialidad.trim() === s}
                onClick={() => setDatos((d) => ({ ...d, especialidad: s }))}
              >
                {s}
              </Sugerencia>
            ))}
          </div>
        </div>
        <CampoDeTexto
          id={idDe('direccion')}
          etiqueta="Dirección del consultorio"
          value={datos.direccion}
          onChange={campo('direccion')}
          alSalir={tocar('direccion')}
          error={error('direccion')}
          autoComplete="street-address"
          enterKeyHint="next"
          placeholder="Av. Miranda, Torre Médica, piso 3"
        />

        <fieldset className="flex min-w-0 flex-col gap-4 border-t border-portada-linea pt-6">
          <legend className="float-left w-full text-[0.97rem] font-medium leading-snug tracking-[-0.01em] text-portada-tinta">
            Fecha de la capacitación
          </legend>
          <p className="-mt-3 text-[0.88rem] leading-snug text-portada-tinta-2">
            Vamos a tu consultorio y te enseñamos a usar Helios. Elige el día y
            la hora que te queden mejor.
          </p>
          <div className="grid gap-5 sm:grid-cols-2">
            <CampoDeTexto
              id={idDe('dia')}
              etiqueta="Día"
              type="date"
              min={sumarDias(hoy, 1)}
              max={sumarDias(hoy, CAPACITACION_HASTA_DIAS)}
              value={datos.dia}
              onChange={campo('dia')}
              alSalir={tocar('dia')}
              error={error('dia')}
            />
            <CampoDeTexto
              id={idDe('hora')}
              etiqueta="Hora"
              type="time"
              step={900}
              value={datos.hora}
              onChange={campo('hora')}
              alSalir={tocar('hora')}
              error={error('hora')}
            />
          </div>
        </fieldset>

        {/* Fuera de la vista y del tabulador: solo lo rellena un robot. */}
        <div
          aria-hidden
          className="absolute -left-[9999px] h-px w-px overflow-hidden"
        >
          <label htmlFor="capacitacion-sitio-web">Sitio web</label>
          <input
            id="capacitacion-sitio-web"
            name="sitio_web"
            tabIndex={-1}
            autoComplete="off"
            value={sitioWeb}
            onChange={(e) => setSitioWeb(e.target.value)}
          />
        </div>

        {envio.isError && (
          <div
            role="alert"
            className="flex gap-3 rounded-2xl border border-[#F4C7C3] bg-[#FDF2F1] px-4 py-3.5 text-[0.9rem] leading-snug text-[#8A1C12]"
          >
            <CircleAlert aria-hidden className="mt-0.5 size-4 shrink-0" />
            <span>
              <span className="block font-medium">
                No pudimos agendar tu capacitación
              </span>
              <span className="mt-0.5 block text-[#8A1C12]/85">
                {describeError(envio.error)}
              </span>
            </span>
          </div>
        )}

        <BotonPrincipal ocupado={envio.isPending} className="mt-2 w-full">
          {envio.isPending ? 'Agendando…' : 'Agendar capacitación'}
        </BotonPrincipal>
      </form>
    </div>
  )
}
