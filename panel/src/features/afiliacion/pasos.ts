import { sumarDias } from '@/components/kit/rango'
import { BANKS } from '@/features/admin/banks'
import {
  CAPACITACION_HASTA_DIAS,
  digitosDeCuenta,
  pareceCorreo,
  telefonoAE164,
} from '@/features/admin/clinicas/clinicas'
import type {
  AltaDeClinica,
  Capacitacion,
} from '@/features/admin/clinicas/clinicas'
import {
  LETRAS_CEDULA,
  LETRAS_TITULAR,
  documentoParaEnviar,
  documentoValido,
  partirDocumento,
} from '@/lib/documento'
import type { LetraDocumento } from '@/lib/documento'

// ═══════════════════════════════════════════════════════════════════════════
// La solicitud de afiliación de la portada (`/afiliacion`), en tres pasos
// cortos: tú, tu consultorio y dónde te pagamos.
//
// Pide lo mismo que el alta del equipo y manda lo mismo (`datosDeAlta`,
// `helios_solicitar_afiliacion`); aquí solo cambia cómo se pide:
//
//   - Cada paso dice qué campo falta, al lado del campo, en vez de un solo
//     motivo para todo el formulario (`motivoDeAlta` sigue siendo el freno
//     final antes de enviar).
//   - El banco sale de los 4 primeros dígitos de la cuenta: no se elige.
//   - El médico escribe «Cédula o RIF» en un solo campo y la letra decide:
//     con V, E o P es su cédula (`owner_document`); con J o G es el RIF del
//     consultorio (`tax_id`) y entonces se le pide aparte su cédula, que la
//     base exige. Sin J o G, el RIF va vacío (es opcional).
//   - Si la cuenta está a nombre del médico, el titular y su cédula son los
//     del paso 1: no se vuelven a escribir.
//
// Módulo puro, probado en `pasos.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

export const PASOS = [
  {
    titulo: 'Tus datos',
    corto: 'Tú',
    nota: 'Quién eres y qué especialidad atiendes.',
  },
  {
    titulo: 'Tu consultorio',
    corto: 'Consultorio',
    nota: 'Dónde atiendes y cómo te contactamos.',
  },
  {
    titulo: 'Dónde te pagamos',
    corto: 'Tu banco',
    nota: 'La cuenta a la que te transferimos tus consultas.',
  },
] as const

export type Paso = 0 | 1 | 2

/**
 * Lo que se puede marcar con un error: los campos del alta, el de «Cédula o
 * RIF» y la capacitación.
 */
export type CampoDeAfiliacion =
  keyof AltaDeClinica | 'documento' | 'capacitacionDia' | 'capacitacionHora'

export type Errores = Partial<Record<CampoDeAfiliacion, string>>

/** El banco de una cuenta venezolana: sus 4 primeros dígitos. `''` si no se sabe. */
export function bancoDeCuenta(cuenta: string): string {
  const d = digitosDeCuenta(cuenta)
  if (d.length < 4) return ''
  return BANKS.find((b) => d.startsWith(b.code))?.name ?? ''
}

/** Lo que lleva el formulario mientras se llena. */
export type Borrador = {
  alta: AltaDeClinica
  /**
   * «Cédula o RIF», la letra pegada al número (`V12345678`, `J123456789`).
   * Con J o G, la cédula del médico va aparte, en `alta.ownerDocument`.
   */
  documento: string
  /** Si la cuenta está a nombre del médico. */
  cuentaPropia: boolean
  capacitacion: Capacitacion
}

/** Las letras de «Cédula o RIF»: las de una persona y las de una empresa. */
export const LETRAS_CEDULA_O_RIF = LETRAS_TITULAR

/** Si «Cédula o RIF» es el RIF de una empresa (J o G): entonces falta la cédula. */
export function esRifDeEmpresa(documento: string): boolean {
  const { letra } = partirDocumento(documento, LETRAS_CEDULA_O_RIF)
  return letra === 'J' || letra === 'G'
}

/**
 * El alta tal como se manda: la cédula y el RIF sacados de «Cédula o RIF»,
 * el banco sacado de la cuenta y, si la cuenta es del médico, su nombre y su
 * cédula como titular.
 */
export function altaParaEnviar(b: Borrador): AltaDeClinica {
  const a = b.alta
  const empresa = esRifDeEmpresa(b.documento)
  const documento = documentoParaEnviar(b.documento, LETRAS_CEDULA_O_RIF)
  const cedula = empresa ? a.ownerDocument : documento
  return {
    ...a,
    ownerDocument: cedula,
    taxId: empresa ? documento : '',
    bank: bancoDeCuenta(a.accountNumber),
    ...(b.cuentaPropia
      ? { accountHolder: a.ownerName, holderDocument: cedula }
      : {}),
  }
}

function errorDeDocumento(
  valor: string,
  letras: ReadonlyArray<LetraDocumento>,
  falta: string,
): string | null {
  if (documentoValido(valor, letras)) return null
  const { letra, numero } = partirDocumento(valor, letras)
  if (numero === '') return falta
  if (letra === 'P') return 'El pasaporte lleva de 5 a 15 letras y números.'
  if (letra === 'J' || letra === 'G') return 'El RIF lleva 8 o 9 números.'
  return 'La cédula lleva de 6 a 9 números.'
}

