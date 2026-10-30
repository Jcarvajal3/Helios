import {
  COMISION_PCT,
  CONSULTA,
  IVA_PCT,
  LIMITE,
  PREGUNTA_COSTO,
  cuota,
  desglose,
  dinero,
  dineroCorto,
} from './datos'
import type { RutaPublica } from '@/config/sitio'

/**
 * LAS PÁGINAS PARA BUSCADORES — `/pacientes`, `/medicos` y una por
 * especialidad. Todo su texto vive aquí; las pinta `Guia.tsx`.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * La portada habla de la marca; estas páginas responden a lo que la gente
 * escribe en Google sin conocer Helios: «pagar consulta médica en cuotas»,
 * «odontólogo en cuotas», «cobrar consultas en cuotas»… Por eso cada una
 * tiene su título, su H1 y sus preguntas propias, y no repite la portada.
 *
 * Las mismas reglas que `datos.ts`: solo se afirma lo que el sistema ya hace
 * (límite inicial de $150, sin decir que crece; sin mencionar cargos por
 * mora), y nunca «préstamo», «financiamiento», «crédito» ni «fee». Si cambia
 * una cifra del negocio, cambia aquí también y se actualiza la fecha de la
 * página en `PAGINAS_PUBLICAS` (`config/sitio.ts`).
 */

export type Pregunta = { pregunta: string; respuesta: string }
type Bloque = { titulo: string; texto: string }
export type Dato = { termino: string; valor: string }

export type Guia = {
  ruta: RutaPublica
  /** El `<title>`: lo que se busca delante, la marca detrás. Hasta ~60 caracteres. */
  titulo: string
  /** La meta descripción: hasta ~155 caracteres. */
  descripcion: string
  /** El nombre corto de la página en la miga de pan y en los enlaces. */
  nombre: string
  publico: 'paciente' | 'medico'
  rotulo: string
  h1: { antes: string; enfasis: string }
  entrada: string
  /**
   * La respuesta corta, justo debajo de la cabecera: las cifras que se
   * buscan, sueltas, para quien lee en diagonal y para los buscadores con
   * IA, que extraen lo que va arriba.
   */
  resumen: Dato[]
  pasos: { titulo: { antes: string; enfasis: string }; lista: Bloque[] }
  ventajas: { titulo: { antes: string; enfasis: string }; lista: Bloque[] }
  /** Un aparte para el otro público: el médico de esa especialidad. */
  aparte?: { titulo: string; texto: string }
  preguntas: Pregunta[]
  relacionadas: RutaPublica[]
  servicio: { nombre: string; categoria?: string }
}

const CUOTA = dinero(cuota)

// ── Lo que se repite entre páginas ─────────────────────────────────────────

const PASOS_PACIENTE: Bloque[] = [
  {
    titulo: 'Pide pagar en cuotas en la consulta',
    texto:
      'Tu médico o su secretaria registran la consulta en Helios con tu cédula, tu correo y tu teléfono. No descargas nada ni creas una cuenta.',
  },
  {
    titulo: 'Confirma por WhatsApp',
    texto:
      'Te llega un mensaje con el monto, la Comisión Helios y tus dos cuotas con su fecha. Respondes «Sí» y el comprobante te llega por correo.',
  },
  {
    titulo: 'Paga a los 7 y a los 14 días',
    texto:
      'En bolívares, por Pago Móvil o transferencia, a la tasa oficial del BCV del día en que pagas. Te recordamos cada fecha por WhatsApp.',
  },
]

/** El resumen de las páginas del paciente. */
const RESUMEN_PACIENTE: Dato[] = [
  { termino: 'Cuotas', valor: '2, a los 7 y a los 14 días' },
  { termino: 'Inicial', valor: '$0: hoy no pagas nada' },
  {
    termino: 'Comisión Helios',
    valor: `${COMISION_PCT}% de la consulta + ${IVA_PCT}% de IVA sobre la comisión, incluida en las cuotas`,
  },
  {
    termino: 'Ejemplo',
    valor: `Consulta de ${dineroCorto(CONSULTA)} → 2 cuotas de ${CUOTA}`,
  },
  {
    termino: 'Cómo pagas',
    valor: 'En bolívares, por Pago Móvil o transferencia, a la tasa BCV del día',
  },
  { termino: 'Límite inicial', valor: `$${LIMITE} en cuotas a la vez` },
]

