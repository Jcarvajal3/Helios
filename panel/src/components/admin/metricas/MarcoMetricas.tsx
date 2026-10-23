import { Component, Suspense, lazy } from 'react'
import type { ErrorInfo, ReactNode } from 'react'
import { CalendarClock, History } from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { SelectorDeSemana } from '@/components/admin/tableros/SelectorDeSemana'
import { Filtro, Periodo, SkeletonBlock, SkeletonList, SkeletonStats } from '@/components/ui'
import {
  VALIDADORES,
  busquedaDeMetricas,
  comunDe,
  lugarDe,
  propiaDe,
  semanaElegida,
} from '@/features/admin/metricas/busqueda'
import type { BusquedaComun, BusquedaMetricas, BusquedasDePestana } from '@/features/admin/metricas/busqueda'
import { cuotaDe } from '@/features/admin/metricas/cobranza/busqueda'
import {
  enlacesDePestanas,
  enlacesDeSubpestanas,
  lugarEscrito,
  motivoSinSemana,
} from '@/features/admin/metricas/navegacion'
import { iconoDeMetricas } from '@/features/admin/metricas/iconos'
import { atajosDeJuanPablo, busquedaDelRango, rangoElegido } from '@/features/admin/metricas/juan-pablo/periodo'
import type { EnlaceDeNavegacion } from '@/features/admin/metricas/navegacion'
import { nombreDelLocal } from '@/features/admin/metricas/opcionesDeLocal'
import { definicionDe, nombreDelLugar } from '@/features/admin/metricas/pestanas'
import type { IdPestana, IdSubpestana, Lugar, Periodo as PeriodoDeLaPestana } from '@/features/admin/metricas/pestanas'
import type { OpcionesDeCambio, PropsPestana } from '@/features/admin/metricas/tipos'
import { reportarError } from '@/lib/sentry'
import { BandaDeSubpestanas, LineaDelLugar, PestanasConTono } from './NavegacionDeMetricas'
import type { EnlaceDeNivel } from './NavegacionDeMetricas'
import { SelectorDeLocal, useLocalesDeMetricas } from './SelectorDeLocal'

// Cada sub-pestaña en su trozo: abrir Métricas no descarga todas, y lo que
// rompa una no toca a las demás. Las carpetas son las de siempre
// (`pestanas.ts` dice cuál pinta cada sub-pestaña).
const ResumenDeLaSemana = lazy(() =>
  import('./semana/resumen/ResumenDeLaSemana').then((m) => ({ default: m.ResumenDeLaSemana })),
)
const PestanaSemana = lazy(() => import('./semana/PestanaSemana').then((m) => ({ default: m.PestanaSemana })))
const PestanaCohortes = lazy(() =>
  import('./cohortes/PestanaCohortes').then((m) => ({ default: m.PestanaCohortes })),
)
const PestanaCobranza = lazy(() =>
  import('./cobranza/PestanaCobranza').then((m) => ({ default: m.PestanaCobranza })),
)
const PestanaCaja = lazy(() => import('./caja/PestanaCaja').then((m) => ({ default: m.PestanaCaja })))
const PestanaLocales = lazy(() => import('./locales/PestanaLocales').then((m) => ({ default: m.PestanaLocales })))
const PestanaGente = lazy(() => import('./gente/PestanaGente').then((m) => ({ default: m.PestanaGente })))
const PestanaJuanPablo = lazy(() =>
  import('./juan-pablo/PestanaJuanPablo').then((m) => ({ default: m.PestanaJuanPablo })),
)
const PestanaGeneral = lazy(() => import('./general/PestanaGeneral').then((m) => ({ default: m.PestanaGeneral })))
const ImpagoPorCuotaDeLaSemana = lazy(() =>
  import('./cobranza/SubvistasDeRiesgo').then((m) => ({ default: m.ImpagoPorCuotaDeLaSemana })),
)

/** Lo que el marco escribe en la URL: la ruta lo convierte en un `navigate`. */
export type Navegar = (search: BusquedaMetricas, opciones?: OpcionesDeCambio) => void

/** Lo de `PropsPestana` que es igual para todas las pestañas. */
type Comunes = Omit<PropsPestana<unknown>, 'busqueda' | 'cambiarBusqueda'>

