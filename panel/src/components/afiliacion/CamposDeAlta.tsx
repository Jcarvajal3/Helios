import type { ReactNode } from 'react'

import { Input, Select } from '@/components/ui'
import { BANKS } from '@/features/admin/banks'
import type { AltaDeClinica } from '@/features/admin/clinicas/clinicas'

const OPCIONES_BANCO = BANKS.map((b) => ({ value: b.name, label: b.name }))

/**
 * Los campos del alta de una clínica, en tres bloques: el médico, el
 * consultorio y el Pago Móvil. Los mismos en la solicitud de la portada
 * (`/afiliacion`), en el alta del equipo y en la revisión de una solicitud,
 * para que lo que pide uno sea lo que ve el otro.
 */
export function CamposDeAlta({
  id,
  valor,
  onChange,
  autoFocus = false,
}: {
  /** Prefijo de los `id`: dos formularios en la misma página no chocan. */
  id: string
  valor: AltaDeClinica
  onChange: (siguiente: AltaDeClinica) => void
  autoFocus?: boolean
}) {
  const campo = (k: keyof AltaDeClinica) => (v: string) => onChange({ ...valor, [k]: v })

  return (
    <div className="flex flex-col gap-6">
      <Bloque titulo="El médico">
        <Input
          id={`${id}-nombre`}
          label="Nombre completo"
          value={valor.ownerName}
          onChange={campo('ownerName')}
          autoComplete="name"
          placeholder="Ana María Pérez"
          autoFocus={autoFocus}
        />
        <Input
          id={`${id}-cedula`}
          label="Cédula de identidad o pasaporte"
          value={valor.ownerDocument}
          onChange={campo('ownerDocument')}
          placeholder="V-12345678"
        />
        <Input
          id={`${id}-especialidad`}
          label="Especialidad"
          value={valor.specialty}
          onChange={campo('specialty')}
          placeholder="Pediatría, odontología, cosmetología…"
        />
        <Input
          id={`${id}-colegio`}
          label="N.º de Colegio o Federación (opcional)"
          value={valor.collegeNumber}
          onChange={campo('collegeNumber')}
          placeholder="12345"
        />
        <Input
          id={`${id}-mpps`}
          label="Matrícula o MPPS (opcional)"
          value={valor.mppsNumber}
          onChange={campo('mppsNumber')}
          placeholder="54321"
        />
      </Bloque>

      <Bloque titulo="El consultorio">
        <Input
          id={`${id}-consultorio`}
          label="Nombre del consultorio o centro médico"
          value={valor.clinicName}
          onChange={campo('clinicName')}
          autoComplete="organization"
          placeholder="Consultorio Pediátrico Los Palos Grandes"
        />
        <Input
          id={`${id}-rif`}
          label="RIF (opcional)"
          value={valor.taxId}
          onChange={campo('taxId')}
          placeholder="J-123456789"
        />
        <Input
          id={`${id}-direccion`}
          label="Dirección del consultorio"
          value={valor.address}
          onChange={campo('address')}
          autoComplete="street-address"
          placeholder="Av. Francisco de Miranda, Torre Médica, piso 3"
          className="sm:col-span-2"
        />
        <Input
          id={`${id}-telefono`}
          label="Número de teléfono"
          value={valor.phone}
          onChange={campo('phone')}
          inputMode="tel"
          autoComplete="tel"
          placeholder="0414 1234567"
        />
        <Input
          id={`${id}-correo`}
          label="Correo electrónico"
          type="email"
          value={valor.email}
          onChange={campo('email')}
          autoComplete="email"
          placeholder="consultorio@correo.com"
        />
      </Bloque>

      <Bloque titulo="Pago Móvil" nota="A esta cuenta te pagamos tus consultas.">
        <Select
          id={`${id}-pm-banco`}
          label="Banco"
          value={valor.pagoMovilBank}
          placeholder="Elige el banco"
          options={OPCIONES_BANCO}
          onChange={campo('pagoMovilBank')}
          className="sm:col-span-2"
        />
        <Input
          id={`${id}-pm-documento`}
          label="Cédula o RIF"
          value={valor.pagoMovilDocument}
          onChange={campo('pagoMovilDocument')}
          placeholder="V-12345678"
        />
        <Input
          id={`${id}-pm-telefono`}
          label="Número de teléfono"
          value={valor.pagoMovilPhone}
          onChange={campo('pagoMovilPhone')}
          inputMode="tel"
          placeholder="0414 1234567"
        />
      </Bloque>
    </div>
  )
}

function Bloque({ titulo, nota, children }: { titulo: string; nota?: string; children: ReactNode }) {
  return (
    <fieldset className="flex flex-col gap-3">
      <legend className="mb-3 type-panel-section text-on-surface">
        {titulo}
        {nota && <span className="mt-1 block type-panel-caption text-on-surface-variant">{nota}</span>}
      </legend>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">{children}</div>
    </fieldset>
  )
}