/**
 * El resumen de la página del médico. Ningún total con la Comisión Helios
 * (CLAUDE.md): el médico solo ve el precio de su consulta.
 */
const RESUMEN_MEDICO: Dato[] = [
  { termino: 'Recibes', valor: 'El 100% del precio de la consulta' },
  { termino: 'Cuándo', valor: 'La mitad a los 8 días y la otra mitad a los 15' },
  { termino: 'Si el paciente no paga', valor: 'Te pagamos igual' },
  { termino: 'Costo para ti', valor: '$0: sin inscripción ni mensualidad' },
  { termino: 'Cómo registras', valor: 'Plataforma web o WhatsApp, sin punto de venta' },
  { termino: 'Moneda', valor: 'Dólares o euros; te pagamos en bolívares a tasa BCV' },
]

/**
 * La tabla «Cuánto pagas» de las páginas del paciente: lo que se paga por
 * consultas de distintos montos, hasta el límite inicial. Sale de las mismas
 * cifras que la portada (`desglose`): no se desactualiza sola.
 */
export const TABLA_DE_CUOTAS = [50, CONSULTA, LIMITE].map((monto) => ({
  monto,
  ...desglose(monto),
}))

/**
 * El calendario de la página del médico: qué pasa cada día desde la
 * consulta. A los 8 y 15 días, el día siguiente a cada cuota
 * (`helios_settlement_run_for`).
 */
export const CALENDARIO_DE_COBRO: Dato[] = [
  { termino: 'Día 0', valor: 'Registras la consulta y el paciente confirma por WhatsApp. Ese día no paga nada.' },
  { termino: 'Día 7', valor: 'Vence la primera cuota del paciente.' },
  { termino: 'Día 8', valor: 'Recibes la mitad del precio de la consulta.' },
  { termino: 'Día 14', valor: 'Vence la segunda cuota del paciente.' },
  { termino: 'Día 15', valor: 'Recibes la otra mitad: ya cobraste el 100%, pague o no el paciente.' },
]

const PREGUNTA_LIMITE: Pregunta = {
  pregunta: '¿Hasta cuánto puedo pagar en cuotas?',
  respuesta: `Tu límite inicial es de $${LIMITE}: es lo máximo que puedes tener en cuotas a la vez. Lo que usaste vuelve a estar disponible cuando pagas tus dos cuotas.`,
}

const PREGUNTA_COMO_PAGO: Pregunta = {
  pregunta: '¿Cómo pago mis cuotas?',
  respuesta:
    'En bolívares, por Pago Móvil o transferencia. Tus cuotas van en la moneda de tu consulta, dólares o euros, y se pagan a la tasa oficial del BCV del día en que haces el pago. No se aceptan Zelle, USDT ni efectivo.',
}

const PREGUNTA_MI_MEDICO: Pregunta = {
  pregunta: '¿Cómo sé si mi médico acepta Helios?',
  respuesta:
    'Búscalo en el directorio de médicos de Helios o pregunta en el consultorio antes de tu cita. Si todavía no está afiliado, cuéntale de Helios: afiliarse no le cuesta nada y cobra el 100% de la consulta.',
}

const APARTE_MEDICO =
  'Ofrece a tus pacientes pagar en dos cuotas y cobra el 100% de la consulta, la mitad a los 8 días y la otra a los 15, pague o no el paciente. No te cuesta nada.'

// ── Pacientes ──────────────────────────────────────────────────────────────