/** Un enlace de la navegación, con su destino en `/admin/metricas` y su icono. */
function comoEnlace(e: EnlaceDeNavegacion, icono: LucideIcon | undefined): EnlaceDeNivel {
  return { ...e, destino: { to: '/admin/metricas', search: e.busqueda }, icono }
}

/**
 * Métricas: todas las cifras del super admin en una pantalla.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * De arriba abajo:
 *
 *   1. los dos controles que valen para todas las pestañas: la semana (o lo
 *      que mire en su lugar lo que se ve: «Desde el inicio», «Hoy», o el
 *      periodo propio de Juan Pablo) y el local
 *   2. las ocho pestañas (nivel 1), cada una en el tono de su área
 *   3. las sub-pestañas de la activa (nivel 2), en su banda
 *   4. «Pestaña › Sub-pestaña — lo que contesta»
 *   5. lo que pinta la sub-pestaña, con sus filtros (nivel 3)
 *
 * Todo vive en la URL (`features/admin/metricas/busqueda.ts`): el enlace que
 * se pega en un chat abre lo mismo, con la misma semana, el mismo local y la
 * misma sub-pestaña. Los niveles 1 y 2 los pinta SOLO el marco, desde el
 * registro (`pestanas.ts`); ninguna pestaña pinta su propio selector de
 * sub-vista, recibe la `sub` ya elegida.
 *
 * El marco no sabe nada de lo que pinta cada sub-pestaña. Le pasa la semana,
 * el local y sus propias claves ya validadas (`PropsPestana`), la envuelve en
 * el tono de su área (`data-area`) y la carga cuando hace falta.
 */
export function MarcoMetricas({
  busqueda,
  hoy,
  navegar,
}: {
  busqueda: BusquedaMetricas
  /** El día operativo de hoy. */
  hoy: string
  navegar: Navegar
}) {
  const lugar = lugarDe(busqueda)
  const vista = lugar.vista
  const pestana = definicionDe(vista)
  const escrito = lugarEscrito(lugar)
  const nombre = nombreDelLugar(lugar)
  const comun = comunDe(busqueda)
  const semana = semanaElegida(comun.semana, hoy)
  const local = comun.local ?? null
  const locales = useLocalesDeMetricas()

  /** Cambia la semana o el local, y deja la pestaña, la sub-pestaña y sus claves como estaban. */
  function cambiarComun(parcial: BusquedaComun) {
    navegar(busquedaDeMetricas(vista, propiaDe(vista, busqueda), { ...comun, ...parcial }, lugar.sub))
  }

  const comunes: Comunes = {
    semana: semana.lunes,
    domingo: semana.domingo,
    enCurso: semana.enCurso,
    hoy,
    local,
    nombreLocal: nombreDelLocal(locales.data ?? [], local),
  }

  /** El `cambiarBusqueda` de una pestaña: su parte, pasada otra vez por su validador, en la misma sub-pestaña. */
  function cambiarPropia<TId extends IdPestana>(id: TId) {
    return (parcial: Partial<BusquedasDePestana[TId]>, opciones?: OpcionesDeCambio) =>
      navegar(
        busquedaDeMetricas(
          id,
          VALIDADORES[id]({ ...propiaDe(id, busqueda), ...parcial }),
          comun,
          // Es la sub-pestaña de ESTA pestaña: `cambiarPropia` solo se pide
          // con la `vista` de `lugar`.
          lugar.sub as IdSubpestana<TId> | undefined,
        ),
        opciones,
      )
  }

  return (
    <div className="flex flex-col">
      <div className="flex flex-wrap items-end gap-x-5 gap-y-3">
        {escrito.periodo === 'semana' ? (
          <Filtro label="Semana">
            <SelectorDeSemana
              lunes={semana.lunes}
              lunesHoy={semana.lunesHoy}
              // La semana en curso no se escribe en la URL: así «esta semana»
              // es siempre la de hoy, también en un enlace de la semana pasada.
              onLunes={(lunes) => cambiarComun({ semana: lunes === semana.lunesHoy ? undefined : lunes })}
            />
          </Filtro>
        ) : escrito.periodo === 'propio' ? (
          // Solo Juan Pablo elige su periodo: un día, una semana, un mes o un
          // rango, de sus propias claves (`desde`, `hasta`). Hoy no se escribe.
          <Filtro label="Periodo">
            <Periodo
              rango={rangoElegido(propiaDe('juan-pablo', busqueda), hoy)}
              hoy={hoy}
              atajos={atajosDeJuanPablo(hoy)}
              onChange={(r) => cambiarPropia('juan-pablo')(busquedaDelRango(r, hoy), { reemplazar: true })}
            />
          </Filtro>
        ) : (
          <Filtro label="Periodo">
            <SinSemana periodo={escrito.periodo} motivo={motivoSinSemana(nombre, escrito.periodo)} />
          </Filtro>
        )}
        <Filtro label="Clínica">
          <SelectorDeLocal
            local={local}
            onCambiar={(id) => cambiarComun({ local: id ?? undefined })}
            motivoApagado={pestana.local === 'ignora' ? `${pestana.titulo} no se parte por clínica.` : undefined}
          />
        </Filtro>
      </div>

      {/* Niveles 1 y 2: pegados, la banda cuelga de la regla de las pestañas. */}
      <div className="mt-4">
        <PestanasConTono
          etiqueta="Pestañas de Métricas"
          enlaces={enlacesDePestanas(busqueda).map((e) => comoEnlace(e, iconoDeMetricas(e.clave)))}
        />
        <BandaDeSubpestanas
          etiqueta={`Sub-pestañas de ${pestana.titulo}`}
          tono={pestana.tono}
          enlaces={enlacesDeSubpestanas(busqueda).map((e) => comoEnlace(e, iconoDeMetricas(lugar.vista, e.clave)))}
        />
      </div>

      <LineaDelLugar
        ruta={escrito.ruta}
        descripcion={escrito.descripcion}
        tono={escrito.tono}
        className="mt-5 mb-6"
      />

      {/* El tono de la pestaña: la serie principal de sus gráficos y los
          iconos de sus cifras salen en el color de su área. */}
      <div data-area={pestana.tono}>
        <LimiteDePestana key={`${vista}:${lugar.sub ?? ''}`} titulo={nombre}>
          <Suspense fallback={<EsqueletoDePestana />}>
            <LoQueSeVe lugar={lugar} busqueda={busqueda} comunes={comunes} cambiarPropia={cambiarPropia} />
          </Suspense>
        </LimiteDePestana>
      </div>
    </div>
  )
}

