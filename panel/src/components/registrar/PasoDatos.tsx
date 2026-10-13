import { useEffect, useRef, useState } from 'react'
import { ArrowLeft } from 'lucide-react'

import { Card, SectionTitle, Tecla } from '@/components/ui'
import {
  ESTADOS_DE_VENEZUELA,
  ORDEN_DE_CAMPOS,
  edadEn,
  esCorreo,
  esMovil,
  formatearFecha,
  formatearTelefono,
  leerFechaDeNacimiento,
  nombreDelEstado,
  problemasDelPaciente,
  sugerenciaDeCorreo,
} from '@/features/merchant/paciente'
import type { BorradorPaciente, CampoDePaciente } from '@/features/merchant/paciente'

import { BotonConFoco, Campo, CampoLista, Opciones } from './Campo'
import { SelectorDeNacimiento } from './SelectorDeNacimiento'

const SEXOS: Array<{ value: 'F' | 'M'; label: string }> = [
  { value: 'F', label: 'Femenino' },
  { value: 'M', label: 'Masculino' },
]

/**
 * PASO 2 · LOS DATOS DE UN PACIENTE NUEVO (plan §2.1).
 *
 * Todo obligatorio salvo la ocupación. Cada dato tiene un trabajo en la
 * cobranza, que depende al 100 % de poder localizar al paciente: el móvil
 * con WhatsApp y el correo donde le llega el comprobante. Sin contacto de
 * referencia desde el 2026-10-13. El estado nace en Distrito Capital.
 *
 * Los problemas de un campo se dicen al salir de él, no mientras se teclea:
 * un «correo inválido» en rojo desde la primera letra es ruido. Enter
 * valida el paso entero y lleva el foco al primer campo que falte.
 */