const PACIENTES: Guia = {
  ruta: '/pacientes',
  titulo: 'Paga tu consulta médica en cuotas, sin inicial | Helios',
  descripcion:
    'Paga tu consulta médica, dental o de cosmetología en 2 cuotas, a los 7 y 14 días, sin inicial. En bolívares, por Pago Móvil o transferencia.',
  nombre: 'Pacientes',
  publico: 'paciente',
  rotulo: 'Para pacientes',
  h1: { antes: 'Paga tu consulta médica', enfasis: 'en dos cuotas.' },
  entrada:
    'Con Helios, la consulta o el tratamiento en un consultorio afiliado se paga en dos cuotas, a los 7 y a los 14 días, sin inicial y sin descargar nada. Atiéndete hoy y paga después.',
  resumen: RESUMEN_PACIENTE,
  pasos: {
    titulo: { antes: 'Pagar en cuotas,', enfasis: 'en tres pasos.' },
    lista: PASOS_PACIENTE,
  },
  ventajas: {
    titulo: {
      antes: 'Lo que tienes que saber',
      enfasis: 'antes de tu consulta.',
    },
    lista: [
      {
        titulo: 'Hoy no pagas nada',
        texto:
          'Sin inicial. Pagas la mitad a los 7 días y la otra mitad a los 14, en fechas que ves antes de confirmar y que no se mueven.',
      },
      {
        titulo: 'Una sola comisión, dicha desde el principio',
        texto: `La Comisión Helios es el ${COMISION_PCT}% de la consulta más su IVA, y ya va incluida en tus cuotas. Sin inscripción ni mensualidad.`,
      },
      {
        titulo: 'En bolívares, por Pago Móvil',
        texto:
          'O por transferencia, a la tasa oficial del BCV del día en que pagas. Te recordamos cada fecha por WhatsApp.',
      },
      {
        titulo: `Límite inicial de $${LIMITE}`,
        texto:
          'Es lo máximo que puedes tener en cuotas a la vez, y se libera cuando pagas tus dos cuotas.',
      },
      {
        titulo: 'Sin app, sin cuenta, sin contraseña',
        texto:
          'Te registran en la consulta con tu cédula. Confirmas por WhatsApp y el comprobante te llega por correo.',
      },
      {
        titulo: 'Tu información es tuya',
        texto:
          'Ningún médico ni centro ve tus cuotas, si estás al día ni dónde te atendiste antes.',
      },
    ],
  },
  preguntas: [
    PREGUNTA_COSTO,
    {
      pregunta: '¿Tengo que pagar una inicial?',
      respuesta:
        'No. El día de la consulta no pagas nada: pagas una cuota a los 7 días y la otra a los 14.',
    },
    {
      pregunta: '¿Tengo que descargar una app o crear una cuenta?',
      respuesta:
        'No. El médico te registra con tu cédula, tu correo y tu teléfono. Confirmas por WhatsApp y el comprobante te llega por correo.',
    },
    PREGUNTA_COMO_PAGO,
    PREGUNTA_LIMITE,
    {
      pregunta: '¿Qué pasa si me retraso con una cuota?',
      respuesta:
        'No puedes registrar otro pago en cuotas hasta ponerte al día. Te recordamos cada fecha por WhatsApp para que no se te pase.',
    },
    {
      pregunta: '¿Quién puede pagar en cuotas?',
      respuesta:
        'Cualquier persona mayor de 18 años con cédula. Si quien se atiende es menor de edad, el pago en cuotas va a nombre de su representante.',
    },
    {
      pregunta: '¿El médico ve lo que debo?',
      respuesta:
        'No. Ningún médico ni centro ve tus cuotas, si estás al día ni dónde te atendiste antes. Solo sabe si puedes pagar esa consulta en cuotas.',
    },
    PREGUNTA_MI_MEDICO,
  ],
  relacionadas: [
    '/consulta-medica-en-cuotas',
    '/odontologia-en-cuotas',
    '/cosmetologia-en-cuotas',
  ],
  servicio: { nombre: 'Pago de consultas de salud en dos cuotas' },
}

// ── Médicos ────────────────────────────────────────────────────────────────

