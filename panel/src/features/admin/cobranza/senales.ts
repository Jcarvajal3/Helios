import { diaOperativo, formatDay, formatNumero } from '@/components/ui'
import { comoFila, filaONula, numeroONulo, textoONulo } from '@/lib/json'
import { unoDe } from '@/lib/busqueda'
import type { EstadoPromesa } from '@/features/admin/estados'

// ═══════════════════════════════════════════════════════════════════════════
// Las señales de un deudor: qué hizo antes de que alguien le escriba.
//
// La base manda HECHOS con fecha (`metricas.senales_deudor` más la historia
// de `metricas.perfil_deudor`, en `senales` de cada fila de la cola y de la
// lista de una semana). Aquí se convierten en señales que se leen de un
// vistazo, cada una con su tono, y en una lectura de intención que solo las
// resume: nunca añade nada que no esté en una señal.
//
// Los tonos:
//   intencion  un gesto de querer pagar (promete, tiene un pago registrado)
//   evita      un gesto de no querer, o de no enterarse (no contesta)
//   aviso      algo que quien cobra tiene que saber antes de escribir (pago
//              en revisión, cuenta congelada, suspensión cerca)
//   historia   un dato de cómo ha pagado antes, que no empuja la intención
//
// Sin app no hay gestos que leer (abrir la app, entrar a pagar, tocar un
// aviso): los avisos salen solos por WhatsApp y correo, y lo que se sabe de un
// paciente es lo que pagó, lo que prometió y si contestó.
//
// Puro: se prueba en `senales.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

export type ReporteDePago = {
  estado: 'reported' | 'in_review' | 'reconciled' | 'rejected'
  en: string
  revisadoEn: string | null
  nota: string | null
}

/** Lo que manda la base en `senales`. Un `null` es «no se sabe», no «no». */
export type HechosDeDeudor = {
  ultimoReporte: ReporteDePago | null
  enRevisionDesde: string | null
  cuotasPagadas: number | null
  pagadasATiempo: number | null
  pagadasTarde: number | null
  atrasoMedioAlPagar: number | null
  promesasRotas: number | null
  ultimaPromesaRota: string | null
  gestionesSinRespuesta: number | null
}

export const SIN_HECHOS: HechosDeDeudor = {
  ultimoReporte: null,
  enRevisionDesde: null,
  cuotasPagadas: null,
  pagadasATiempo: null,
  pagadasTarde: null,
  atrasoMedioAlPagar: null,
  promesasRotas: null,
  ultimaPromesaRota: null,
  gestionesSinRespuesta: null,
}

const ESTADOS_DE_REPORTE = ['reported', 'in_review', 'reconciled', 'rejected'] as const

export function leerHechos(raw: unknown): HechosDeDeudor {
  if (raw === null || raw === undefined) return SIN_HECHOS
  const r = comoFila(raw)
  const rep = filaONula(r.ultimo_reporte)
  const estadoRep = rep ? unoDe(ESTADOS_DE_REPORTE, rep.estado) : undefined
  return {
    ultimoReporte:
      rep && estadoRep
        ? {
            estado: estadoRep,
            en: textoONulo(rep.en) ?? '',
            revisadoEn: textoONulo(rep.revisado_en),
            nota: textoONulo(rep.nota),
          }
        : null,
    enRevisionDesde: textoONulo(r.en_revision_desde),
    cuotasPagadas: numeroONulo(r.cuotas_pagadas),
    pagadasATiempo: numeroONulo(r.pagadas_a_tiempo),
    pagadasTarde: numeroONulo(r.pagadas_tarde),
    atrasoMedioAlPagar: numeroONulo(r.atraso_medio_al_pagar),
    promesasRotas: numeroONulo(r.promesas_rotas),
    ultimaPromesaRota: textoONulo(r.ultima_promesa_rota),
    gestionesSinRespuesta: numeroONulo(r.gestiones_sin_respuesta),
  }
}