/**
 * Lo que pinta la sub-pestaña elegida, con sus props. Un `switch` y no un
 * mapa de componentes: así cada una recibe SU búsqueda con su tipo, sin
 * conversiones, y una sub-pestaña nueva sin su caso no compila.
 */
function LoQueSeVe({
  lugar,
  busqueda,
  comunes,
  cambiarPropia,
}: {
  lugar: Lugar
  busqueda: BusquedaMetricas
  comunes: Comunes
  cambiarPropia: <TId extends IdPestana>(
    id: TId,
  ) => (parcial: Partial<BusquedasDePestana[TId]>, opciones?: OpcionesDeCambio) => void
}) {
  switch (lugar.vista) {
    case 'juan-pablo':
      return (
        <PestanaJuanPablo
          {...comunes}
          busqueda={propiaDe('juan-pablo', busqueda)}
          cambiarBusqueda={cambiarPropia('juan-pablo')}
        />
      )
    case 'semana': {
      const props = { ...comunes, busqueda: propiaDe('semana', busqueda), cambiarBusqueda: cambiarPropia('semana') }
      // Resumen: lo nuevo del 27-09. Rendimiento: la pestaña Semana de antes.
      return lugar.sub === 'rendimiento' ? <PestanaSemana {...props} /> : <ResumenDeLaSemana {...props} />
    }
    case 'cobros': {
      const props = { ...comunes, busqueda: propiaDe('cobros', busqueda), cambiarBusqueda: cambiarPropia('cobros') }
      // Semanas: lo que era Cohortes («Comparar todas»). Impago por cuota: lo
      // pinta la carpeta Cobranza. Los avisos se mudaron a Notificaciones ›
      // Rendimiento (29-09).
      if (lugar.sub === 'impago-por-cuota') {
        const b = props.busqueda
        return (
          <ImpagoPorCuotaDeLaSemana
            domingo={comunes.domingo}
            local={comunes.local}
            cuota={cuotaDe(b)}
            onCambiarCuota={(c) => props.cambiarBusqueda({ cuota: c === 2 ? '2' : undefined }, { reemplazar: true })}
            dimension={b.dim ?? 'semana'}
            onCambiarDimension={(dim) =>
              props.cambiarBusqueda({ dim: dim === 'semana' ? undefined : dim }, { reemplazar: true })
            }
          />
        )
      }
      return <PestanaCohortes {...props} sub="calendario" />
    }
    case 'mora':
      return (
        <PestanaCobranza
          {...comunes}
          sub={lugar.sub ?? 'resumen'}
          busqueda={propiaDe('mora', busqueda)}
          cambiarBusqueda={cambiarPropia('mora')}
        />
      )
    case 'caja':
      return (
        <PestanaCaja
          {...comunes}
          sub={lugar.sub ?? 'balance'}
          busqueda={propiaDe('caja', busqueda)}
          cambiarBusqueda={cambiarPropia('caja')}
        />
      )
    case 'locales':
      return (
        <PestanaLocales
          {...comunes}
          busqueda={propiaDe('locales', busqueda)}
          cambiarBusqueda={cambiarPropia('locales')}
        />
      )
    case 'gente':
      return (
        <PestanaGente
          {...comunes}
          busqueda={propiaDe('gente', busqueda)}
          cambiarBusqueda={cambiarPropia('gente')}
        />
      )
    case 'global':
      return (
        <PestanaGeneral
          {...comunes}
          busqueda={propiaDe('global', busqueda)}
          cambiarBusqueda={cambiarPropia('global')}
        />
      )
  }
}

