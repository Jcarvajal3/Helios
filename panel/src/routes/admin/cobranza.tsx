import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'

import { CalendarioDeCobro } from '@/components/admin/calendario-de-cobro/CalendarioDeCobro'
import { CarteraVencida } from '@/components/admin/CarteraVencida'
import { Morosos } from '@/components/admin/cartera/Morosos'
import { PestanaPromesas } from '@/components/admin/PestanaPromesas'
import { PorSemana } from '@/components/admin/cartera/semana/PorSemana'
import { resumirPromesasDeHoy } from '@/components/admin/inicio/colas'
import { Tabs, hoyCaracas } from '@/components/ui'
import { filtroDeCartera } from '@/features/admin/cobranza/cartera'
import type { FiltroCartera } from '@/features/admin/cobranza/cartera'
import { consultaPromesas } from '@/features/admin/cobranza/consultas'
import { PERFILES_DEUDOR } from '@/features/admin/metricas/cobranza/perfiles'
import type { PerfilDeudor } from '@/features/admin/metricas/cobranza/perfiles'
import { VALORES_ESTADO_PROMESA } from '@/features/admin/estados'
import type { EstadoPromesa } from '@/features/admin/estados'
import { lunesDe } from '@/features/admin/semana'
import { comoDia, unoDe } from '@/lib/busqueda'

type Vista = 'lista' | 'morosos' | 'semana' | 'calendario' | 'promesas'

const VALORES_VISTA: readonly Vista[] = ['lista', 'morosos', 'semana', 'calendario', 'promesas']

/**
 * El estado de la pantalla, entero en la URL. Cada pestaña tiene sus
 * parámetros y no se pisan, así que al volver a una sigue como se dejó.
 */
type PorCobrarSearch = {
  /** La pestaña. Sin ella, la lista. */
  vista?: Vista
  /**
   * Lista: un recorte que llega por enlace (Inicio, el catálogo, el
   * asistente) y se ve como etiqueta que se quita. La lista ya no tiene
   * filtros de plazo ni de tramo: va en grupos. Las claves no cambian para
   * que los enlaces guardados sigan llegando.
   */
  tramo?: FiltroCartera
  /** Lista: un perfil de deudor que llega por enlace (Métricas, el catálogo), también como etiqueta. */
  perfil?: PerfilDeudor
  /** Lista: por prioridad, en grupos. Sin él, por días de atraso. */
  orden?: 'prioridad'
  /** Cohortes: el lunes de la semana de consumo. Sin él, la más reciente con algo vencido. */
  cohorte?: string
  /** Cohortes: el local (uuid). Sin él, todos. */
  local?: string
  /** Cohortes: solo la cuota 1 o la 2. Sin él, las dos. */
  cuota?: '1' | '2'
  /** El estado de Promesas. Sin él, las que vencen hoy. */
  estado?: EstadoPromesa
  /** Calendario: el lunes de la semana que se mira. Sin él, la semana en curso. */
  semana?: string
  /** Calendario: el día elegido en el gráfico. Sin él, la semana entera. */
  dia?: string
  /** Calendario: con 'todo', también lo ya cobrado. */
  ver?: 'todo'
}

export const Route = createFileRoute('/admin/cobranza')({
  staticData: { title: 'Por cobrar', width: 'wide' },
  component: PorCobrarPage,
  validateSearch: (search: Record<string, unknown>): PorCobrarSearch => {
    // Cualquier día vale y se lleva a su lunes: un enlace con el miércoles
    // enseña la semana de ese miércoles.
    const semana = comoDia(search.semana)
    const cohorte = comoDia(search.cohorte)
    return {
      vista: unoDe(VALORES_VISTA, search.vista),
      // Un enlace al tramo de antes (`t5`) cae en el que lo sustituye.
      tramo: filtroDeCartera(search.tramo),
      perfil: unoDe(PERFILES_DEUDOR, search.perfil),
      orden: unoDe(['prioridad'] as const, search.orden),
      cohorte: cohorte ? lunesDe(cohorte) : undefined,
      local: typeof search.local === 'string' && /^[0-9a-f-]{36}$/i.test(search.local) ? search.local : undefined,
      cuota: unoDe(['1', '2'] as const, search.cuota),
      estado: unoDe(VALORES_ESTADO_PROMESA, search.estado),
      semana: semana ? lunesDe(semana) : undefined,
      dia: comoDia(search.dia),
      ver: unoDe(['todo'], search.ver),
    }
  },
})

