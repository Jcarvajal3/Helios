import type { BusquedaCobranza } from '@/features/admin/metricas/cobranza/busqueda'
import { corteDeLaSemana } from '@/features/admin/metricas/cobranza/semana'
import type { IdSubpestana } from '@/features/admin/metricas/pestanas'
import type { PropsSubpestana } from '@/features/admin/metricas/tipos'
import { ResumenDeCobranza } from './ResumenDeCobranza'
import { CuposDeHoy, RendimientoDeLaSemana } from './SubvistasDeRiesgo'

/**
 * Métricas › Riesgo (id `mora`, la carpeta Cobranza).
 * ══════════════════════════════════════════════════════════════════════════
 *
 * La foto de la cartera y lo que hace la cobranza, con la semana y el local
 * de arriba. Pinta las tres sub-pestañas de Riesgo, que elige el marco:
 *
 *   resumen      cifras, vencía y entró, tramos, cambio de tramo y enlaces
 *   cupos        el cupo ocupado por nivel (hoy)
 *   rendimiento  lo recuperado, la cura por tramo, las gestiones y las promesas
 *
 * Lo que no está aquí y por qué: la lista de deudores es trabajo y vive en
 * Por cobrar; el impago por cuota sigue cada semana de consumo y vive en
 * Cobros (esta carpeta lo pinta igual, desde `ImpagoPorCuotaDeLaSemana`).
 *
 * Los datos y las cuentas viven en `features/admin/metricas/cobranza/`; aquí
 * solo se reparte la pantalla.
 */
export function PestanaCobranza({
  sub,
  semana,
  domingo,
  enCurso,
  hoy,
  local,
  nombreLocal,
}: PropsSubpestana<BusquedaCobranza, IdSubpestana<'mora'>>) {
  // Lo que va en la URL para enlazar otra sub-pestaña sin perder la semana ni
  // el local: la semana en curso no se escribe (el marco hace lo mismo).
  const enlace = { semana: enCurso ? undefined : semana, local: local ?? undefined }

  return (
    <div className="flex flex-col gap-6">
      {sub === 'resumen' && (
        <ResumenDeCobranza
          semana={semana}
          domingo={domingo}
          enCurso={enCurso}
          hoy={hoy}
          local={local}
          nombreLocal={nombreLocal}
          enlace={enlace}
        />
      )}

      {sub === 'cupos' && <CuposDeHoy local={local} nombreLocal={nombreLocal} />}

      {sub === 'rendimiento' && (
        <RendimientoDeLaSemana
          lunes={semana}
          domingo={domingo}
          corte={corteDeLaSemana(domingo, hoy)}
          local={local}
        />
      )}
    </div>
  )
}
