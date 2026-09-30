import { formatUsd } from '@/components/ui'
import { delta, textoDeDesglose } from '@/features/admin/metricas/formato'
import type { Delta } from '@/features/admin/metricas/formato'
import { etiquetaDeSemana, tramoDeDias, tramoHastaElCorte } from '@/features/admin/metricas/semana/etiquetas'
import type { CifrasDelTramo, RespuestaResumen, SemanaDeLaChispa } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// Las cinco cifras de Semana › Resumen, con las palabras de Javier:
//
//   Total facturado (sin fee) + Service fee + IVA = Total a cobrar
//
// (los nombres del vocabulario del super admin, AUDITORIA §2: «Total
// facturado (sin fee)» es el mismo número y el mismo nombre que la fila
// «Total facturado» de Semana › Rendimiento, y «Usuarios que consumieron»,
// el de su fila de usuarios).
//   Consumos · Usuarios que consumieron
//
// Las tres primeras son un desglose que suma, no tres cifras sueltas: el
// total a cobrar lleva el fee dentro y por eso solo se enseña al lado de sus
// dos sumandos (la regla del fee). Cada una va frente a la semana anterior
// (hasta el mismo momento si la elegida está en curso) y con su chispa de
// las ocho últimas semanas.
//
// Aquí no hay aritmética nueva: los valores son los de la base. Solo se
// eligen las palabras y los pies.
//
// Puro: se prueba en `cifras.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

export type IdCifraResumen = 'facturado' | 'fee' | 'total' | 'consumos' | 'usuarios'

/** Los tres sumandos del desglose, en su orden: facturado + fee = total. */
export const CIFRAS_DEL_DESGLOSE = ['facturado', 'fee', 'total'] as const satisfies ReadonlyArray<IdCifraResumen>

/** Las dos que cuentan: consumos y gente. */
export const CIFRAS_QUE_CUENTAN = ['consumos', 'usuarios'] as const satisfies ReadonlyArray<IdCifraResumen>

/**
 * El título de cada tarjeta. Lo que es consumo dice si lleva el fee, y el fee
 * se llama por su nombre: «service fee», nunca «servicio».
 */
export const TITULOS_DEL_RESUMEN: Record<IdCifraResumen, string> = {
  facturado: 'Total financiado (sin fee)',
  fee: 'Service fee + IVA',
  // El desglose está a su izquierda, con sus signos: «+» y «=».
  total: 'Total a cobrar',
  consumos: 'Financiamientos',
  usuarios: 'Pacientes que se financiaron',
}

/** Qué es cada cifra, en el `InfoDot` de su título. */
export const AYUDAS_DEL_RESUMEN: Record<IdCifraResumen, string> = {
  facturado:
    'Sin el service fee: lo que se financió en las clínicas en la semana (la en curso, hasta ahora), por día operativo. Solo financiamientos confirmados y sin los de prueba.',
  fee: 'El service fee de esos financiamientos, con su IVA dentro: el total a cobrar menos el total financiado. El pie lo parte en el service fee sin IVA (el ingreso de Helios) y el IVA, que no es de Helios.',
  total:
    'Lo que la gente paga en sus dos cuotas por los financiamientos de la semana: el total financiado (sin fee) más el service fee y su IVA. Siempre con sus dos partes a la vista.',
  consumos: 'Financiamientos confirmados de la semana, sin los de prueba. Un financiamiento de grupo es uno solo, pague cuanta gente pague.',
  usuarios:
    'Los pacientes distintos con cuota en los financiamientos de la semana: en un grupo, cada paciente que paga su parte, no solo quien abrió la cuenta. Quien vino dos días o a dos clínicas cuenta una vez. El pie: cuántos consumían por primera vez en algún clínica (o en el elegido).',
}

export type ChispaDeCifra = {
  valores: number[]
  etiquetas: string[]
  rotulo: string
  formato: (n: number) => string
  /** El nombre de la cifra junto al valor en el globo: el título de la tarjeta. */
  serie: string
}

export type CifraDelResumen = {
  id: IdCifraResumen
  titulo: string
  /** Ya escrita. */
  valor: string
  delta: Delta | null
  /**
   * Una línea: lo que completa la cifra. El total a cobrar no lleva: sus dos
   * sumandos son las tarjetas de al lado (en el móvil, las de encima).
   */
  pie: string | undefined
  info: string
  chispa: ChispaDeCifra
}

/** Un recuento, con el punto de miles de aquí. */
export function escribirNumero(n: number): string {
  return n.toLocaleString('es-VE')
}

/** «14–20 sep»: la semana de una barra de la chispa. */
function etiquetaDe(s: SemanaDeLaChispa): string {
  return etiquetaDeSemana(s.desde, s.hasta)
}

/**
 * La semana de una barra del total a cobrar, con sus dos partes: en el
 * globo, lo que se cobra nunca sale sin decir de qué está hecho.
 */
export function etiquetaConDesglose(s: SemanaDeLaChispa): string {
  return `${etiquetaDe(s)} (${textoDeDesglose(s).replace('Financiamiento', 'financiamiento')})`
}