const MEDICOS: Guia = {
  ruta: '/medicos',
  titulo: 'Cobra tus consultas en cuotas, con pago garantizado | Helios',
  descripcion:
    'Ofrece pago en cuotas en tu consultorio y recibe el 100% de cada consulta a los 8 y 15 días, pague o no el paciente. Sin costo ni permanencia.',
  nombre: 'Médicos y centros',
  publico: 'medico',
  rotulo: 'Para médicos y centros de salud',
  h1: { antes: 'Ofrece pago en cuotas', enfasis: 'y cobra el 100%.' },
  entrada:
    'Tus pacientes pagan la consulta en dos cuotas y tú recibes el precio completo, la mitad a los 8 días y la otra mitad a los 15, pague o no el paciente. El cobro corre por cuenta de Helios.',
  resumen: RESUMEN_MEDICO,
  pasos: {
    titulo: { antes: 'Así funciona', enfasis: 'en tu consultorio.' },
    lista: [
      {
        titulo: 'Registras la consulta',
        texto:
          'Desde la plataforma de Helios o por WhatsApp, con la cédula del paciente y el monto en dólares o en euros. Toma un par de minutos y también lo puede hacer tu secretaria.',
      },
      {
        titulo: 'El paciente confirma',
        texto:
          'Le llega un WhatsApp con su monto y sus dos cuotas. Responde «Sí» y recibe el comprobante por correo. Tú lo ves confirmado en la plataforma.',
      },
      {
        titulo: 'Te pagamos a los 8 y a los 15 días',
        texto:
          'La mitad de la consulta a los 8 días y la otra mitad a los 15, por transferencia en bolívares, pague o no el paciente.',
      },
    ],
  },
  ventajas: {
    titulo: {
      antes: 'Más pacientes que se atienden hoy,',
      enfasis: 'sin riesgo para ti.',
    },
    lista: [
      {
        titulo: 'Pago garantizado',
        texto:
          'Recibes el 100% del precio aunque el paciente no pague. El cobro al paciente es responsabilidad de Helios.',
      },
      {
        titulo: 'No te cuesta nada',
        texto:
          'Sin inscripción ni mensualidad. La Comisión Helios la paga el paciente y no se descuenta de tu consulta.',
      },
      {
        titulo: 'Sin equipos ni punto de venta',
        texto:
          'Registras desde el navegador o por WhatsApp. No instalas nada ni compras ningún aparato.',
      },
      {
        titulo: 'En dólares o en euros',
        texto:
          'Eliges la moneda de cada consulta al registrarla. Te pagamos en bolívares, a la tasa oficial del BCV.',
      },
      {
        titulo: 'Para todo tu equipo',
        texto:
          'Da acceso a tu secretaria y a tus sedes, y sigue en un solo lugar lo que registraste y lo que te toca cobrar.',
      },
      {
        titulo: 'Sin permanencia',
        texto:
          'Puedes cancelar tu afiliación cuando quieras, con aviso previo.',
      },
    ],
  },
  preguntas: [
    {
      pregunta: '¿Cuánto me cuesta afiliarme a Helios?',
      respuesta:
        'Nada. No hay inscripción ni mensualidad, y la Comisión Helios la paga el paciente (no se descuenta de tu consulta). Tampoco hay permanencia: puedes cancelar con aviso previo.',
    },
    {
      pregunta: '¿Qué pasa si el paciente no paga?',
      respuesta:
        'Te pagamos igual, a los 8 y a los 15 días. El cobro al paciente es responsabilidad de Helios.',
    },
    {
      pregunta: '¿Cuándo y cómo me pagan?',
      respuesta:
        'Recibes la mitad del precio de la consulta a los 8 días y la otra mitad a los 15, por transferencia en bolívares a la tasa oficial del BCV de la moneda de la consulta. Se paga a diario, no una vez por semana.',
    },
    {
      pregunta: '¿Puedo cobrar la consulta en dólares o en euros?',
      respuesta:
        'Sí. Eliges la moneda al registrar cada consulta. El paciente paga en bolívares a la tasa BCV del día en que paga, y a ti te pagamos en bolívares a la tasa de esa misma moneda.',
    },
    {
      pregunta: '¿Necesito un punto de venta o instalar algo?',
      respuesta:
        'No. Registras la consulta desde la plataforma de Helios en el navegador o por WhatsApp, con la cédula del paciente y el monto.',
    },
    {
      pregunta: '¿Mi secretaria puede registrar las consultas?',
      respuesta:
        'Sí. Puedes dar acceso a tu personal y a tus sedes. Cada quien ve solo lo que le corresponde.',
    },
    {
      pregunta: '¿Veo la deuda o el historial del paciente?',
      respuesta:
        'No. Por privacidad, ningún médico ni centro ve las cuotas de un paciente ni dónde se atendió antes. Solo sabes si puede pagar esa consulta en cuotas.',
    },
    {
      pregunta: '¿Qué especialidades pueden afiliarse?',
      respuesta:
        'Consultorios y centros de salud privada de medicina (general y especialidades), odontología y cosmetología en Venezuela.',
    },
    {
      pregunta: '¿Cómo me afilio?',
      respuesta:
        'Llena la solicitud de afiliación con los datos de tu consultorio o centro. La revisamos y te escribimos para activar tu cuenta.',
    },
  ],
  relacionadas: [
    '/consulta-medica-en-cuotas',
    '/odontologia-en-cuotas',
    '/cosmetologia-en-cuotas',
  ],
  servicio: { nombre: 'Pago en cuotas para consultorios y centros de salud' },
}

