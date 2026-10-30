/**
 * LO QUE DICE LA PORTADA — cifras y textos, en un solo sitio.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Las cifras salen de las reglas vigentes (docs/00 §1 y §1.1, CLAUDE.md). Si
 * una cambia, esta página miente y hay que venir a arreglarla:
 *
 *   · 0 al registrar, 2 cuotas a +7 y +14 días
 *   · Comisión Helios 12% + IVA 16% sobre la comisión, la paga el paciente
 *   · Límite inicial $150 (no decir que «crece»: no hay reglas para subirlo)
 *   · La consulta va en dólares o en euros; el paciente paga en bolívares a la
 *     tasa BCV del día en que paga, por Pago Móvil o transferencia
 *   · Sin cargos por mora desde el 2026-10-07 (`late_fee_usd` = 0): no se
 *     menciona el cargo. Si vuelve, va en «Si te retrasas».
 *   · La clínica cobra el 100%, en dos mitades, a los 8 y 15 días, pague o no
 *     el paciente
 *
 * Lo que NO se dice aquí: «préstamo», «financiamiento», «crédito» ni «fee»
 * (se dice «pago en cuotas» y «Comisión Helios»), cómo se verifica o no
 * al paciente, quién firma los contratos ni nada interno del equipo.
 */

export const CONSULTA = 100
export const COMISION_PCT = 12
export const IVA_PCT = 16
export const LIMITE = 150

export type Moneda = 'USD' | 'EUR'

const SIMBOLO: Record<Moneda, string> = { USD: '$', EUR: '€' }

/** Al céntimo, al estilo venezolano: 113.92 → «$113,92». */
export function dinero(n: number, moneda: Moneda = 'USD'): string {
  const [entero = '0', centimos = '00'] = (Math.round(n * 100) / 100)
    .toFixed(2)
    .split('.')
  return `${SIMBOLO[moneda]}${entero.replace(/\B(?=(\d{3})+(?!\d))/g, '.')},${centimos}`
}

/** Sin céntimos cuando son cero: «$100», «$56,96». */
export function dineroCorto(n: number, moneda: Moneda = 'USD'): string {
  return dinero(n, moneda).replace(/,00$/, '')
}

export const comision = Math.round(CONSULTA * COMISION_PCT) / 100
export const iva = Math.round(comision * IVA_PCT) / 100
export const total = CONSULTA + comision + iva
export const cuota = Math.round((total / 2) * 100) / 100

export const ESPECIALIDADES = [
  'Medicina',
  'Odontología',
  'Cosmetología',
] as const

/**
 * El menú, el mismo en la portada y en las páginas para buscadores. Médicos
 * y pacientes llevan a su página (son enlaces que Google sigue); los demás,
 * a su sección de la portada. El directorio (`/directorio`) es una página
 * para buscar médico: lleva `noindex`, pero desde el 2026-10-30 se llega a
 * ella desde aquí.
 */
export const MENU = [
  { href: '/#como-funciona', texto: 'Cómo funciona' },
  { href: '/medicos', texto: 'Médicos y centros' },
  { href: '/pacientes', texto: 'Pacientes' },
  { href: '/directorio', texto: 'Directorio' },
  { href: '/#preguntas', texto: 'Preguntas' },
] as const

export const PASOS = [
  {
    n: '01',
    titulo: 'El médico registra la consulta',
    texto:
      'Desde la plataforma de Helios o por WhatsApp, con la cédula del paciente y el monto. Toma un par de minutos.',
  },
  {
    n: '02',
    titulo: 'El paciente confirma',
    texto:
      'Le llega un WhatsApp con el monto, la Comisión Helios y sus dos cuotas con fecha. Responde «Sí» y el comprobante le llega por correo.',
  },
  {
    n: '03',
    titulo: 'Paga en dos cuotas',
    texto:
      'A los 7 y a los 14 días, por Pago Móvil o transferencia. Le recordamos cada fecha por WhatsApp.',
  },
] as const

export const PARA_MEDICOS = [
  {
    titulo: 'Cobras a los 8 y a los 15 días',
    texto:
      'Recibes el precio de la consulta en dos partes: la mitad a los 8 días y la otra mitad a los 15.',
  },
  {
    titulo: 'No te cuesta nada',
    texto:
      'La Comisión Helios la paga el paciente. Tú recibes el 100% del precio, sin descuentos.',
  },
  {
    titulo: 'Registro simple',
    texto:
      'Registras la consulta desde la plataforma de Helios o por WhatsApp. Sin equipos ni puntos de venta.',
  },
  {
    titulo: 'Sin permanencia',
    texto: 'Puedes cancelar tu afiliación cuando quieras, con aviso previo.',
  },
] as const

export const PARA_PACIENTES = [
  {
    titulo: 'Dos cuotas, a los 7 y a los 14 días',
    texto:
      'Sin inicial. Las fechas van en el mensaje que confirmas y en tu comprobante, y no se mueven.',
  },
  {
    titulo: `Comisión Helios del ${COMISION_PCT}%`,
    texto: `Es el ${COMISION_PCT}% del monto de la consulta, más el IVA de esa comisión, y va incluida en tus cuotas. Sin inscripción ni mensualidad.`,
  },
  {
    titulo: `Límite inicial de $${LIMITE}`,
    texto:
      'Es lo máximo que puedes tener en cuotas a la vez. Lo que usaste vuelve a estar disponible cuando pagas las dos cuotas.',
  },
  {
    titulo: 'Pagas en bolívares',
    texto:
      'Tus cuotas van en la moneda de tu consulta, dólares o euros. Pagas en bolívares a la tasa oficial del BCV del día en que pagas, por Pago Móvil o transferencia.',
  },
  {
    titulo: 'Si te retrasas',
    texto: 'No puedes registrar otro pago en cuotas hasta ponerte al día.',
  },
  {
    titulo: 'Mayor de 18, con cédula',
    texto:
      'Si quien se atiende es menor de edad, el pago en cuotas va a nombre de su representante.',
  },
] as const

export const PREGUNTAS = [
  {
    pregunta: '¿Dónde puedo usarlo?',
    respuesta:
      'En los consultorios y centros de salud afiliados a Helios, de medicina, odontología y cosmetología. Pregunta antes de tu consulta.',
  },
  {
    pregunta: '¿Tengo que descargar algo o crear una cuenta?',
    respuesta:
      'No. El médico te registra con tu cédula, tu correo y tu teléfono. Confirmas por WhatsApp y el comprobante te llega por correo.',
  },
  {
    pregunta: '¿Cuánto pago en bolívares?',
    respuesta:
      'Tus cuotas van en dólares o en euros, según la moneda de tu consulta. Pagas en bolívares a la tasa oficial del BCV del día en que haces el pago.',
  },
  {
    pregunta: '¿El médico ve lo que debo?',
    respuesta:
      'No. Ningún médico ni centro ve tus cuotas, si estás al día ni dónde te atendiste antes. Solo sabe si puedes pagar esa consulta en cuotas.',
  },
  {
    pregunta: 'Soy médico: ¿qué pasa si el paciente no paga?',
    respuesta:
      'Te pagamos igual, a los 8 y a los 15 días. El cobro al paciente es responsabilidad de Helios.',
  },
  {
    pregunta: 'Soy médico: ¿cuánto me cuesta afiliarme?',
    respuesta:
      'Nada. No hay inscripción ni mensualidad, y la Comisión Helios la paga el paciente. Tampoco hay permanencia: puedes cancelar con aviso previo.',
  },
] as const
