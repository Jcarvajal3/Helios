import type { ReactNode } from 'react'

import { CampoDocumento } from '@/components/CampoDocumento'
import { Input, Select } from '@/components/ui'
import { BANKS } from '@/features/admin/banks'
import { REDES_SOCIALES, cuentaDeOtroBanco, digitosDeCuenta, formatoCuenta } from '@/features/admin/clinicas/clinicas'
import type { AltaDeClinica, ModoDeAlta, RedSocial } from '@/features/admin/clinicas/clinicas'
import { LETRAS_CEDULA, LETRAS_RIF, LETRAS_TITULAR } from '@/lib/documento'

const OPCIONES_BANCO = BANKS.map((b) => ({ value: b.name, label: b.name }))

/**
 * Los campos del alta de una clínica: el médico, el consultorio y a dónde se
 * le paga. Los mismos en la solicitud de la portada (`/afiliacion`), en el
 * alta del equipo y en la revisión de una solicitud, para que lo que pide uno
 * sea lo que ve el otro. La portada (`modo="portada"`) solo pide la
 * transferencia; el equipo ve también el Pago Móvil.
 *
 * La red social, opcional, va con el contacto del consultorio: qué red es y
 * el usuario o el enlace.
 *
 * Las cédulas y el RIF van con `CampoDocumento` (la letra en un selector y
 * solo números), y la cuenta se escribe en bloques de 4 y se guarda sin
 * espacios: así todos los datos quedan en el mismo formato.
 */
export function CamposDeAlta({
  id,
  valor,
  onChange,
  modo = 'equipo',
  autoFocus = false,
}: {
  /** Prefijo de los `id`: dos formularios en la misma página no chocan. */
  id: string
  valor: AltaDeClinica
  onChange: (siguiente: AltaDeClinica) => void
  modo?: ModoDeAlta
  autoFocus?: boolean
}) {
  const campo = (k: keyof AltaDeClinica) => (v: string) => onChange({ ...valor, [k]: v })
  const portada = modo === 'portada'
  const otroBanco = cuentaDeOtroBanco(valor.bank, valor.accountNumber)
  // «Otra» no dice cuál: el rótulo solo nombra la red cuando se sabe.
  const red = valor.socialNetwork === 'otra' ? null : REDES_SOCIALES.find((r) => r.value === valor.socialNetwork)?.label

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
        <CampoDocumento
          id={`${id}-cedula`}
          label="Cédula de identidad o pasaporte"
          value={valor.ownerDocument}
          onChange={campo('ownerDocument')}
          letras={LETRAS_CEDULA}
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
        <CampoDocumento
          id={`${id}-rif`}
          label="RIF (opcional)"
          value={valor.taxId}
          onChange={campo('taxId')}
          letras={LETRAS_RIF}
          placeholder="123456789"
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
        <Select<RedSocial>
          id={`${id}-red-social`}
          label="Red social (opcional)"
          value={valor.socialNetwork}
          placeholder="Ninguna"
          options={[...REDES_SOCIALES]}
          onChange={(v) => onChange({ ...valor, socialNetwork: v })}
        />
        <Input
          id={`${id}-red-social-usuario`}
          label={red ? `Usuario o enlace en ${red} (opcional)` : 'Usuario o enlace (opcional)'}
          value={valor.socialUser}
          onChange={campo('socialUser')}
          autoComplete="off"
          placeholder="@consultorio.perez"
        />
      </Bloque>

      <Bloque
        titulo={portada ? 'Datos para la transferencia' : 'Transferencia'}
        nota={
          portada
            ? 'A esta cuenta te transferimos tus consultas.'
            : 'A dónde se le paga. Pon la transferencia, el Pago Móvil o los dos.'
        }
      >
        <Input
          id={`${id}-titular`}
          label="Titular de la cuenta"
          value={valor.accountHolder}
          onChange={campo('accountHolder')}
          placeholder="Ana María Pérez o Consultorio Pérez C.A."
        />
        <CampoDocumento
          id={`${id}-titular-documento`}
          label="Cédula o RIF del titular"
          value={valor.holderDocument}
          onChange={campo('holderDocument')}
          letras={LETRAS_TITULAR}
        />
        <Select
          id={`${id}-banco`}
          label="Banco"
          value={valor.bank}
          placeholder="Elige el banco"
          options={OPCIONES_BANCO}
          onChange={campo('bank')}
        />
        <div>
          <Input
            id={`${id}-cuenta`}
            label={portada ? 'Número de cuenta (20 dígitos)' : 'Número de cuenta (20 dígitos, opcional)'}
            value={formatoCuenta(valor.accountNumber)}
            onChange={(v) => onChange({ ...valor, accountNumber: digitosDeCuenta(v) })}
            inputMode="numeric"
            placeholder="0134 0000 0000 0000 0000"
            error={!!otroBanco}
          />
          {otroBanco && <p className="mt-1 type-panel-caption text-error">{otroBanco}</p>}
        </div>
      </Bloque>

      {!portada && (
        <Bloque titulo="Pago Móvil (opcional)" nota="Con el mismo titular de arriba.">
          <Select
            id={`${id}-pm-banco`}
            label="Banco"
            value={valor.pagoMovilBank}
            placeholder="Sin Pago Móvil"
            options={OPCIONES_BANCO}
            onChange={campo('pagoMovilBank')}
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
      )}
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