// ── Cuánto hace ────────────────────────────────────────────────────────────

const MINUTO = 60_000
const HORA = 60 * MINUTO

/**
 * «hace 20 min», «hace 3 h», «ayer», «hace 5 días», por días operativos: lo
 * de ayer a las 2 de la madrugada es de la misma noche que hoy a las 9.
 */
export function haceCuanto(instante: string, ahora: Date): string {
  const t = new Date(instante)
  const ms = ahora.getTime() - t.getTime()
  if (ms < HORA) return `hace ${Math.max(1, Math.round(ms / MINUTO))} min`
  const dias = diasEntre(diaOperativo(t), diaOperativo(ahora))
  if (dias <= 0) return `hace ${Math.round(ms / HORA)} h`
  if (dias === 1) return 'ayer'
  return `hace ${dias} días`
}

/** Días de calendario entre dos días 'YYYY-MM-DD' (b − a). */
export function diasEntre(a: string, b: string): number {
  return Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86_400_000)
}

// ── Las señales ───────────────────────────────────────────────────────────

export type TonoDeSenal = 'intencion' | 'evita' | 'aviso' | 'historia'

export type ClaveDeSenal =
  | 'en_revision'
  | 'rechazado'
  | 'promete'
  | 'promesa_rota'
  | 'sin_respuesta'
  | 'nunca_pago'
  | 'siempre_a_tiempo'
  | 'suele_tarde'
  | 'congelada'
  | 'baja_pronto'

export type Senal = {
  clave: ClaveDeSenal
  tono: TonoDeSenal
  texto: string
  /** Qué quiere decir, con la fecha exacta: el globo de la señal. */
  ayuda: string
  /** Cuánto empuja la intención: + quiere pagar, − lo evita. 0 no cuenta. */
  peso: number
}

/** Lo que la señal necesita de la fila de la cola, además de los hechos. */
export type FilaParaSenales = {
  overdueUsd: number
  daysOverdue: number
  status: string
  promiseDate: string | null
  promiseStatus: EstadoPromesa | null
  senales: HechosDeDeudor
}

export type ContextoDeSenales = {
  ahora: Date
  /** Día operativo de hoy. */
  hoy: string
  /** Días de atraso con que el estado automático suspende la cuenta (y baja un nivel). */
  diasBaja: number
}

function plural(n: number, uno: string, varios: string): string {
  return `${formatNumero(n, 0)} ${n === 1 ? uno : varios}`
}

/**
 * Las señales de una persona, en el orden en que se leen: primero lo que
 * quien cobra tiene que saber antes de escribir, después los gestos de más
 * peso y al final la historia.
 */
