import { diaOperativo, formatDay, formatNumero } from '@/components/ui'
import { comoFila, filaONula, numero, numeroONulo, textoONulo } from '@/lib/json'
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
//   intencion  un gesto de querer pagar (entró a pagar, promete, abrió el aviso)
//   evita      un gesto de no querer, o de no enterarse (no abre, no contesta)
//   aviso      algo que quien cobra tiene que saber antes de escribir (pago
//              en revisión, cuenta congelada, baja de nivel cerca)
//   historia   un dato de cómo ha pagado antes, que no empuja la intención
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
  /** El último arranque o vuelta a la app que se conoce. */
  ultimaApertura: string | null
  avisos: 'activos' | 'apagados' | 'nunca' | null
  /** Por qué se apagaron: `DeviceNotRegistered` (desinstaló) o `Sesión cerrada`. */
  avisosMotivo: string | null
  /** Desde cuándo la app anota sus gestos. Sin esto no se puede decir que NO hizo algo. */
  gestosDesde: string | null
  entroAPagar: string | null
  copioDatos: string | null
  abrioAviso: string | null
  /** Su cuota vencida más vieja (sin lo dado por perdido). */
  vencidaDesde: string | null
  avisosEntregados: number
  avisosAbiertos: number
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
  ultimaApertura: null,
  avisos: null,
  avisosMotivo: null,
  gestosDesde: null,
  entroAPagar: null,
  copioDatos: null,
  abrioAviso: null,
  vencidaDesde: null,
  avisosEntregados: 0,
  avisosAbiertos: 0,
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
    ultimaApertura: textoONulo(r.ultima_apertura),
    avisos: unoDe(['activos', 'apagados', 'nunca'] as const, r.avisos) ?? null,
    avisosMotivo: textoONulo(r.avisos_motivo),
    gestosDesde: textoONulo(r.gestos_desde),
    entroAPagar: textoONulo(r.entro_a_pagar),
    copioDatos: textoONulo(r.copio_datos),
    abrioAviso: textoONulo(r.abrio_aviso),
    vencidaDesde: textoONulo(r.vencida_desde),
    avisosEntregados: numero(r.avisos_entregados),
    avisosAbiertos: numero(r.avisos_abiertos),
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
  | 'entro_a_pagar'
  | 'copio_datos'
  | 'promete'
  | 'promesa_rota'
  | 'abrio_aviso'
  | 'avisos_sin_abrir'
  | 'avisos_entregados'
  | 'sin_avisos'
  | 'abrio_app'
  | 'no_abre'
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
  /** Días de atraso con que el estado automático baja de nivel. */
  diasBaja: number
}

/** Cuántos días atrás un gesto sigue contando como reciente. */
const RECIENTE_DIAS = 7

function reciente(instante: string | null, ctx: ContextoDeSenales): instante is string {
  return instante !== null && diasEntre(diaOperativo(new Date(instante)), ctx.hoy) <= RECIENTE_DIAS
}

