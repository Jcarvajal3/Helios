import { METAS, medirMeta } from '@/components/admin/resumen/medirMetas'
import type { DefinicionDeMeta, Meta } from '@/components/admin/resumen/medirMetas'
import type { BadgeTone } from '@/components/ui'
import type { Parametros } from '@/features/admin/parametros'
import type { Progreso } from '@/features/admin/semana'
import { FILAS } from './filas'
import type { DestinoDeFila } from './filas'
import type { CifrasDePeriodo } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// Las metas del negocio (`meta_*` de `business_parameters`) frente a la
// semana elegida: cada una con su cifra, cuánto lleva y un veredicto.
//
// Las definiciones de las metas (qué parámetro, en qué sentido se cumplen,
// cómo se escribe el número) son las del Resumen (`resumen/medirMetas.ts`);
// la cifra que se mide es la misma de la tabla. Las metas son de todo Helios:
// con un local elegido no se miden (la pestaña enseña `NoSeParte`).
//
// Puro: se prueba en `metas.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** En el orden en que se leen. */
const ORDEN: ReadonlyArray<Meta> = ['financiado', 'mora', 'cobroATiempo', 'personas', 'locales']

/**
 * El nombre de cada meta en el bloque: el de la fila que mide, el mismo
 * número con el mismo nombre (AUDITORIA §1). El rótulo del parámetro en la
 * base («Meta de financiado por semana», «Meta de personas activas por
 * semana») es el de Ajustes y usa palabras viejas.
 */
const ROTULO_DE_META: Record<Meta, string> = {
  financiado: 'Total financiado (sin fee)',
  mora: 'Mora al cierre',
  cobroATiempo: 'Cobrado a tiempo',
  personas: 'Pacientes que se financiaron',
  locales: 'Clínicas con financiamientos',
}

/** Qué fila de la tabla mide cada meta. */
const FILA_DE_META: Record<Meta, string> = {
  financiado: 'consumo',
  mora: 'mora',
  cobroATiempo: 'a-tiempo',
  personas: 'personas',
  locales: 'locales',
}

export type VeredictoDeMeta = { tono: BadgeTone; texto: string }

export type MetaDeLaSemana = {
  clave: Meta
  def: DefinicionDeMeta
  /** El nombre de la fila que mide: «Total facturado (sin fee)». */
  rotulo: string
  valor: number | null
  /** `null`: la meta existe pero nadie le ha puesto valor. */
  meta: number | null
  progreso: Progreso | null
  veredicto: VeredictoDeMeta
  destino: DestinoDeFila
}

/**
 * Verde si se cumple; ámbar si no, salvo una meta de las que se alcanzan
 * (consumo, personas, locales) en una semana que todavía no ha terminado: el
 * jueves nadie ha llegado todavía y no es una mala noticia.
 */
export function veredictoDeMeta(
  def: DefinicionDeMeta,
  meta: number | null,
  progreso: Progreso | null,
  enCurso: boolean,
): VeredictoDeMeta {
  if (meta === null) return { tono: 'neutral', texto: 'Sin meta' }
  if (!progreso) return { tono: 'neutral', texto: 'Sin dato' }
  if (progreso.cumplida) {
    return { tono: 'success', texto: def.sentido === 'bajar' ? 'Por debajo de la meta' : 'Cumplida' }
  }
  if (def.sentido === 'bajar') return { tono: 'warning', texto: `${def.formato(progreso.distancia)} por encima` }
  return { tono: enCurso ? 'neutral' : 'warning', texto: `Faltan ${def.formato(progreso.distancia)}` }
}


/** Las cinco metas frente a las cifras de la semana elegida. */
export function metasDeLaSemana(
  cifras: CifrasDePeriodo,
  enCurso: boolean,
  parametros: Parametros | undefined,
): MetaDeLaSemana[] {

  return ORDEN.flatMap((clave) => {
    const def: DefinicionDeMeta = METAS[clave]
    const fila = FILAS.find((f) => f.id === FILA_DE_META[clave])
    if (!fila) return []
    const valor = fila.valor(cifras)
    const { meta, progreso } = medirMeta(def, valor, parametros)
    return [
      {
        clave,
        def,
        rotulo: ROTULO_DE_META[clave],
        valor,
        meta,
        progreso,
        veredicto: veredictoDeMeta(def, meta, progreso, enCurso),
        destino: fila.destino,
      },
    ]
  })
}
