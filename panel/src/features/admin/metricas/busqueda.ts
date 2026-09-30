import { domingoDe, lunesDe } from '@/features/admin/semana'
import { comoDia, comoId, unoDe } from '@/lib/busqueda'
import { IDS_PESTANA, PESTANA_POR_DEFECTO, idsDeSubpestanas, subPorDefecto } from './pestanas'
import type { IdPestana, IdSubpestana, Lugar } from './pestanas'
import { validarCaja } from './caja/busqueda'
import type { BusquedaCaja } from './caja/busqueda'
import { validarCobranza, validarImpago } from './cobranza/busqueda'
import type { BusquedaCobranza, BusquedaImpago } from './cobranza/busqueda'
import { validarCohortes } from './cohortes/busqueda'
import type { BusquedaCohortes } from './cohortes/busqueda'
import { validarGeneral } from './general/busqueda'
import type { BusquedaGeneral } from './general/busqueda'
import { validarGente } from './gente/busqueda'
import type { BusquedaGente } from './gente/busqueda'
import { validarLocales } from './locales/busqueda'
import type { BusquedaLocales } from './locales/busqueda'
import { validarSemana } from './semana/busqueda'
import type { BusquedaSemana } from './semana/busqueda'

// ═══════════════════════════════════════════════════════════════════════════
// La URL de Métricas:
//
//   /admin/metricas?vista=<pestaña>&sub=<sub-pestaña>&semana=…&local=…
//                   + las claves propias de la pestaña activa
//
// El marco valida lo suyo —`vista`, `sub`, `semana` y `local`— y le pasa la
// URL cruda al validador de la pestaña activa, que se queda solo con sus
// claves. Así dos pestañas pueden usar la misma palabra (`cuota`, `dim`) con
// valores distintos, y lo de una pestaña no se arrastra a otra.
//
// La forma canónica no escribe lo que vale por defecto: ni la pestaña Semana,
// ni la primera sub-pestaña, ni la semana en curso. Un enlace viejo
// (`vista=cohortes`, `vista=cobranza&sub=cupos`…) se traduce a su sitio nuevo
// en `traducirEnlaceViejo`, y el router reescribe la URL en su forma nueva.
//
// Puro, sin React ni Supabase: se prueba en `busqueda.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Las claves de Cobros: las de Cohortes (Semanas) y las de Impago por cuota.
 * Las dos llaman `cuota` a la cuota que se mira, con los mismos valores
 * ('1' | '2'), así que la cuota elegida se queda al cambiar de sub-pestaña.
 */
export type BusquedaCobros = BusquedaCohortes & BusquedaImpago

export function validarCobros(raw: Record<string, unknown>): BusquedaCobros {
  return { ...validarCohortes(raw), ...validarImpago(raw) }
}

/**
 * Las claves propias de cada pestaña: lo que devuelve su validador. Nunca
 * `vista`, `sub`, `semana` ni `local`, que son del marco.
 */
export type BusquedasDePestana = {
  semana: BusquedaSemana
  cobros: BusquedaCobros
  mora: BusquedaCobranza
  caja: BusquedaCaja
  locales: BusquedaLocales
  gente: BusquedaGente
  global: BusquedaGeneral
}

type ValidadorDe<TId extends IdPestana> = (raw: Record<string, unknown>) => BusquedasDePestana[TId]

/** El validador de cada pestaña. Una pestaña sin validador no compila. */
export const VALIDADORES: { readonly [TId in IdPestana]: ValidadorDe<TId> } = {
  semana: validarSemana,
  cobros: validarCobros,
  mora: validarCobranza,
  caja: validarCaja,
  locales: validarLocales,
  gente: validarGente,
  global: validarGeneral,
}

/** Lo que es del marco y vale para todas las pestañas. */
export type BusquedaComun = {
  /**
   * El lunes de la semana elegida. Sin él, la semana en curso: así la URL de
   * quien entra sin elegir nada no se reescribe, y un enlace sin semana
   * siempre abre la de hoy.
   */
  semana?: string
  /** El uuid del local elegido, en minúsculas. Sin él, todos los locales. */
  local?: string
}

/** `vista`, que se omite en la pestaña por defecto. */
type VistaDe<TId extends IdPestana> = TId extends typeof PESTANA_POR_DEFECTO ? { vista?: TId } : { vista: TId }

/** `sub`, que se omite en la primera sub-pestaña y no existe en una pestaña sin ellas. */
type SubDe<TId extends IdPestana> = [IdSubpestana<TId>] extends [never] ? unknown : { sub?: IdSubpestana<TId> }

/**
 * La búsqueda de una pestaña concreta: lo común, la `vista`, la `sub` y sus
 * claves.
 */