function despuesDe(a: string | null, b: string | null): boolean {
  return a !== null && (b === null || new Date(a) > new Date(b))
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

  // ── Pagos reportados ─────────────────────────────────────────────────────
  if (h.enRevisionDesde) {
    s.push({
      clave: 'en_revision',
      tono: 'aviso',
      texto: `Pago en revisión ${haceCuanto(h.enRevisionDesde, ctx.ahora)}`,
      ayuda: 'Reportó un pago que todavía no se ha aprobado. Revísalo en Pagos reportados antes de escribirle.',
      peso: 3,
    })
  } else if (h.ultimoReporte?.estado === 'rejected') {
    const nota = h.ultimoReporte.nota ? ` Motivo: «${h.ultimoReporte.nota}».` : ''
    s.push({
      clave: 'rechazado',
      tono: 'evita',
      texto: `Pago rechazado ${haceCuanto(h.ultimoReporte.revisadoEn ?? h.ultimoReporte.en, ctx.ahora)}`,
      ayuda: `Su último pago reportado se rechazó y no ha reportado otro. Puede que no sepa por qué.${nota}`,
      peso: -1,
    })
  }

  // ── Gestos en la app (desde la OTA que los anota) ─────────────────────────
  // Solo cuenta lo que hizo después de su último pago reportado: antes, ya pagó.
  const ultimoPago = h.ultimoReporte?.en ?? null
  if (!h.enRevisionDesde && reciente(h.entroAPagar, ctx) && despuesDe(h.entroAPagar, ultimoPago)) {
    s.push({
      clave: 'entro_a_pagar',
      tono: 'intencion',
      texto: `Entró a pagar ${haceCuanto(h.entroAPagar, ctx.ahora)}, no reportó`,
      ayuda: 'Abrió la pantalla de reportar pago y no llegó a reportar ninguno. Puede que le falte saldo o que no sepa cómo.',
      peso: 2,
    })
    if (reciente(h.copioDatos, ctx) && despuesDe(h.copioDatos, ultimoPago)) {
      s.push({
        clave: 'copio_datos',
        tono: 'intencion',
        texto: 'Copió los datos del pago',
        ayuda: `Copió la cuenta destino o el monto ${haceCuanto(h.copioDatos, ctx.ahora)}: fue a su banco.`,
        peso: 1,
      })
    }
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

  // ── Los avisos ─────────────────────────────────────────────────────────────
  if (h.avisos === 'apagados' || h.avisos === 'nunca') {
    const porque =
      h.avisos === 'nunca'
        ? 'Nunca dio permiso de avisos en su teléfono.'
        : h.avisosMotivo === 'DeviceNotRegistered'
          ? 'Su teléfono dejó de aceptar avisos: desinstaló la app o borró sus datos.'
          : h.avisosMotivo === 'Sesión cerrada'
            ? 'Cerró sesión en la app y no ha vuelto a entrar.'
            : 'Ningún teléfono suyo acepta avisos.'
    s.push({
      clave: 'sin_avisos',
      tono: 'evita',
      texto: 'No recibe avisos',
      ayuda: `${porque} Los recordatorios no le llegan: hay que escribirle por WhatsApp.`,
      peso: -1,
    })
  } else if (debeVencido && reciente(h.abrioAviso, ctx) && h.avisosAbiertos > 0) {
    s.push({
      clave: 'abrio_aviso',
      tono: 'intencion',
      texto: `Abrió el aviso ${haceCuanto(h.abrioAviso, ctx.ahora)}`,
      ayuda: `Tocó ${plural(h.avisosAbiertos, 'aviso de cuota', 'avisos de cuota')} desde que venció: sabe que debe.`,
      peso: 1,
    })
  } else if (debeVencido && h.avisosEntregados > 0) {
    // Solo se puede decir que NO los abrió si la app ya anotaba los toques
    // cuando le llegaron.
    const medido =
      h.gestosDesde !== null && h.vencidaDesde !== null && diaOperativo(new Date(h.gestosDesde)) <= h.vencidaDesde
    s.push(
      medido && h.avisosEntregados >= 2
        ? {
            clave: 'avisos_sin_abrir',
            tono: 'evita',
            texto: `${plural(h.avisosEntregados, 'aviso', 'avisos')} sin abrir`,
            ayuda: 'Los recordatorios de cuota le llegaron al teléfono desde que venció, y no tocó ninguno.',
            peso: -1,
          }
        : {
            clave: 'avisos_entregados',
            tono: 'historia',
            texto: `Le llegaron ${plural(h.avisosEntregados, 'aviso', 'avisos')}`,
            ayuda: 'Recordatorios de cuota entregados en su teléfono desde que venció. No se sabe si los abrió.',
            peso: 0,
          },
    )
  }

  // ── La app ───────────────────────────────────────────────────────────────
  if (h.ultimaApertura) {
    const dia = diaOperativo(new Date(h.ultimaApertura))
    const desdeQueVencio = h.vencidaDesde !== null && dia < h.vencidaDesde
    if (debeVencido && desdeQueVencio) {
      s.push({
        clave: 'no_abre',
        tono: 'evita',
        texto: 'No abre la app desde que venció',
        ayuda: `La última vez que abrió la app fue el ${formatDay(dia)}, antes de su vencimiento del ${formatDay(h.vencidaDesde)}.`,
        peso: -1,
      })
    } else if (diasEntre(dia, ctx.hoy) > RECIENTE_DIAS) {
      s.push({
        clave: 'no_abre',
        tono: debeVencido ? 'evita' : 'historia',
        texto: `Sin abrir la app desde ${haceCuanto(h.ultimaApertura, ctx.ahora)}`,
        ayuda: `La última vez que abrió la app fue el ${formatDay(dia)}.`,
        peso: debeVencido ? -1 : 0,
      })
    } else {
      s.push({
        clave: 'abrio_app',
        tono: debeVencido ? 'intencion' : 'historia',
        texto: `Abrió la app ${haceCuanto(h.ultimaApertura, ctx.ahora)}`,
        ayuda: 'La última vez que arrancó o volvió a la app.',
        peso: debeVencido ? 1 : 0,
      })
    }
  }

  // ── Gestiones sin respuesta ────────────────────────────────────────────────
  if (debeVencido && h.gestionesSinRespuesta && h.gestionesSinRespuesta > 0) {
    s.push({
      clave: 'sin_respuesta',
      tono: 'evita',
      texto: `${plural(h.gestionesSinRespuesta, 'gestión', 'gestiones')} sin respuesta`,
      ayuda: 'Gestiones desde que venció sin promesa ni pago reportado en las horas siguientes.',
      peso: h.gestionesSinRespuesta >= 2 ? -2 : -1,
    })
  }

  // ── La cuenta ─────────────────────────────────────────────────────────────
  if (fila.status === 'frozen') {
    s.push({
      clave: 'congelada',
      tono: 'aviso',
      texto: 'Cuenta congelada',
      ayuda: 'El estado automático le congeló la cuenta por el atraso: no puede financiarse hasta que pague.',
      peso: 0,
    })
  }
  const faltanParaBaja = ctx.diasBaja - fila.daysOverdue
  if (debeVencido && ctx.diasBaja > 0 && faltanParaBaja > 0 && faltanParaBaja <= 7) {
    s.push({
      clave: 'baja_pronto',
      tono: 'aviso',
      texto: faltanParaBaja === 1 ? 'Baja de nivel mañana' : `Baja de nivel en ${faltanParaBaja} días`,
      ayuda: `Si no paga, el estado automático le baja de nivel al cumplir ${ctx.diasBaja} días de atraso.`,
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
  'La suma de sus señales: las verdes (entró a pagar, promete, abrió el aviso o la app) suman; las rojas (no abre, no contesta, promesa rota, sin avisos, nunca pagó) restan. Un pago en revisión cuenta como que quiere pagar.'

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

export type GrupoDeCola = 'primero' | 'despues' | 'recordar' | 'vigilar'

export const GRUPOS_DE_COLA: readonly GrupoDeCola[] = ['primero', 'despues', 'recordar', 'vigilar']

export const ROTULO_GRUPO: Record<GrupoDeCola, string> = {
  primero: 'Llamar primero',
  despues: 'Después',
  recordar: 'Recordar: vence hoy o mañana',
  vigilar: 'Vigilar',
}

export const QUE_ES_EL_GRUPO: Record<GrupoDeCola, string> = {
  primero: 'Deben algo vencido y su perfil tiene prioridad alta: nunca han pagado, rompieron una promesa o no contestan.',
  despues: 'Deben algo vencido con prioridad media o baja: suelen pagar, aunque tarde, o se les pasó por pocos días.',
  recordar: 'No deben nada vencido y les vence una cuota hoy o mañana: un recordatorio a tiempo evita el atraso.',
  vigilar: 'No deben nada vencido y lo próximo les vence más adelante.',
}

/**
 * Las dos formas de ver la cola: una sola lista de más días de atraso a menos
 * (la de por defecto, Javier 28-09) o los cuatro grupos por prioridad.
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
export function grupoDe(
  fila: { overdueUsd: number; prioridad: 'alta' | 'media' | 'baja' | null; nextDueDate: string },
  hoy: string,
): GrupoDeCola {
  if (fila.overdueUsd > 0) return fila.prioridad === 'alta' ? 'primero' : 'despues'
  return diasEntre(hoy, fila.nextDueDate) <= 1 ? 'recordar' : 'vigilar'
}