// ── Especialidades ─────────────────────────────────────────────────────────

const MEDICINA: Guia = {
  ruta: '/consulta-medica-en-cuotas',
  titulo: 'Consulta médica en cuotas, sin inicial | Helios Venezuela',
  descripcion:
    'Paga tu consulta con el médico general o el especialista en 2 cuotas, a los 7 y 14 días, sin inicial. En bolívares, por Pago Móvil o transferencia.',
  nombre: 'Consulta médica en cuotas',
  publico: 'paciente',
  rotulo: 'Medicina · Pago en cuotas',
  h1: { antes: 'Tu consulta médica,', enfasis: 'en dos cuotas.' },
  entrada:
    'Con tu médico de cabecera o con el especialista: si el consultorio está afiliado a Helios, pagas la consulta en dos cuotas, a los 7 y a los 14 días, sin inicial.',
  resumen: RESUMEN_PACIENTE,
  pasos: {
    titulo: { antes: 'Cómo pagar tu consulta', enfasis: 'en cuotas.' },
    lista: PASOS_PACIENTE,
  },
  ventajas: {
    titulo: { antes: 'Ve al médico hoy,', enfasis: 'no cuando puedas.' },
    lista: [
      {
        titulo: 'No pospongas el chequeo',
        texto:
          'Atiéndete cuando lo necesitas y reparte el pago en dos fechas, a los 7 y a los 14 días.',
      },
      {
        titulo: 'Médico general o especialista',
        texto:
          'Sirve en cualquier consultorio o centro de salud afiliado, sea medicina general o una especialidad.',
      },
      {
        titulo: 'Sabes cuánto pagas antes de confirmar',
        texto:
          'El mensaje de WhatsApp trae el monto, la Comisión Helios y tus dos cuotas con fecha. Si no estás de acuerdo, no confirmas.',
      },
      {
        titulo: 'En bolívares, como siempre pagas',
        texto:
          'Pago Móvil o transferencia, a la tasa oficial del BCV del día en que pagas.',
      },
    ],
  },
  aparte: {
    titulo: '¿Eres médico o tienes un centro de salud?',
    texto: APARTE_MEDICO,
  },
  preguntas: [
    {
      pregunta: '¿Puedo pagar en cuotas una consulta con un especialista?',
      respuesta:
        'Sí, si el especialista o su centro están afiliados a Helios. Sirve para medicina general y para especialidades como pediatría, ginecología, cardiología, dermatología o traumatología.',
    },
    PREGUNTA_COSTO,
    PREGUNTA_COMO_PAGO,
    PREGUNTA_LIMITE,
    {
      pregunta: '¿Puedo pagar en cuotas la consulta de mi hijo?',
      respuesta:
        'Sí. Si quien se atiende es menor de edad, el pago en cuotas va a nombre de su representante, mayor de 18 años y con cédula.',
    },
    PREGUNTA_MI_MEDICO,
  ],
  relacionadas: ['/pacientes', '/odontologia-en-cuotas', '/medicos'],
  servicio: { nombre: 'Consulta médica en cuotas', categoria: 'Medicina' },
}

