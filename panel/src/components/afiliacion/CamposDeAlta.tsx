import { useState } from 'react'
import type { ReactNode } from 'react'
import { ChevronDown, CircleCheck } from 'lucide-react'

import { CampoDocumento } from '@/components/CampoDocumento'
import { Chip, Input, Segmented, Select } from '@/components/ui'
import type { Moneda } from '@/components/ui'
import { BANKS } from '@/features/admin/banks'
import {
  REDES_SOCIALES,
  TITULOS_DEL_MEDICO,
  comoLoNombran,
  digitosDeCuenta,
  formatoCuenta,
} from '@/features/admin/clinicas/clinicas'
import type { AltaDeClinica, RedSocial } from '@/features/admin/clinicas/clinicas'
import { ESPECIALIDADES } from '@/features/directorio/especialidades'
import { LETRAS_CEDULA_O_RIF, bancoDeCuenta, esRifDeEmpresa } from '@/features/afiliacion/pasos'
import { LETRAS_CEDULA, LETRAS_TITULAR } from '@/lib/documento'

const OPCIONES_BANCO = BANKS.map((b) => ({ value: b.name, label: b.name }))

const OPCIONES_MONEDA: Array<{ value: Moneda; label: string }> = [
  { value: 'USD', label: 'Dólares ($)' },
  { value: 'EUR', label: 'Euros (€)' },
]

/** «Otras especialidades»: abre un campo para escribirla, como en la portada. */
const OTRA = 'otra'
const OPCIONES_ESPECIALIDAD = [
  ...ESPECIALIDADES.filter((e) => e.clave !== OTRA).map((e) => ({ value: e.nombre, label: e.nombre })),
  { value: OTRA, label: 'Otras especialidades' },
]
const NOMBRES_DE_LA_LISTA: ReadonlySet<string> = new Set(OPCIONES_ESPECIALIDAD.map((o) => o.value))

