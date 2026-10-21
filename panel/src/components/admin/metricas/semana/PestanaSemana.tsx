import { useQuery } from '@tanstack/react-query'

import { estadoDeConsulta } from '@/components/ui'
import type { BusquedaComun } from '@/features/admin/metricas/busqueda'
import { consultaDeSemanas } from '@/features/admin/metricas/semana/api'
import { COLUMNAS_POR_DEFECTO, columnasDe } from '@/features/admin/metricas/semana/busqueda'
import type { BusquedaSemana } from '@/features/admin/metricas/semana/busqueda'
import { cifrasDeLaSemana } from '@/features/admin/metricas/semana/cifras'
import { metasDeLaSemana } from '@/features/admin/metricas/semana/metas'
import type { PropsPestana } from '@/features/admin/metricas/tipos'
import { useIsSuperAdmin } from '@/features/admin/role'
import { useParametros } from '@/features/admin/useParametros'
import { CifrasDeLaSemana } from './CifrasDeLaSemana'
import { MetasDeLaSemana } from './MetasDeLaSemana'
import { TablaSemanaASemana } from './TablaSemanaASemana'

/**
 * Métricas › Semana: ¿cómo va el negocio esta semana frente a las anteriores?
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Las cinco cifras que mandan (consumo, Comisión Helios, personas, cobrado a
 * tiempo y mora), cada una con su cambio y su chispa, la tabla «Semana a
 * semana» y las metas. Sin frase arriba: repetía las tarjetas. Todo sale de
 * UNA lectura, `admin_metricas_semanas`, que respeta la semana y el local de
 * arriba: la tarjeta y la tabla no pueden decir cosas distintas.
 *
 * La semana en curso va a medias y se compara con los mismos días de la
 * anterior; lo pinta como lo usó la base (su «hoy» y su semana), no como lo
 * pidió el navegador.
 */
export function PestanaSemana({ semana, enCurso, local, busqueda, cambiarBusqueda }: PropsPestana<BusquedaSemana>) {
  const columnas = busqueda.semanas ?? COLUMNAS_POR_DEFECTO
  const consulta = useQuery(consultaDeSemanas({ semana, local, semanas: columnasDe(busqueda) }))
  const parametros = useParametros()
  const esSuperAdmin = useIsSuperAdmin()

  const estado = estadoDeConsulta(consulta)
  const respuesta = consulta.data
  const elegida = respuesta?.semanas.at(-1)
  const reintentar = () => void consulta.refetch()

  // Los enlaces llevan la misma semana y el mismo local. La en curso no se
  // escribe: así el enlace sigue siendo «esta semana».
  const comun: BusquedaComun = { semana: enCurso ? undefined : semana, local: local ?? undefined }

  const cifras =
    respuesta && estado === 'listo' ? cifrasDeLaSemana({ respuesta, local, parametros: parametros.data }) : null
  const metas =
    elegida && estado === 'listo' ? metasDeLaSemana(elegida.cifras, elegida.enCurso, parametros.data) : null
  // Las metas necesitan los parámetros; las cifras no (sin ellos, sin meta ni pastilla).
  const estadoMetas = estado === 'listo' ? estadoDeConsulta(parametros) : estado
  // Ninguna meta (`meta_*`) tiene valor en Helios: el bloque solo decía «Sin
  // meta» cinco veces. Sale en cuanto se fije alguna en Ajustes › Parámetros.
  const hayMetas = metas === null || metas.some((m) => m.meta !== null)

  return (
    <div className="flex flex-col gap-6">
      <CifrasDeLaSemana cifras={cifras} estado={estado} onReintentar={reintentar} comun={comun} />

      <TablaSemanaASemana
        respuesta={respuesta}
        estado={estado}
        error={consulta.error}
        onReintentar={reintentar}
        columnas={columnas}
        onColumnas={(c) => cambiarBusqueda({ semanas: c === COLUMNAS_POR_DEFECTO ? undefined : c }, { reemplazar: true })}
        comun={comun}
        local={local}
        actualizando={consulta.isPlaceholderData}
      />

      {hayMetas && (
        <MetasDeLaSemana
          metas={metas}
          estado={estadoMetas}
          onReintentar={() => {
            if (consulta.isError) reintentar()
            if (parametros.isError) void parametros.refetch()
          }}
          comun={comun}
          local={local}
          esSuperAdmin={esSuperAdmin}
        />
      )}
    </div>
  )
}