/** «7 noches · 3 locales»: en cuántas noches y locales se repartió lo facturado. */
export function repartoDeLaSemana(r: RespuestaResumen): string {
  const noches = new Set(r.noches.map((n) => n.dia)).size
  const locales = new Set(r.noches.map((n) => n.merchantId)).size
  if (noches === 0) return 'Ningún financiamiento todavía'
  const enNoches = `${noches} ${noches === 1 ? 'día' : 'días'}`
  // Con un local elegido, todas las filas son de él: los locales sobran.
  return r.local ? enNoches : `${enNoches} · ${locales} ${locales === 1 ? 'clínica' : 'clínicas'}`
}

/** «€225,80 sin IVA + €36,12 de IVA»: de qué está hecho el fee. */
export function partesDelFee(c: Pick<CifrasDelTramo, 'servicioUsd' | 'ivaUsd'>): string {
  return `${formatUsd(c.servicioUsd)} sin IVA + ${formatUsd(c.ivaUsd)} de IVA`
}

/**
 * «30 nuevos en algún local»: los usuarios que consumieron por primera vez
 * en algún local (en el elegido, con local), contados una vez. No es
 * «nuevos en Ronda» (la fila «Usuarios nuevos» de Rendimiento): quien ya
 * había ido a otro local cuenta aquí si estrenó uno.
 */
export function nuevosEnElLocal(nuevas: number, conLocal: boolean): string {
  const donde = conLocal ? 'en la clínica' : 'en algún clínica'
  if (nuevas === 0) return conLocal ? 'Ningún paciente nuevo en la clínica' : 'Ningún paciente nuevo en ninguna clínica'
  return `${escribirNumero(nuevas)} ${nuevas === 1 ? 'nuevo' : 'nuevos'} ${donde}`
}

/** «Ticket medio €26,26 (sin fee)». */
export function pieDeConsumos(c: Pick<CifrasDelTramo, 'ticketMedioUsd'>): string {
  return c.ticketMedioUsd === null ? 'Sin financiamientos, sin ticket medio' : `Ticket medio ${formatUsd(c.ticketMedioUsd)} (sin fee)`
}

/**
 * Con qué se compara, en una línea encima de las cifras: la semana en curso
 * con la anterior HASTA EL MISMO MOMENTO (hace exactamente siete días: con
 * días enteros, a media tarde la anterior llevaba una noche entera de más);
 * una cerrada, con la anterior entera.
 */
export function lineaDeLaComparacion(r: Pick<RespuestaResumen, 'semana' | 'dias' | 'anterior'>): string {
  if (r.semana.enCurso) {
    const antes = tramoHastaElCorte(r.anterior.desde, r.anterior.hasta, r.anterior.corte)
    if (r.anterior.corte) {
      return `Semana en curso: cada cifra se compara con la anterior hasta el mismo momento, ${antes}.`
    }
    const llevaDias = r.dias === 1 ? '1 día de 7' : `${r.dias} días de 7`
    return `Semana en curso (${llevaDias}): cada cifra se compara con los mismos días de la anterior, ${antes}.`
  }
  return `Cada cifra se compara con la semana anterior entera, ${tramoDeDias(r.anterior.desde, r.anterior.hasta)}.`
}

/** Las cinco cifras: primero las tres del desglose y luego las dos que cuentan. */
export function cifrasDelResumen(r: RespuestaResumen): CifraDelResumen[] {
  const c = r.cifras
  const antes = r.comparacion
  const etiquetas = r.semanas.map(etiquetaDe)

  function cifra(
    id: IdCifraResumen,
    valorDe: (t: CifrasDelTramo) => number,
    formato: (n: number) => string,
    pie: string | undefined,
    etiquetasDeLaChispa: string[] = etiquetas,
  ): CifraDelResumen {
    const titulo = TITULOS_DEL_RESUMEN[id]
    return {
      id,
      titulo,
      valor: formato(valorDe(c)),
      // Más es mejor en las cinco: más consumo, más gente. Ninguna es un riesgo.
      delta: delta(valorDe(c), valorDe(antes), { tipo: 'relativo', arribaEsBueno: true }),
      pie,
      info: AYUDAS_DEL_RESUMEN[id],
      chispa: {
        valores: r.semanas.map(valorDe),
        etiquetas: etiquetasDeLaChispa,
        rotulo: `${titulo}, de las últimas ${r.semanas.length} semanas`,
        formato,
        serie: titulo,
      },
    }
  }

  return [
    cifra('facturado', (t) => t.financedUsd, formatUsd, repartoDeLaSemana(r)),
    cifra('fee', (t) => t.feeUsd, formatUsd, partesDelFee(c)),
    cifra('total', (t) => t.payableUsd, formatUsd, undefined, r.semanas.map(etiquetaConDesglose)),
    cifra('consumos', (t) => t.consumos, escribirNumero, pieDeConsumos(c)),
    cifra('usuarios', (t) => t.personas, escribirNumero, nuevosEnElLocal(c.nuevas, r.local !== null)),
  ]
}