/**
 * Los campos del alta de una clínica que llena el equipo, con la misma
 * estructura que la afiliación de la portada (`FormularioDeAfiliacion`):
 *
 * 1. El médico: nombre, cómo lo nombran sus pacientes (Dr., Dra.…, con cómo
 *    quedará), «Cédula o RIF» (con un RIF de empresa se pide además su
 *    cédula), la especialidad de la lista del directorio y, opcionales, el
 *    Colegio y el MPPS.
 * 2. El consultorio: nombre, dirección, teléfono personal, teléfono de
 *    contacto (opcional, el que sale en el directorio), correo y, opcionales,
 *    la red social y el precio mínimo de la consulta (con él nace su ficha
 *    del directorio, oculta, ya con el precio).
 * 3. Dónde se le paga: a nombre de quién está la cuenta (del médico, o del
 *    consultorio u otra persona) y el número de cuenta, del que sale el
 *    banco. El equipo puede añadir además el Pago Móvil.
 *
 * Los mismos en el alta y en la revisión de una solicitud. Lo que se guarda
 * sigue siendo un `AltaDeClinica`: «Cédula o RIF» reparte entre
 * `ownerDocument` y `taxId` como `altaParaEnviar`, y con la cuenta «del
 * médico» el titular es él.
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
  // La cuenta es del médico si no hay titular o el titular es él.
  const [cuentaPropia, setCuentaPropia] = useState(
    () =>
      !valor.accountHolder.trim() ||
      (valor.accountHolder.trim() === valor.ownerName.trim() && valor.holderDocument === valor.ownerDocument),
  )
  const [otraEspecialidad, setOtraEspecialidad] = useState(
    () => !!valor.specialty.trim() && !NOMBRES_DE_LA_LISTA.has(valor.specialty.trim()),
  )
  const [conColegio, setConColegio] = useState(() => !!(valor.collegeNumber || valor.mppsNumber))
  const [conRed, setConRed] = useState(() => !!(valor.socialNetwork || valor.socialUser))
  const [conPrecio, setConPrecio] = useState(() => !!valor.consultationPrice.trim())
  const [conPagoMovil, setConPagoMovil] = useState(() => !!(valor.pagoMovilBank || valor.pagoMovilPhone))

  /** Cada cambio sale con el banco de la cuenta y, si la cuenta es suya, el médico de titular. */
  function emitir(siguiente: AltaDeClinica, propia = cuentaPropia) {
    const banco = bancoDeCuenta(siguiente.accountNumber)
    onChange({
      ...siguiente,
      bank: banco || (digitosDeCuenta(siguiente.accountNumber).length >= 4 ? '' : siguiente.bank),
      ...(propia ? { accountHolder: siguiente.ownerName, holderDocument: siguiente.ownerDocument } : {}),
    })
  }
  const campo = (k: keyof AltaDeClinica) => (v: string) => emitir({ ...valor, [k]: v })

  // «Cédula o RIF»: un RIF de empresa (J o G) va a `taxId` y pide además la cédula.
  const empresa = !!valor.taxId && esRifDeEmpresa(valor.taxId)
  const documento = empresa ? valor.taxId : valor.ownerDocument
  function cambiarDocumento(v: string) {
    if (esRifDeEmpresa(v)) emitir({ ...valor, taxId: v, ownerDocument: empresa ? valor.ownerDocument : '' })
    else emitir({ ...valor, ownerDocument: v, taxId: '' })
  }

  const banco = bancoDeCuenta(valor.accountNumber)
  const digitos = digitosDeCuenta(valor.accountNumber).length
  // «Otra» no dice cuál: el rótulo solo nombra la red cuando se sabe.
  const red = valor.socialNetwork === 'otra' ? null : REDES_SOCIALES.find((r) => r.value === valor.socialNetwork)?.label

  return (
    <div className="flex flex-col gap-6">
      <Bloque titulo="1. El médico">
        <Input
          id={`${id}-nombre`}
          label="Nombre y apellido"
          value={valor.ownerName}
          onChange={campo('ownerName')}
          autoComplete="name"
          placeholder="Ana María Pérez"
          autoFocus={autoFocus}
          className="sm:col-span-2"
        />
        <fieldset className="flex min-w-0 flex-col gap-2 sm:col-span-2">
          <legend className="mb-1.5 type-panel-label text-on-surface-variant">
            ¿Cómo quiere que lo nombren sus pacientes?
          </legend>
          <div className="flex flex-wrap gap-1.5">
            {TITULOS_DEL_MEDICO.map((t) => (
              <Chip key={t} selected={valor.doctorTitle === t} onClick={() => emitir({ ...valor, doctorTitle: t })}>
                {t}
              </Chip>
            ))}
          </div>
          <p className="type-panel-caption text-on-surface-variant">
            {valor.ownerName.trim().length >= 3 && valor.doctorTitle ? (
              <>
                En los mensajes a sus pacientes dirá:{' '}
                <span className="font-medium text-on-surface">{comoLoNombran(valor.doctorTitle, valor.ownerName)}</span>
              </>
            ) : (
              'Va delante de su nombre en los mensajes a sus pacientes. Od. es para odontólogos.'
            )}
          </p>
        </fieldset>
        <CampoDocumento
          id={`${id}-documento`}
          label="Cédula o RIF"
          value={documento}
          onChange={cambiarDocumento}
          letras={LETRAS_CEDULA_O_RIF}
        />
        {empresa ? (
          <CampoDocumento
            id={`${id}-cedula`}
            label="Su cédula (con el RIF del consultorio)"
            value={valor.ownerDocument}
            onChange={campo('ownerDocument')}
            letras={LETRAS_CEDULA}
          />
        ) : (
          <span className="hidden sm:block" />
        )}
        <Select
          id={`${id}-especialidad`}
          label="Especialidad"
          value={otraEspecialidad ? OTRA : valor.specialty}
          placeholder="Elige la especialidad"
          options={OPCIONES_ESPECIALIDAD}
          onChange={(v) => {
            if (v === OTRA) {
              setOtraEspecialidad(true)
              emitir({ ...valor, specialty: NOMBRES_DE_LA_LISTA.has(valor.specialty) ? '' : valor.specialty })
            } else {
              setOtraEspecialidad(false)
              emitir({ ...valor, specialty: v })
            }
          }}
        />
        {otraEspecialidad ? (
          <Input
            id={`${id}-especialidad-otra`}
            label="¿Cuál?"
            value={valor.specialty}
            onChange={campo('specialty')}
            placeholder="Escribe su especialidad"
          />
        ) : (
          <span className="hidden sm:block" />
        )}
        <Opcional
          abierto={conColegio}
          onAbrir={() => setConColegio(true)}
          texto="Añadir N.º de Colegio o MPPS"
        >
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
        </Opcional>
      </Bloque>

      <Bloque titulo="2. El consultorio">
        <Input
          id={`${id}-consultorio`}
          label="Nombre del consultorio o centro"
          value={valor.clinicName}
          onChange={campo('clinicName')}
          autoComplete="organization"
          placeholder="Consultorio Los Palos Grandes"
          className="sm:col-span-2"
        />
        <Input
          id={`${id}-direccion`}
          label="Dirección"
          value={valor.address}
          onChange={campo('address')}
          autoComplete="street-address"
          placeholder="Av. Miranda, Torre Médica, piso 3"
          className="sm:col-span-2"
        />
        <Input
          id={`${id}-telefono`}
          label="Teléfono personal"
          value={valor.phone}
          onChange={campo('phone')}
          inputMode="tel"
          autoComplete="tel"
          placeholder="0414 1234567"
        />
        <Input
          id={`${id}-telefono-contacto`}
          label="Teléfono de contacto (opcional)"
          value={valor.contactPhone}
          onChange={campo('contactPhone')}
          inputMode="tel"
          autoComplete="off"
          placeholder="0424 7654321"
          hint="El que sale en su ficha del directorio. En blanco, sale el personal."
        />
        <Input
          id={`${id}-correo`}
          label="Correo electrónico"
          type="email"
          value={valor.email}
          onChange={campo('email')}
          autoComplete="email"
          placeholder="consultorio@correo.com"
          className="sm:col-span-2"
        />
        <Opcional abierto={conRed} onAbrir={() => setConRed(true)} texto="Añadir red social">
          <Select<RedSocial>
            id={`${id}-red-social`}
            label="Red social (opcional)"
            value={valor.socialNetwork}
            placeholder="Ninguna"
            options={[...REDES_SOCIALES]}
            onChange={(v) => emitir({ ...valor, socialNetwork: v })}
          />
          <Input
            id={`${id}-red-social-usuario`}
            label={red ? `Usuario o enlace en ${red} (opcional)` : 'Usuario o enlace (opcional)'}
            value={valor.socialUser}
            onChange={campo('socialUser')}
            autoComplete="off"
            placeholder="@consultorio.perez"
          />
        </Opcional>
        <Opcional abierto={conPrecio} onAbrir={() => setConPrecio(true)} texto="Añadir precio de consulta">
          <Input
            id={`${id}-precio`}
            label="Precio mínimo de consulta (opcional)"
            value={valor.consultationPrice}
            onChange={campo('consultationPrice')}
            inputMode="decimal"
            autoComplete="off"
            placeholder="40"
            hint="Sale en su ficha del directorio como «Consulta a partir de»."
          />
          <Select<Moneda>
            id={`${id}-precio-moneda`}
            label="Moneda"
            value={valor.consultationCurrency}
            options={OPCIONES_MONEDA}
            onChange={(v) => emitir({ ...valor, consultationCurrency: v })}
          />
        </Opcional>
      </Bloque>

      <Bloque titulo="3. Dónde se le paga">
        <div className="flex flex-col gap-1.5 sm:col-span-2">
          <span className="type-panel-label text-on-surface-variant">¿A nombre de quién está la cuenta?</span>
          <Segmented
            etiqueta="A nombre de quién está la cuenta"
            options={[
              { value: 'propia', label: 'A nombre del médico' },
              { value: 'otra', label: 'Del consultorio u otra persona' },
            ]}
            value={cuentaPropia ? 'propia' : 'otra'}
            onChange={(v) => {
              const propia = v === 'propia'
              setCuentaPropia(propia)
              emitir(propia ? valor : { ...valor, accountHolder: '', holderDocument: '' }, propia)
            }}
          />
          {cuentaPropia && valor.ownerName.trim() && (
            <span className="type-panel-caption text-on-surface-variant">
              Titular: {valor.ownerName.trim()}
              {valor.ownerDocument ? ` · ${valor.ownerDocument}` : ''}
            </span>
          )}
        </div>
        {!cuentaPropia && (
          <>
            <Input
              id={`${id}-titular`}
              label="Titular de la cuenta"
              value={valor.accountHolder}
              onChange={campo('accountHolder')}
              placeholder="Consultorio Pérez C.A."
            />
            <CampoDocumento
              id={`${id}-titular-documento`}
              label="Cédula o RIF del titular"
              value={valor.holderDocument}
              onChange={campo('holderDocument')}
              letras={LETRAS_TITULAR}
            />
          </>
        )}
        <div className="sm:col-span-2">
          <Input
            id={`${id}-cuenta`}
            label="Número de cuenta"
            value={formatoCuenta(valor.accountNumber)}
            onChange={(v) => emitir({ ...valor, accountNumber: digitosDeCuenta(v) })}
            inputMode="numeric"
            placeholder="0134 0000 0000 0000 0000"
            error={digitos >= 4 && !banco}
          />
          <p className={`mt-1 type-panel-caption ${digitos >= 4 && !banco ? 'text-error' : 'text-on-surface-variant'}`}>
            {banco ? (
              <span className="flex flex-wrap items-center justify-between gap-x-3">
                <span className="inline-flex items-center gap-1.5 font-medium text-on-surface">
                  <CircleCheck size={13} aria-hidden className="text-primary" /> {banco}
                </span>
                <span className="tabular-nums">{digitos} de 20 dígitos</span>
              </span>
            ) : digitos >= 4 ? (
              'No reconocemos el banco por sus 4 primeros dígitos.'
            ) : (
              'Los 20 dígitos: el banco se reconoce por los 4 primeros.'
            )}
          </p>
        </div>
        <Opcional abierto={conPagoMovil} onAbrir={() => setConPagoMovil(true)} texto="Añadir Pago Móvil (opcional)">
          <Select
            id={`${id}-pm-banco`}
            label="Banco del Pago Móvil"
            value={valor.pagoMovilBank}
            placeholder="Sin Pago Móvil"
            options={OPCIONES_BANCO}
            onChange={campo('pagoMovilBank')}
          />
          <Input
            id={`${id}-pm-telefono`}
            label="Teléfono del Pago Móvil"
            value={valor.pagoMovilPhone}
            onChange={campo('pagoMovilPhone')}
            inputMode="tel"
            placeholder="0414 1234567"
          />
        </Opcional>
      </Bloque>
    </div>
  )
}

/** Un grupo del alta: su título y los campos en dos columnas. */
function Bloque({ titulo, children }: { titulo: string; children: ReactNode }) {
  return (
    <fieldset className="flex flex-col gap-3">
      <legend className="mb-3 type-panel-section text-on-surface">{titulo}</legend>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">{children}</div>
    </fieldset>
  )
}

/** Lo opcional, plegado como en la portada: un enlace que lo abre. */
function Opcional({
  abierto,
  onAbrir,
  texto,
  children,
}: {
  abierto: boolean
  onAbrir: () => void
  texto: string
  children: ReactNode
}) {
  if (abierto) return <>{children}</>
  return (
    <button
      type="button"
      onClick={onAbrir}
      className="inline-flex items-center gap-1 justify-self-start type-panel-caption font-medium text-primary underline-offset-4 hover:underline sm:col-span-2"
    >
      <ChevronDown size={14} aria-hidden /> {texto}
    </button>
  )
}