const ODONTOLOGIA: Guia = {
  ruta: '/odontologia-en-cuotas',
  titulo: 'Odontología en cuotas: paga al dentista sin inicial | Helios',
  descripcion:
    'Paga al odontólogo tu consulta o tratamiento en 2 cuotas, a los 7 y 14 días, sin inicial. En bolívares, por Pago Móvil o transferencia.',
  nombre: 'Odontología en cuotas',
  publico: 'paciente',
  rotulo: 'Odontología · Pago en cuotas',
  h1: { antes: 'Tu consulta con el odontólogo,', enfasis: 'en dos cuotas.' },
  entrada:
    'Una limpieza, un control o ese dolor de muela que no puede esperar. En los consultorios odontológicos afiliados a Helios pagas tu atención en dos cuotas, a los 7 y a los 14 días, sin inicial.',
  resumen: RESUMEN_PACIENTE,
  pasos: {
    titulo: { antes: 'Cómo pagar al dentista', enfasis: 'en cuotas.' },
    lista: PASOS_PACIENTE,
  },
  ventajas: {
    titulo: { antes: 'Cuida tus dientes hoy,', enfasis: 'paga en dos partes.' },
    lista: [
      {
        titulo: 'Sin esperar a fin de mes',
        texto:
          'Atiéndete cuando lo necesitas: hoy no pagas nada y repartes el monto en dos cuotas.',
      },
      {
        titulo: 'Consultas y tratamientos',
        texto:
          'Lo que te haga tu odontólogo afiliado, siempre que el monto quepa en tu límite disponible.',
      },
      {
        titulo: 'Montos claros desde el principio',
        texto:
          'Antes de confirmar ves el precio, la Comisión Helios y tus dos cuotas con su fecha.',
      },
      {
        titulo: 'Pagas por Pago Móvil',
        texto:
          'O por transferencia, en bolívares, a la tasa oficial del BCV del día en que pagas.',
      },
    ],
  },
  aparte: { titulo: '¿Eres odontólogo?', texto: APARTE_MEDICO },
  preguntas: [
    {
      pregunta: '¿Qué tratamientos dentales puedo pagar en cuotas?',
      respuesta: `Los que te haga un odontólogo afiliado a Helios, siempre que el monto quepa en tu límite disponible (el inicial es de $${LIMITE}, lo máximo que puedes tener en cuotas a la vez). Pregunta en el consultorio antes de tu cita.`,
    },
    PREGUNTA_COSTO,
    PREGUNTA_COMO_PAGO,
    {
      pregunta: '¿Puedo pagar en cuotas la consulta dental de mi hijo?',
      respuesta:
        'Sí. Si quien se atiende es menor de edad, el pago en cuotas va a nombre de su representante, mayor de 18 años y con cédula.',
    },
    {
      pregunta: '¿Cómo sé si mi odontólogo acepta Helios?',
      respuesta:
        'Búscalo en el directorio de médicos de Helios o pregúntale en el consultorio. Si todavía no está afiliado, cuéntale de Helios: afiliarse no le cuesta nada y cobra el 100% de la consulta.',
    },
  ],
  relacionadas: ['/pacientes', '/consulta-medica-en-cuotas', '/medicos'],
  servicio: { nombre: 'Odontología en cuotas', categoria: 'Odontología' },
}