export type BusquedaDePestana<TId extends IdPestana> = BusquedaComun & VistaDe<TId> & SubDe<TId> & BusquedasDePestana[TId]

/**
 * Lo que devuelve el `validateSearch` de `/admin/metricas`: una unión por
 * pestaña. Un enlace `{ to: '/admin/metricas', search: { vista: 'cobros',
 * sub: 'calendario' } }` se comprueba contra las sub-pestañas y las claves
 * de Cobros, y con una que Cobros no tiene no compila.
 */
export type BusquedaMetricas = { [TId in IdPestana]: BusquedaDePestana<TId> }[IdPestana]

// ── Los enlaces viejos ─────────────────────────────────────────────────────

/**
 * Un enlace guardado de antes de una reorganización (27-09 y 28-09), llevado
 * a su sitio nuevo. Todo lo demás pasa tal cual: la semana, el local y las
 * claves propias que sigan teniendo sentido (`cuota`, `dim`…).
 *
 *   vista=general&sub=cupos, global&sub=cupos → mora (Riesgo) › cupos
 *   vista=general, global                     → global
 *   vista=cohortes&modo=todas                 → cobros › calendario (Semanas)
 *   vista=cobranza|mora&sub=primera-cuota     → cobros › impago-por-cuota
 *   vista=cobranza|mora&sub=impago-por-cuota  → cobros › impago-por-cuota
 *   vista=cobranza&sub=X                      → mora (Riesgo) › X
 *
 * `sub=deudores`, `sub=resumen` de Cobros y `vista=cohortes` sin `modo=todas`
 * no se traducen: son de Por cobrar.
 */
export function traducirEnlaceViejo(raw: Record<string, unknown>): Record<string, unknown> {
  const { modo, ...resto } = raw
  switch (raw.vista) {
    case 'general':
    case 'global':
      if (raw.sub === 'cupos') return { ...resto, vista: 'mora', sub: 'cupos' }
      return { ...resto, vista: 'global', sub: undefined }
    case 'cohortes':
      return { ...resto, vista: 'cobros', sub: modo === 'todas' ? 'calendario' : undefined }
    case 'cobranza':
    case 'mora':
      if (raw.sub === 'primera-cuota' || raw.sub === 'impago-por-cuota') {
        // En Riesgo la cuota era el número 2; en Cobros es el texto '2'.
        return { ...resto, vista: 'cobros', sub: 'impago-por-cuota', cuota: String(raw.cuota ?? '') || undefined }
      }
      return { ...resto, vista: 'mora' }
    default:
      // `modo` solo lo tuvo Cohortes: en cualquier otra pestaña no es de nadie.
      return resto
  }
}

// ── Lo común ───────────────────────────────────────────────────────────────

/**
 * La semana de la URL, llevada a su lunes. `undefined` —la semana en curso—
 * si no es un día válido, si es la semana de hoy (una sola URL para «esta
 * semana») o si todavía no ha empezado: el futuro no se mira desde aquí.
 */
export function semanaDeLaUrl(v: unknown, hoy: string): string | undefined {
  const dia = comoDia(v)
  if (!dia) return undefined
  const lunes = lunesDe(dia)
  return lunes >= lunesDe(hoy) ? undefined : lunes
}

/** La pestaña de la URL; sin ella, o con una que no existe, la por defecto. */
export function vistaDeLaUrl(v: unknown): IdPestana {
  return unoDe(IDS_PESTANA, v) ?? PESTANA_POR_DEFECTO
}

/**
 * La sub-pestaña de la URL, ya en su forma canónica: `undefined` si es la
 * primera (la de por defecto), si no es de esa pestaña o si la pestaña no
 * tiene sub-pestañas.
 */
export function subDeLaUrl<TId extends IdPestana>(vista: TId, v: unknown): IdSubpestana<TId> | undefined {
  const sub = unoDe(idsDeSubpestanas(vista), v)
  return sub === subPorDefecto(vista) ? undefined : sub
}

/**
 * La búsqueda de una pestaña a partir de sus piezas, ya con la forma de la
 * URL: sin `vista` en la pestaña por defecto, sin `sub` en la primera
 * sub-pestaña y sin claves vacías de más.
 *
 * Es la única forma de armar una `BusquedaMetricas` desde fuera: el marco la
 * usa en sus enlaces, las rutas viejas al redirigir y las pestañas al
 * enlazarse entre sí.
 */
export function busquedaDeMetricas<TId extends IdPestana>(
  vista: TId,
  propia: BusquedasDePestana[TId],
  comun: BusquedaComun = {},
  sub?: IdSubpestana<TId>,
): BusquedaMetricas {
  const armada = {
    ...propia,
    vista: vista === PESTANA_POR_DEFECTO ? undefined : vista,
    sub: sub === subPorDefecto(vista) ? undefined : sub,
    semana: comun.semana,
    local: comun.local,
  }
  // El compilador no sigue la correlación entre `vista`, `sub` y `propia` a
  // través del genérico (TypeScript #30581); la firma sí la garantiza: son
  // los de ESA pestaña.
  return armada as BusquedaMetricas
}