/**
 * Por cobrar: la mesa de trabajo de quien cobra. Todo lo que hay aquí acaba
 * en una persona a la que escribir; lo que acaba en otra cifra (comparar
 * semanas, medir si los avisos o las gestiones funcionan) es de Métricas.
 *
 *   Lista        la cola del día, por días de atraso o en grupos por prioridad, con las señales de cada uno
 *   Morosos      solo quien debe algo vencido: desde cuándo, cuánto, su estado y su último pago
 *   Cohortes     lo consumido cada semana (A1, A2…), sus dos cuotas, cómo es y quién lo debe
 *   Calendario   lo que vence cada día, con su desglose y su reparto por local
 *   Promesas     las promesas de pago que dejaron las gestiones
 *
 * Cobra una sola persona, así que no hay reparto de cartera ni cifras por
 * gestora: la lista es la cola del día.
 */
function PorCobrarPage() {
  const navigate = useNavigate({ from: '/admin/cobranza' })
  const search = Route.useSearch()
  const { tramo = 'todos', estado = 'vence_hoy' } = search
  const vista: Vista = search.vista ?? 'lista'
  // La semana en curso es la del calendario de Caracas: los vencimientos son
  // días naturales, no operativos.
  const lunesHoy = lunesDe(hoyCaracas())

  function cambiar(patch: Partial<PorCobrarSearch>) {
    void navigate({ search: (s) => ({ ...s, ...patch }) })
  }

  // La misma clave que la insignia del menú y la cola de Inicio: no cuesta
  // otra llamada.
  const vencenHoy = useQuery({
    ...consultaPromesas(),
    select: (d) => resumirPromesasDeHoy(d).cantidad,
  })

  return (
    <>
      <Tabs
        options={[
          { value: 'lista', label: 'Lista' },
          { value: 'morosos', label: 'Morosos' },
          { value: 'semana', label: 'Cohortes' },
          { value: 'calendario', label: 'Calendario' },
          { value: 'promesas', label: 'Promesas', insignia: vencenHoy.data },
        ]}
        value={vista}
        onChange={(v) => cambiar({ vista: v === 'lista' ? undefined : v })}
      />

      {vista === 'lista' && (
        <CarteraVencida
          filtro={tramo}
          onFiltro={(f) => cambiar({ tramo: f === 'todos' ? undefined : f })}
          perfil={search.perfil}
          onPerfil={(p) => cambiar({ perfil: p })}
          orden={search.orden ?? 'atraso'}
          onOrden={(o) =>
            void navigate({ search: (s) => ({ ...s, orden: o === 'prioridad' ? o : undefined }), replace: true })
          }
        />
      )}

      {vista === 'morosos' && <Morosos />}

      {vista === 'semana' && (
        <PorSemana
          cohorte={search.cohorte}
          local={search.local ?? null}
          cuota={search.cuota ?? 'todas'}
          onCohorte={(lunes) => cambiar({ cohorte: lunes })}
          onLocal={(local) => cambiar({ local: local ?? undefined })}
          onCuota={(c) =>
            void navigate({ search: (s) => ({ ...s, cuota: c === 'todas' ? undefined : c }), replace: true })
          }
        />
      )}

      {vista === 'calendario' && (
        <CalendarioDeCobro
          lunes={search.semana ?? lunesHoy}
          lunesHoy={lunesHoy}
          dia={search.dia}
          ver={search.ver ?? 'pendiente'}
          // Cambiar de semana suelta el día: el de la semana de antes ya no está.
          onLunes={(lunes) => cambiar({ semana: lunes === lunesHoy ? undefined : lunes, dia: undefined })}
          onDia={(d) => void navigate({ search: (s) => ({ ...s, dia: d ?? undefined }), replace: true })}
          onVer={(v) =>
            void navigate({ search: (s) => ({ ...s, ver: v === 'todo' ? 'todo' : undefined }), replace: true })
          }
        />
      )}

      {vista === 'promesas' && (
        <PestanaPromesas
          estado={estado}
          onEstado={(e) => cambiar({ estado: e === 'vence_hoy' ? undefined : e })}
        />
      )}
    </>
  )
}