export function PasoDatos({
  documentoLegible,
  paciente,
  onCambio,
  hoy,
  onAtras,
  onSeguir,
}: {
  documentoLegible: string
  paciente: BorradorPaciente
  onCambio: (campo: CampoDePaciente, valor: string) => void
  /** El día de hoy en Caracas: de él sale la edad. */
  hoy: string
  onAtras: () => void
  onSeguir: () => void
}) {
  const [tocados, setTocados] = useState<Set<CampoDePaciente>>(() => new Set())
  const [intentado, setIntentado] = useState(false)

  // Una referencia por campo, para llevar el foco al primero que falte.
  const refs = useRef<Partial<Record<CampoDePaciente, HTMLElement | null>>>({})
  const guardar = (campo: CampoDePaciente) => (el: HTMLElement | null) => {
    refs.current[campo] = el
  }

  useEffect(() => {
    refs.current.firstName?.focus()
  }, [])

  const problemas = problemasDelPaciente(paciente, hoy)
  const visible = (campo: CampoDePaciente) =>
    intentado || tocados.has(campo) ? (problemas[campo] ?? null) : null
  const tocar = (campo: CampoDePaciente) => () =>
    setTocados((t) => (t.has(campo) ? t : new Set(t).add(campo)))

  function seguir() {
    setIntentado(true)
    const primero = ORDEN_DE_CAMPOS.find((c) => problemas[c])
    if (primero) {
      refs.current[primero]?.focus()
      return
    }
    onSeguir()
  }

  // Lo que se confirma mientras se teclea, en verde de ayuda y no en rojo.
  const nacimiento = leerFechaDeNacimiento(paciente.birthDate, hoy)
  const edad = nacimiento && nacimiento <= hoy ? edadEn(nacimiento, hoy) : null
  const sugerencia = esCorreo(paciente.email) ? sugerenciaDeCorreo(paciente.email) : null

  return (
    <form
      noValidate
      onSubmit={(e) => {
        e.preventDefault()
        seguir()
      }}
      className="flex flex-col gap-5"
    >
      <p className="type-panel-body text-on-surface-variant">
        Paciente nuevo · cédula <strong className="text-on-surface">{documentoLegible}</strong>.
        Todos los datos son obligatorios salvo la ocupación.
      </p>

      <Card as="section" className="flex flex-col gap-4">
        <SectionTitle>Identidad</SectionTitle>
        <div className="grid gap-4 sm:grid-cols-2">
          <Campo
            id="alta-nombres"
            label="Nombres"
            value={paciente.firstName}
            onChange={(v) => onCambio('firstName', v)}
            onBlur={tocar('firstName')}
            inputRef={guardar('firstName')}
            autoComplete="off"
            maxLength={80}
            error={visible('firstName')}
          />
          <Campo
            id="alta-apellidos"
            label="Apellidos"
            value={paciente.lastName}
            onChange={(v) => onCambio('lastName', v)}
            onBlur={tocar('lastName')}
            inputRef={guardar('lastName')}
            autoComplete="off"
            maxLength={80}
            error={visible('lastName')}
          />
          <Campo
            id="alta-nacimiento"
            label="Fecha de nacimiento"
            value={paciente.birthDate}
            onChange={(v) => onCambio('birthDate', v)}
            onBlur={tocar('birthDate')}
            inputRef={guardar('birthDate')}
            inputMode="numeric"
            autoComplete="off"
            placeholder="dd/mm/aaaa"
            // Solo se teclean cifras: las barras las pone el campo.
            formato={formatearFecha}
            sufijo={
              <SelectorDeNacimiento
                valor={paciente.birthDate}
                hoy={hoy}
                inputId="alta-nacimiento"
                onElegir={(v) => {
                  onCambio('birthDate', v)
                  tocar('birthDate')()
                }}
              />
            }
            // La edad sale en cuanto la fecha se puede leer, aunque todavía no
            // se haya salido del campo: un menor se detecta aquí y no al final.
            error={
              visible('birthDate') ??
              (edad !== null && problemas.birthDate ? problemas.birthDate : null)
            }
            hint={
              edad !== null
                ? `${edad} ${edad === 1 ? 'año' : 'años'}`
                : 'Escribe 12041990 o elígela en el calendario'
            }
          />
          <Opciones
            id="alta-sexo"
            label="Sexo"
            value={paciente.sex}
            opciones={SEXOS}
            onChange={(v) => {
              onCambio('sex', v)
              tocar('sex')()
            }}
            primeraRef={guardar('sex')}
            error={visible('sex')}
          />
        </div>
      </Card>

      <Card as="section" className="flex flex-col gap-4">
        <SectionTitle>Contacto</SectionTitle>
        <div className="grid gap-4 sm:grid-cols-2">
          <Campo
            id="alta-telefono"
            label="Teléfono móvil (con WhatsApp)"
            type="tel"
            inputMode="tel"
            value={paciente.phone}
            onChange={(v) => onCambio('phone', v)}
            onBlur={tocar('phone')}
            inputRef={guardar('phone')}
            autoComplete="off"
            placeholder="0414-123.45.67"
            formato={formatearTelefono}
            error={visible('phone')}
            hint={esMovil(paciente.phone) ? '✓ Móvil válido' : '0412, 0414, 0416, 0422, 0424 o 0426'}
            className="sm:col-span-2"
          />
          <Campo
            id="alta-correo"
            label="Correo electrónico"
            type="email"
            inputMode="email"
            value={paciente.email}
            onChange={(v) => onCambio('email', v)}
            onBlur={tocar('email')}
            inputRef={guardar('email')}
            autoComplete="off"
            maxLength={120}
            placeholder="nombre@gmail.com"
            error={visible('email')}
            className="sm:col-span-2"
            hint={
              sugerencia ? (
                <span>
                  ¿Quisiste decir{' '}
                  <button
                    type="button"
                    onClick={() => onCambio('email', sugerencia)}
                    className="font-semibold text-on-surface underline underline-offset-2"
                  >
                    {sugerencia}
                  </button>
                  ?
                </span>
              ) : (
                'Ahí le llega el comprobante con sus cuotas'
              )
            }
          />
        </div>
      </Card>

      <Card as="section" className="flex flex-col gap-4">
        <SectionTitle>Dirección</SectionTitle>
        <div className="grid gap-4 sm:grid-cols-2">
          <CampoLista
            id="alta-estado"
            label="Estado"
            value={paciente.state}
            opciones={ESTADOS_DE_VENEZUELA}
            etiqueta={nombreDelEstado}
            onChange={(v) => onCambio('state', v)}
            onBlur={tocar('state')}
            selectRef={guardar('state')}
            error={visible('state')}
          />
          <Campo
            id="alta-direccion"
            label="Dirección"
            value={paciente.address}
            onChange={(v) => onCambio('address', v)}
            onBlur={tocar('address')}
            inputRef={guardar('address')}
            autoComplete="off"
            maxLength={160}
            placeholder="Ciudad o municipio, urbanización, calle, casa…"
            error={visible('address')}
          />
          <Campo
            id="alta-ocupacion"
            label="Ocupación"
            opcional
            value={paciente.occupation}
            onChange={(v) => onCambio('occupation', v)}
            onBlur={tocar('occupation')}
            inputRef={guardar('occupation')}
            autoComplete="off"
            maxLength={80}
            error={visible('occupation')}
            className="sm:col-span-2"
          />
        </div>
      </Card>

      <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap sm:items-center sm:gap-3">
        <BotonConFoco type="submit">
          Continuar al monto
          <Tecla enBoton>Enter</Tecla>
        </BotonConFoco>
        <BotonConFoco variant="text" onClick={onAtras}>
          <ArrowLeft size={16} aria-hidden />
          Cambiar la cédula
        </BotonConFoco>
      </div>
    </form>
  )
}