export function senalesDe(fila: FilaParaSenales, ctx: ContextoDeSenales): Senal[] {
  const h = fila.senales
  const debeVencido = fila.overdueUsd > 0
  const s: Senal[] = []

  // ── Pagos registrados ────────────────────────────────────────────────────
  if (h.enRevisionDesde) {
    s.push({
      clave: 'en_revision',
      tono: 'aviso',
      texto: `Pago por aprobar ${haceCuanto(h.enRevisionDesde, ctx.ahora)}`,
      ayuda: 'Tiene un pago registrado que todavía no se ha aprobado. Revísalo en Pagos reportados antes de escribirle.',
      peso: 3,
    })
  } else if (h.ultimoReporte?.estado === 'rejected') {
    const nota = h.ultimoReporte.nota ? ` Motivo: «${h.ultimoReporte.nota}».` : ''
    s.push({
      clave: 'rechazado',
      tono: 'evita',
      texto: `Pago rechazado ${haceCuanto(h.ultimoReporte.revisadoEn ?? h.ultimoReporte.en, ctx.ahora)}`,
      ayuda: `Su último pago registrado se rechazó y no ha mandado otro comprobante. Puede que no sepa por qué.${nota}`,
      peso: -1,
    })
  }

  // ── Promesas ──────────────────────────────────────────────────────────────
  if (fila.promiseDate && (fila.promiseStatus === 'vence_hoy' || fila.promiseStatus === 'pendiente')) {
    s.push({
      clave: 'promete',
      tono: 'intencion',
      texto: fila.promiseStatus === 'vence_hoy' ? 'Promete pagar hoy' : `Promete pagar el ${formatDay(fila.promiseDate)}`,
      ayuda: 'En la última gestión con promesa dijo que pagaría ese día, y todavía no ha llegado el pago.',
      peso: 2,
    })
  } else if (debeVencido && h.ultimaPromesaRota) {
    s.push({
      clave: 'promesa_rota',
      tono: 'evita',
      texto: `Promesa incumplida del ${formatDay(h.ultimaPromesaRota)}`,
      ayuda: `Prometió pagar ese día y no llegó ningún pago.${
        h.promesasRotas && h.promesasRotas > 1 ? ` Lleva ${plural(h.promesasRotas, 'promesa rota', 'promesas rotas')}.` : ''
      }`,
      peso: -2,
    })
  }

  // ── Gestiones sin respuesta ────────────────────────────────────────────────
  if (debeVencido && h.gestionesSinRespuesta && h.gestionesSinRespuesta > 0) {
    s.push({
      clave: 'sin_respuesta',
      tono: 'evita',
      texto: `${plural(h.gestionesSinRespuesta, 'gestión', 'gestiones')} sin respuesta`,
      ayuda: 'Gestiones desde que venció sin promesa ni pago registrado en las horas siguientes.',
      peso: h.gestionesSinRespuesta >= 2 ? -2 : -1,
    })
  }

  // ── La cuenta ─────────────────────────────────────────────────────────────
  if (fila.status === 'frozen') {
    s.push({
      clave: 'congelada',
      tono: 'aviso',
      texto: 'Cuenta congelada',
      ayuda: 'El estado automático le congeló la cuenta por el atraso: no puede pagar otra consulta en cuotas hasta que pague.',
      peso: 0,
    })
  }
  const faltanParaBaja = ctx.diasBaja - fila.daysOverdue
  if (debeVencido && ctx.diasBaja > 0 && faltanParaBaja > 0 && faltanParaBaja <= 7) {
    s.push({
      clave: 'baja_pronto',
      tono: 'aviso',
      texto: faltanParaBaja === 1 ? 'Se suspende mañana' : `Se suspende en ${faltanParaBaja} días`,
      ayuda: `Si no paga, el estado automático le suspende la cuenta (y le baja un nivel, si tiene más de uno) al cumplir ${ctx.diasBaja} días de atraso.`,
      peso: 0,
    })
  }

  // ── Historia ──────────────────────────────────────────────────────────────
  if (h.cuotasPagadas === 0) {
    s.push({
      clave: 'nunca_pago',
      tono: 'evita',
      texto: 'Nunca ha pagado una cuota',
      ayuda: 'No tiene ninguna cuota pagada desde que usa Helios.',
      peso: -1,
    })
  } else if (h.cuotasPagadas !== null && h.cuotasPagadas > 0 && h.pagadasTarde === 0) {
    s.push({
      clave: 'siempre_a_tiempo',
      tono: 'historia',
      texto: 'Siempre pagó a tiempo',
      ayuda: `${h.cuotasPagadas === 1 ? 'Su cuota pagada llegó' : `Sus ${formatNumero(h.cuotasPagadas, 0)} cuotas pagadas llegaron`} dentro de plazo.`,
      peso: 0,
    })
  } else if (h.atrasoMedioAlPagar !== null && h.atrasoMedioAlPagar >= 1) {
    const dias = Math.round(h.atrasoMedioAlPagar)
    s.push({
      clave: 'suele_tarde',
      tono: 'historia',
      texto: `Suele pagar ${dias} ${dias === 1 ? 'día' : 'días'} tarde`,
      ayuda: `Atraso medio de sus cuotas pagadas${
        h.pagadasTarde ? `; ${plural(h.pagadasTarde, 'llegó tarde', 'llegaron tarde')}` : ''
      }.`,
      peso: 0,
    })
  }

  return s
}

