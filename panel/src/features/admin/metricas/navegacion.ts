import { VALIDADORES, busquedaDeMetricas, comunDe, lugarDe, propiaDe } from './busqueda'
import type { BusquedaMetricas } from './busqueda'
import {
  PESTANAS,
  definicionDe,
  descripcionDelLugar,
  periodoDe,
  subpestanaDe,
  subpestanasDe,
} from './pestanas'
import type { IdPestana, Lugar, Periodo, TonoDePestana } from './pestanas'

// ═══════════════════════════════════════════════════════════════════════════
// Lo que pinta la navegación de Métricas, calculado de la URL y el registro:
//
//   nivel 1  las pestañas (subrayadas, cada una en el tono de su área)
//   nivel 2  las sub-pestañas de la activa (píldoras en su banda)
//   lugar    «Cobros › Calendario — lo que contesta», encima del contenido
//
// Los filtros (Cuota 1 · Cuota 2, Ventana…) son el nivel 3 y los pinta cada
// pestaña: aquí no entran.
//
// Puro: se prueba en `navegacion.test.ts`. El marco solo lo convierte en
// enlaces.
// ═══════════════════════════════════════════════════════════════════════════

/** Un enlace de la navegación: adónde lleva y si es donde se está. */
export type EnlaceDeNavegacion = {
  clave: string
  rotulo: string
  tono: TonoDePestana
  busqueda: BusquedaMetricas
  /**
   * `pagina`: lleva exactamente a lo que se ve. `seccion`: es la pestaña
   * activa, pero se está en otra de sus sub-pestañas (su enlace lleva a la
   * primera). `null`: no es donde se está.
   */
  actual: 'pagina' | 'seccion' | null
}

/**
 * Las pestañas, con adónde lleva cada una: a su primera sub-pestaña, con la
 * misma semana y el mismo local, y sin las claves de la pestaña que se deja
 * (no significan nada en la otra).
 */
export function enlacesDePestanas(busqueda: BusquedaMetricas): EnlaceDeNavegacion[] {
  const aqui = lugarDe(busqueda)
  const comun = comunDe(busqueda)
  return PESTANAS.map((p) => {
    const activa = p.id === aqui.vista
    const primera = subpestanasDe(p.id).at(0)
    return {
      clave: p.id,
      rotulo: p.titulo,
      tono: p.tono,
      busqueda: busquedaDeMetricas(p.id, VALIDADORES[p.id]({}), comun),
      actual: !activa ? null : primera === undefined || primera.id === aqui.sub ? 'pagina' : 'seccion',
    }
  })
}

/**
 * Las sub-pestañas de la pestaña activa, con adónde lleva cada una: la misma
 * pestaña, semana y local, y las claves de la pestaña tal como estaban (la
 * cuota elegida en Cobros sigue elegida en Recordatorios). Vacío si la
 * pestaña no tiene sub-pestañas: entonces no se pinta la banda.
 */
export function enlacesDeSubpestanas(busqueda: BusquedaMetricas): EnlaceDeNavegacion[] {
  const aqui = lugarDe(busqueda)
  return enlacesDeSubpestanasDe(aqui.vista, busqueda, aqui.sub)
}

function enlacesDeSubpestanasDe<TId extends IdPestana>(
  vista: TId,
  busqueda: BusquedaMetricas,
  subActual: string | undefined,
): EnlaceDeNavegacion[] {
  const tono = definicionDe(vista).tono
  const propia = propiaDe(vista, busqueda)
  const comun = comunDe(busqueda)
  return subpestanasDe(vista).map((s) => ({
    clave: s.id,
    rotulo: s.titulo,
    tono,
    busqueda: busquedaDeMetricas(vista, propia, comun, s.id),
    actual: s.id === subActual ? 'pagina' : null,
  }))
}

/** Dónde se está, para la línea de encima del contenido y el título de la página. */
export type LugarEscrito = {
  /** «Cobros», «Calendario»; solo la pestaña si no tiene sub-pestañas. */
  ruta: ReadonlyArray<string>
  /** Lo que contesta, en una línea. */
  descripcion: string
  tono: TonoDePestana
  periodo: Periodo
}

export function lugarEscrito(lugar: Lugar): LugarEscrito {
  const pestana = definicionDe(lugar.vista)
  const sub = subpestanaDe(lugar.vista, lugar.sub)
  return {
    ruta: sub ? [pestana.titulo, sub.titulo] : [pestana.titulo],
    descripcion: descripcionDelLugar(lugar),
    tono: pestana.tono,
    periodo: periodoDe(lugar.vista, lugar.sub),
  }
}

/**
 * Lo que dice el hueco de la semana cuando lo que se ve no la mira. Una
 * pestaña con periodo `propio` pinta ahí su selector: no lleva motivo.
 */
export function motivoSinSemana(nombre: string, periodo: Exclude<Periodo, 'semana' | 'propio'>): string {
  return periodo === 'hoy'
    ? `${nombre} es de hoy: la semana no la cambia.`
    : `${nombre} mira todo desde el primer día: la semana no aplica aquí.`
}