const COSMETOLOGIA: Guia = {
  ruta: '/cosmetologia-en-cuotas',
  titulo: 'Tratamientos estéticos en cuotas, sin inicial | Helios',
  descripcion:
    'Paga tu tratamiento de cosmetología o estética en 2 cuotas, a los 7 y 14 días, sin inicial. En bolívares, por Pago Móvil o transferencia.',
  nombre: 'Cosmetología en cuotas',
  publico: 'paciente',
  rotulo: 'Cosmetología · Pago en cuotas',
  h1: { antes: 'Tu tratamiento de cosmetología,', enfasis: 'en dos cuotas.' },
  entrada:
    'Limpiezas faciales, tratamientos para la piel y otros servicios de cosmetología: en los centros afiliados a Helios los pagas en dos cuotas, a los 7 y a los 14 días, sin inicial.',
  resumen: RESUMEN_PACIENTE,
  pasos: {
    titulo: { antes: 'Cómo pagar tu tratamiento', enfasis: 'en cuotas.' },
    lista: PASOS_PACIENTE,
  },
  ventajas: {
    titulo: { antes: 'Date ese cuidado hoy,', enfasis: 'paga en dos partes.' },
    lista: [
      {
        titulo: 'Hoy no pagas nada',
        texto:
          'Sin inicial: una cuota a los 7 días y otra a los 14, con fechas fijas.',
      },
      {
        titulo: 'Sin sorpresas',
        texto:
          'Antes de confirmar ves el precio del tratamiento, la Comisión Helios y tus dos cuotas.',
      },
      {
        titulo: 'Sin app ni cuenta',
        texto:
          'El centro te registra con tu cédula, confirmas por WhatsApp y el comprobante te llega por correo.',
      },
      {
        titulo: 'En bolívares',
        texto:
          'Por Pago Móvil o transferencia, a la tasa oficial del BCV del día en que pagas.',
      },
    ],
  },
  aparte: {
    titulo: '¿Tienes un centro de cosmetología?',
    texto: APARTE_MEDICO,
  },
  preguntas: [
    {
      pregunta: '¿Qué tratamientos de cosmetología puedo pagar en cuotas?',
      respuesta: `Los que ofrezca un centro de cosmetología afiliado a Helios, siempre que el monto quepa en tu límite disponible (el inicial es de $${LIMITE}, lo máximo que puedes tener en cuotas a la vez).`,
    },
    PREGUNTA_COSTO,
    PREGUNTA_COMO_PAGO,
    {
      pregunta: '¿Quién puede pagar en cuotas?',
      respuesta:
        'Cualquier persona mayor de 18 años con cédula. Si quien se atiende es menor de edad, el pago en cuotas va a nombre de su representante.',
    },
    {
      pregunta: '¿Cómo sé si mi centro acepta Helios?',
      respuesta:
        'Búscalo en el directorio de médicos de Helios o pregunta en el centro antes de tu cita. Si todavía no está afiliado, cuéntale de Helios: afiliarse no le cuesta nada y cobra el 100% del tratamiento.',
    },
  ],
  relacionadas: ['/pacientes', '/odontologia-en-cuotas', '/medicos'],
  servicio: { nombre: 'Cosmetología en cuotas', categoria: 'Cosmetología' },
}

export const GUIAS = {
  '/pacientes': PACIENTES,
  '/medicos': MEDICOS,
  '/consulta-medica-en-cuotas': MEDICINA,
  '/odontologia-en-cuotas': ODONTOLOGIA,
  '/cosmetologia-en-cuotas': COSMETOLOGIA,
} as const satisfies Partial<Record<RutaPublica, Guia>>

export type RutaDeGuia = keyof typeof GUIAS

/** Los enlaces del pie y de «También te puede interesar». */
export const NOMBRE_DE_RUTA: Partial<Record<RutaPublica, string>> = {
  '/': 'Inicio',
  '/afiliacion': 'Quiero afiliarme',
  ...Object.fromEntries(Object.values(GUIAS).map((g) => [g.ruta, g.nombre])),
}