// ── La intención ──────────────────────────────────────────────────────────

export type Intencion = 'quiere' | 'dudosa' | 'evita'

export const ROTULO_INTENCION: Record<Intencion, string> = {
  quiere: 'Quiere pagar',
  dudosa: 'No está claro',
  evita: 'Lo está evitando',
}

export const QUE_ES_LA_INTENCION =
  'La suma de sus señales: las verdes (registró un pago, promete, contesta) suman; las rojas (no contesta, promesa rota, nunca pagó) restan. Un pago registrado sin aprobar cuenta como que quiere pagar.'

/**
 * Lo que dicen sus señales, juntas: la suma de sus pesos. Con un pago en
 * revisión, quiere pagar (ya pagó). Sin ninguna señal que pese, no está claro.
 */
export function intencionDe(senales: ReadonlyArray<Senal>): Intencion {
  const suma = senales.reduce((a, s) => a + s.peso, 0)
  if (suma >= 1) return 'quiere'
  if (suma <= -1) return 'evita'
  return 'dudosa'
}

// ── Los grupos de la cola ──────────────────────────────────────────────────

export type GrupoDeCola = 'primero' | 'despues' | 'vigilar'

export const GRUPOS_DE_COLA: readonly GrupoDeCola[] = ['primero', 'despues', 'vigilar']

export const ROTULO_GRUPO: Record<GrupoDeCola, string> = {
  primero: 'Llamar primero',
  despues: 'Después',
  vigilar: 'Al día',
}

export const QUE_ES_EL_GRUPO: Record<GrupoDeCola, string> = {
  primero: 'Deben algo vencido y su perfil tiene prioridad alta: nunca han pagado, rompieron una promesa o no contestan.',
  despues: 'Deben algo vencido con prioridad media o baja: suelen pagar, aunque tarde, o se les pasó por pocos días.',
  vigilar:
    'No deben nada vencido. Los recordatorios de antes del vencimiento (3 días antes, la víspera y el mismo día) les salen solos por WhatsApp y correo.',
}

/**
 * Las dos formas de ver la cola: una sola lista de más días de atraso a menos
 * (la de por defecto, Javier 28-09) o los tres grupos por prioridad.
 */
export const ORDENES_DE_COLA = ['atraso', 'prioridad'] as const
export type OrdenDeCola = (typeof ORDENES_DE_COLA)[number]

export const ROTULO_ORDEN: Record<OrdenDeCola, string> = {
  atraso: 'Por días de atraso',
  prioridad: 'Por prioridad',
}

/**
 * De más días de atraso a menos; a igual atraso, quien más debe vencido.
 * Detrás, quien no debe nada vencido, por lo que le vence antes.
 */
export function ordenarPorAtraso<
  T extends { daysOverdue: number; overdueUsd: number; upcomingUsd: number; nextDueDate: string },
>(filas: ReadonlyArray<T>): T[] {
  return [...filas].sort((a, b) => {
    const va = a.overdueUsd > 0
    const vb = b.overdueUsd > 0
    if (va !== vb) return va ? -1 : 1
    if (va) return b.daysOverdue - a.daysOverdue || b.overdueUsd - a.overdueUsd
    return a.nextDueDate.localeCompare(b.nextDueDate) || b.upcomingUsd - a.upcomingUsd
  })
}

/**
 * El grupo de una fila. Excluyentes y exhaustivos: cada persona de la cola
 * está en uno solo.
 */
export function grupoDe(fila: { overdueUsd: number; prioridad: 'alta' | 'media' | 'baja' | null }): GrupoDeCola {
  if (fila.overdueUsd > 0) return fila.prioridad === 'alta' ? 'primero' : 'despues'
  return 'vigilar'
}
