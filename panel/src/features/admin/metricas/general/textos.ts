import { DEFINICIONES } from '@/features/admin/definitions'

// ═══════════════════════════════════════════════════════════════════════════
// El nombre de cada cifra de General y lo que dice su InfoDot, una sola vez.
//
// Lo leen las tarjetas de la pestaña y el catálogo (Ctrl K y el asistente):
// si una frase cambia, cambia en los dos sitios. Las cifras que ya tenían
// nombre y explicación en el panel (la caja, lo que se les debe a los
// locales, la mora, el impago y el punto de empate) toman la de
// `DEFINICIONES`: la misma cifra no se explica de dos maneras.
//
// Ningún texto escribe un plazo ni un monto del negocio (la gracia, la
// escalera): cambian en Ajustes sin tocar esto.
//
// Las palabras del fee: se llama «service fee» (o «fee» donde no cabe),
// nunca «servicio». Todo consumo dice si lleva el fee: el que va sin él lo
// dice en el título o al empezar su InfoDot («Sin el service fee»), y lo que
// se paga en cuotas lleva «(consumo + fee)» y sus dos partes a la vista.
// ═══════════════════════════════════════════════════════════════════════════

export type ClaveCifraGeneral =
  | 'registros'
  | 'solicitaron'
  | 'hanComprado'
  | 'activos'
  | 'repiten'
  | 'consumo'
  | 'consumos'
  | 'ticket'
  | 'personas'
  | 'localesActivos'
  | 'movido'
  | 'porCobrar'
  | 'vencido'
  | 'cobrado'
  | 'servicio'
  | 'cargos'
  | 'perdido'
  | 'caja'
  | 'porPagarLocales'
  | 'mora'
  | 'impago'
  | 'cuotaATiempo'
  | 'porCadaCien'
  | 'curva'