/**
 * En el hueco de la semana, cuando lo que se ve no la mira: «Desde el inicio»
 * (Global › Resumen, el Perfil de la gente) o «Hoy» (los cupos, los deudores,
 * la proyección). El motivo va en el `title` y, para el lector de pantalla,
 * escrito a continuación.
 */
function SinSemana({
  periodo,
  motivo,
}: {
  periodo: Exclude<PeriodoDeLaPestana, 'semana' | 'propio'>
  motivo: string
}) {
  const Icono = periodo === 'hoy' ? CalendarClock : History
  return (
    <span
      title={motivo}
      className="inline-flex h-panel-control-sm items-center gap-2 rounded-panel-control bg-panel-raised px-2.5 type-panel-control text-on-surface-variant"
    >
      <Icono size={15} aria-hidden className="text-panel-muted" />
      {periodo === 'hoy' ? 'Hoy' : 'Desde el inicio'}
      <span className="sr-only">. {motivo}</span>
    </span>
  )
}

/** Mientras llega el trozo de la sub-pestaña: la frase, una fila de cifras y un bloque. */
function EsqueletoDePestana() {
  return (
    <div aria-busy className="flex flex-col gap-6">
      <SkeletonBlock className="h-5 w-3/5" />
      <SkeletonStats count={4} cols={4} />
      <SkeletonList rows={4} />
    </div>
  )
}

/**
 * Si una sub-pestaña revienta al pintarse (o su trozo no llega: un despliegue
 * nuevo mientras la pantalla estaba abierta), se dice en su hueco y el resto
 * de Métricas sigue funcionando: se puede cambiar de pestaña o de semana.
 * «Reintentar» recarga la página: un fallo de pintado sale igual con los
 * mismos datos en memoria, y un trozo perdido solo vuelve recargando.
 */
class LimiteDePestana extends Component<{ titulo: string; children: ReactNode }, { error: Error | null }> {
  state: { error: Error | null } = { error: null }

  static getDerivedStateFromError(error: unknown): { error: Error } {
    return { error: error instanceof Error ? error : new Error(String(error)) }
  }

  componentDidCatch(error: unknown, info: ErrorInfo) {
    reportarError(error, { componentStack: info.componentStack, pestana: this.props.titulo })
  }

  render() {
    if (this.state.error) {
      return (
        <ErrorConReintento
          title={`No se pudo mostrar ${this.props.titulo}`}
          error={this.state.error}
          onReintentar={() => window.location.reload()}
        />
      )
    }
    return this.props.children
  }
}