/**
 * Un sitio de Métricas (una pestaña y su sub-pestaña) con la semana y el
 * local que se le pasen y sin claves propias. Es lo que usa un enlace entre
 * pestañas: «ver esto en Riesgo › Cupos, con la misma semana y local».
 */
export function busquedaDelLugar(lugar: Lugar, comun: BusquedaComun = {}): BusquedaMetricas {
  return busquedaDeMetricas(lugar.vista, VALIDADORES[lugar.vista]({}), comun, lugar.sub)
}

/**
 * El `validateSearch` de la ruta: un enlace viejo llevado a su sitio, lo
 * común validado, la sub-pestaña de ESA pestaña y sus claves pasadas por SU
 * validador. `hoy` es el día operativo (lo da la ruta; aquí se recibe para
 * poder probarlo).
 */
export function validarBusquedaMetricas(raw: Record<string, unknown>, hoy: string): BusquedaMetricas {
  const nuevo = traducirEnlaceViejo(raw)
  const vista = vistaDeLaUrl(nuevo.vista)
  const validada = busquedaDeMetricas(
    vista,
    VALIDADORES[vista](nuevo),
    { semana: semanaDeLaUrl(nuevo.semana, hoy), local: comoId(nuevo.local) },
    subDeLaUrl(vista, nuevo.sub),
  )
  // TanStack mezcla la URL cruda con lo que devuelve este validador: una
  // clave cruda que nadie devuelve se quedaría en la URL canónica (el `modo`
  // de un enlace viejo de Cohortes, una clave de otra pestaña). Devuelta como
  // `undefined`, el router la quita al reescribir la URL.
  const sueltas = Object.fromEntries(
    Object.keys(raw)
      .filter((clave) => !(clave in validada))
      .map((clave) => [clave, undefined]),
  )
  return { ...sueltas, ...validada }
}

/** La pestaña de una búsqueda ya validada. */
export function vistaDe(busqueda: BusquedaMetricas): IdPestana {
  return busqueda.vista ?? PESTANA_POR_DEFECTO
}

/**
 * La sub-pestaña que se mira en una búsqueda ya validada de la pestaña
 * `vista`: la de la URL o, sin ella, la primera. `undefined` si la pestaña no
 * tiene sub-pestañas.
 */
export function subDe<TId extends IdPestana>(vista: TId, busqueda: BusquedaMetricas): IdSubpestana<TId> | undefined {
  const escrita = 'sub' in busqueda ? busqueda.sub : undefined
  return unoDe(idsDeSubpestanas(vista), escrita) ?? subPorDefecto(vista)
}

/** El sitio de una búsqueda ya validada: su pestaña y la sub-pestaña que se mira. */
export function lugarDe(busqueda: BusquedaMetricas): Lugar {
  const vista = vistaDe(busqueda)
  // Mismo caso que en `busquedaDeMetricas`: `subDe` es de ESA pestaña.
  return { vista, sub: subDe(vista, busqueda) } as Lugar
}

/** Lo común de una búsqueda ya validada. */
export function comunDe(busqueda: BusquedaMetricas): BusquedaComun {
  return { semana: busqueda.semana, local: busqueda.local }
}

/**
 * Las claves de la pestaña `vista` dentro de una búsqueda: se vuelven a pasar
 * por su validador, que es idempotente y deja fuera lo del marco.
 */
export function propiaDe<TId extends IdPestana>(
  vista: TId,
  busqueda: BusquedaMetricas,
): BusquedasDePestana[TId] {
  return VALIDADORES[vista](busqueda)
}

// ── La semana elegida ──────────────────────────────────────────────────────

export type SemanaElegida = {
  /** El lunes. */
  lunes: string
  /** El domingo. */
  domingo: string
  /** Es la semana de hoy. */
  enCurso: boolean
  /** El lunes de la semana de hoy. */
  lunesHoy: string
}

/** La semana que se mira: la de la URL o, sin ella, la de `hoy`. */
export function semanaElegida(semana: string | undefined, hoy: string): SemanaElegida {
  const lunesHoy = lunesDe(hoy)
  const lunes = semana ?? lunesHoy
  return { lunes, domingo: domingoDe(lunes), enCurso: lunes === lunesHoy, lunesHoy }
}

/**
 * La semana tal como va en un enlace: la en curso no se escribe (una sola
 * URL para «esta semana»).
 */
export function semanaParaEnlace(lunes: string, hoy: string): string | undefined {
  return lunes >= lunesDe(hoy) ? undefined : lunes
}