export const CIFRAS_GENERAL: Record<ClaveCifraGeneral, { titulo: string; que: string }> = {
  registros: {
    titulo: 'Registros',
    que: 'Los pacientes con la verificación de identidad aprobada, desde el primer día. Quien pidió el código y no se verificó no es un registro: cuenta en «Solicitaron el código».',
  },
  solicitaron: {
    titulo: 'Solicitaron el código',
    que: 'Los pacientes que han pedido el código por SMS desde el primer día, se verificaran o no. Las que tienen la identidad verificada son los registros.',
  },
  hanComprado: {
    titulo: 'Registros que se han financiado',
    que: 'Qué parte de los registros se ha financiado al menos una vez, en un financiamiento propio o pagando su parte en uno de grupo.',
  },
  activos: {
    titulo: 'Pacientes activos (30 días)',
    que: 'Los pacientes con cuota en algún financiamiento de los últimos treinta días operativos, hoy incluido; con una clínica elegida, en esa clínica. El pie: qué parte son de todos los pacientes.',
  },
  repiten: {
    titulo: 'Pacientes que repiten',
    que: 'Los pacientes con financiamientos en dos días distintas o más, desde el primer día; con una clínica elegida, dos días en esa clínica.',
  },
  consumo: {
    titulo: 'Total financiado (sin fee)',
    que: 'Sin el service fee ni su IVA: todo lo financiado en las clínicas desde el primer día.',
  },
  consumos: {
    titulo: 'Financiamientos',
    que: 'Los financiamientos confirmados desde el primer día; uno de grupo cuenta una vez.',
  },
  ticket: {
    titulo: 'Ticket medio (sin fee)',
    que: 'Sin el service fee: el total financiado dividido entre el número de financiamientos, desde el primer día.',
  },
  personas: {
    titulo: 'Pacientes que se financiaron',
    que: 'Los pacientes distintos con cuota en algún financiamiento desde el primer día: en uno de grupo cuenta cada paciente que pagó su parte, no solo quien abrió la cuenta.',
  },
  localesActivos: {
    titulo: 'Clínicas activas (30 días)',
    que: 'Las clínicas con algún financiamiento en los últimos treinta días operativos, hoy incluido. El pie: cuántos han financiado alguna vez.',
  },
  movido: {
    titulo: 'Total movido (financiado + fee)',
    que: 'Todo lo que ha pasado por Helios desde el primer día: el importe de todas las cuotas de todos los financiamientos, cobradas o no, el financiado (sin fee) más el service fee + IVA, con las dos partes por separado. Es lo cobrado + lo por cobrar + lo perdido. No cuenta los cargos por atraso.',
  },
  porCobrar: {
    titulo: 'Por cobrar (financiado + fee)',
    que: 'Hoy: el importe de las cuotas vencidas o por vencer que siguen sin pagarse, el financiado (sin fee) más el service fee + IVA, con las dos partes por separado. No cuenta lo perdido ni los cargos por atraso.',
  },
  vencido: {
    titulo: 'De ello, vencido',
    que: 'Hoy: la parte de lo que está por cobrar con el vencimiento ya pasado, financiado (sin fee) más service fee + IVA, con las dos partes por separado.',
  },
  cobrado: {
    titulo: 'Cobrado (financiado + fee)',
    que: 'El importe de todas las cuotas pagadas desde el primer día: el financiado (sin fee) más el service fee + IVA, con las dos partes por separado. Los cargos por atraso cobrados van en su cifra.',
  },
  servicio: {
    titulo: 'Service fee sin IVA',
    que: 'Lo que Helios ha ganado con el service fee de todos los financiamientos confirmados desde el primer día, sin el IVA, que se cobra y se remite. Nunca se suma al financiado.',
  },
  cargos: {
    titulo: 'Cargos por atraso',
    que: 'Los cargos por atraso cargados desde el primer día, sin los condonados. Son ingreso de Helios sin IVA y van aparte del service fee. El pie: lo cobrado de ellos.',
  },
  perdido: {
    titulo: 'Perdido (sin fee)',
    que: 'Sin el service fee: el financiado de las cuotas que se dieron por perdidas desde el primer día y siguen sin pagarse, lo que Helios ya le pagó a la clínica y no va a volver. Su service fee tampoco se cobrará.',
  },
  caja: {
    titulo: DEFINICIONES.caja.label,
    que: DEFINICIONES.caja.what,
  },
  porPagarLocales: {
    titulo: DEFINICIONES.porPagarLocales.label,
    que: DEFINICIONES.porPagarLocales.what,
  },
  mora: {
    titulo: 'Mora hoy',
    que: DEFINICIONES.mora.what,
  },
  impago: {
    titulo: 'Impago',
    que: `${DEFINICIONES.impago.what} Se lee frente al punto de empate: ${DEFINICIONES.puntoDeEmpate.what.charAt(0).toLowerCase()}${DEFINICIONES.puntoDeEmpate.what.slice(1)}`,
  },
  cuotaATiempo: {
    // La tarjeta dice el número: «Cuota 1 a tiempo», «Cuota 2 a tiempo».
    titulo: 'Cuota a tiempo',
    que: 'De las cuotas de ese número cuyo plazo ya cerró, el vencimiento más los días de gracia, qué parte se pagó dentro de él, desde el primer día. Lo dado por perdido cuenta como no pagado a tiempo.',
  },
  porCadaCien: {
    titulo: 'Por cada $100 facturados',
    que: 'Lo que dejan el service fee (sin IVA) y los cargos por atraso por cada cien dólares facturados (sin fee) desde el primer día, y el margen que queda después del impago (%) del bloque Riesgo. Los cien dólares son el denominador, no una línea: el fee nunca se suma al financiado.',
  },
  curva: {
    titulo: 'Registros y financiado acumulados',
    que: 'Los registros y el total financiado (sin fee) acumulados semana a semana desde el primer día, de lunes a domingo por día operativo. Un registro cuenta la semana en que se aprobó su verificación de identidad. La última semana llega hasta hoy.',
  },
}