/**
 * Lo que falta o está mal en un paso, campo por campo. Vacío si se puede
 * seguir. Los mismos frenos que `motivoDeAlta` y `motivoDeCapacitacion`,
 * dichos al lado de cada campo.
 */
export function erroresDelPaso(paso: Paso, b: Borrador, hoy: string): Errores {
  const e: Errores = {}
  const a = altaParaEnviar(b)

  if (paso === 0) {
    if (a.ownerName.trim().length < 3) {
      e.ownerName = 'Escribe tu nombre y apellido.'
    }
    if (!a.doctorTitle) e.doctorTitle = 'Elige cómo quieres que te nombren.'
    const documento = errorDeDocumento(
      b.documento,
      LETRAS_CEDULA_O_RIF,
      'Escribe el número de tu cédula o RIF.',
    )
    if (documento) e.documento = documento
    // Con el RIF de una empresa, la cédula del médico va aparte.
    if (esRifDeEmpresa(b.documento)) {
      const cedula = errorDeDocumento(
        a.ownerDocument,
        LETRAS_CEDULA,
        'Escribe el número de tu cédula o pasaporte.',
      )
      if (cedula) e.ownerDocument = cedula
    }
    if (!a.specialty.trim()) e.specialty = 'Escribe o elige tu especialidad.'
  }

  if (paso === 1) {
    if (a.clinicName.trim().length < 2) {
      e.clinicName = 'Escribe el nombre de tu consultorio o centro.'
    }
    if (a.address.trim().length < 5) {
      e.address = 'Escribe la dirección del consultorio.'
    }
    if (!telefonoAE164(a.phone)) {
      e.phone = a.phone.trim()
        ? 'Revisa el número: 0414 1234567 o 0212 5551234.'
        : 'Escribe un teléfono de contacto.'
    }
    if (!pareceCorreo(a.email)) {
      e.email = a.email.trim()
        ? 'Revisa el correo: algo como nombre@correo.com.'
        : 'Escribe tu correo electrónico.'
    }
    const usuario = a.socialUser.trim()
    if (usuario && !a.socialNetwork) e.socialNetwork = 'Elige qué red es.'
    if (a.socialNetwork && !usuario) {
      e.socialUser = 'Escribe tu usuario o el enlace.'
    }
    if (usuario.length > 150) e.socialUser = 'Es demasiado largo.'
  }

  if (paso === 2) {
    if (!b.cuentaPropia) {
      if (a.accountHolder.trim().length < 3) {
        e.accountHolder = 'Escribe el nombre del titular.'
      }
      const documento = errorDeDocumento(
        a.holderDocument,
        LETRAS_TITULAR,
        'Escribe la cédula o el RIF del titular.',
      )
      if (documento) e.holderDocument = documento
    }

    const cuenta = digitosDeCuenta(a.accountNumber)
    if (cuenta === '') e.accountNumber = 'Escribe el número de cuenta.'
    else if (cuenta.length >= 4 && !a.bank) {
      e.accountNumber =
        'No reconocemos el banco de esta cuenta: revisa los 4 primeros dígitos.'
    } else if (cuenta.length !== 20) {
      const faltan = 20 - cuenta.length
      e.accountNumber = `Te ${faltan === 1 ? 'falta 1 dígito' : `faltan ${faltan} dígitos`}: la cuenta tiene 20.`
    }

    const { dia, hora } = b.capacitacion
    if (dia || hora) {
      if (!dia) e.capacitacionDia = 'Elige el día.'
      else if (dia <= hoy)
        e.capacitacionDia = 'Elige un día a partir de mañana.'
      else if (dia > sumarDias(hoy, CAPACITACION_HASTA_DIAS)) {
        e.capacitacionDia = `Elige un día dentro de los próximos ${CAPACITACION_HASTA_DIAS} días.`
      }
      if (!hora) e.capacitacionHora = 'Elige la hora.'
    }
  }

  return e
}

/** Los campos que se ven en cada paso, en orden: al fallar, el foco va al primero con error. */
export const CAMPOS_DEL_PASO: Record<Paso, ReadonlyArray<CampoDeAfiliacion>> = {
  0: [
    'ownerName',
    'doctorTitle',
    'documento',
    'ownerDocument',
    'specialty',
    'collegeNumber',
    'mppsNumber',
  ],
  1: ['clinicName', 'address', 'phone', 'email', 'socialNetwork', 'socialUser'],
  2: [
    'accountHolder',
    'holderDocument',
    'accountNumber',
    'capacitacionDia',
    'capacitacionHora',
  ],
}

/** El primer campo del paso con error, o `null`. */
export function primerError(
  paso: Paso,
  errores: Errores,
): CampoDeAfiliacion | null {
  return CAMPOS_DEL_PASO[paso].find((c) => errores[c]) ?? null
}
