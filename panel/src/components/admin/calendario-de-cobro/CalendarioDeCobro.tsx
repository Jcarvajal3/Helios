import { Seccion, Segmented, SkeletonBlock, SkeletonCard, SkeletonStats } from '@/components/ui'
import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { diaDentro } from '@/features/admin/porCobrar'
import type { VerPorCobrar } from '@/features/admin/porCobrar'
import { domingoDe } from '@/features/admin/semana'
import { CifrasDeLaSemana } from './CifrasDeLaSemana'
import { LoQueVenceCadaDia } from './LoQueVenceCadaDia'
import { PorLocal } from './PorLocal'
import { SelectorDeSemana } from '@/components/admin/tableros/SelectorDeSemana'
import { usePorCobrar } from './usePorCobrar'

const OPCIONES_VER: Array<{ value: VerPorCobrar; label: string }> = [
  { value: 'pendiente', label: 'Por cobrar' },
  { value: 'todo', label: 'Todo lo que vence' },
]

/**
 * Por cobrar › Calendario: cuánto hay que cobrar cada día de una semana,
 * partido en consumo y service fee, y qué parte corresponde a cada local.
 *
 * Es «Por cobrar a usuarios» del Balance de Dinero puesto en calendario, y
 * vive en Cobranza porque es el orden en que entra el dinero que se persigue. La semana, lo
 * que se ve y el día elegido van en la URL (`?semana=`, `?ver=`, `?dia=`), así
 * que «mira lo que vence el jueves en cada local» se manda como un enlace.
 */
export function CalendarioDeCobro({
  lunes,
  lunesHoy,
  dia,
  ver,
  onLunes,
  onDia,
  onVer,
}: {
  /** El lunes de la semana que se mira. */
  lunes: string
  /** El lunes de la semana en curso. */
  lunesHoy: string
  /** El día elegido en el gráfico, tal como llega de la URL. */
  dia: string | undefined
  ver: VerPorCobrar
  onLunes: (lunes: string) => void
  onDia: (dia: string | null) => void
  onVer: (ver: VerPorCobrar) => void
}) {
  const consulta = usePorCobrar(lunes, ver)
  const enCurso = lunes === lunesHoy
  // Un día de otra semana, en un enlace a medio editar, no filtra nada.
  const elegido = diaDentro(dia, lunes, domingoDe(lunes))

  const controles = (
    <>
      <Segmented etiqueta="Ver" options={OPCIONES_VER} value={ver} onChange={onVer} />
      {/* Hacia delante sin tope: lo que vence la semana que viene es justo una pregunta. */}
      <SelectorDeSemana lunes={lunes} lunesHoy={lunesHoy} onLunes={onLunes} semanasFuturas={4} />
    </>
  )

  const cabecera = {
    titulo: enCurso ? 'Esta semana' : 'La semana elegida',
    info: 'Lo que vence cada día de lunes a domingo, por la fecha de vencimiento de cada cuota. «Por cobrar» enseña lo que sigue sin pagar; «Todo lo que vence», también lo ya cobrado.',
    controles,
  }

  if (consulta.isPending) {
    return (
      <Seccion {...cabecera}>
        {/* La silueta de lo que llega: el titular al lado de cuatro cifras, y el gráfico. */}
        <div className="flex flex-col gap-4">
          <div className="@container">
            <div className="grid gap-4 @4xl:grid-cols-5">
              <SkeletonCard className="@4xl:col-span-2" />
              <SkeletonStats count={4} cols={2} className="@4xl:col-span-3" />
            </div>
          </div>
          <SkeletonBlock className="h-72 w-full" />
        </div>
      </Seccion>
    )
  }

  if (consulta.isError) {
    return (
      <Seccion {...cabecera}>
        <ErrorConReintento
          title="No se pudo leer lo que vence"
          error={consulta.error}
          onReintentar={() => void consulta.refetch()}
        />
      </Seccion>
    )
  }

  const datos = consulta.data
  const vacia = datos.periodo.cuotas === 0

  return (
    <div className="flex flex-col gap-10">
      <Seccion {...cabecera}>
        <div className="flex flex-col gap-4">
          <CifrasDeLaSemana datos={datos} ver={ver} enCurso={enCurso} onVer={onVer} />
          {!vacia && <LoQueVenceCadaDia datos={datos} dia={elegido} onDia={onDia} />}
        </div>
      </Seccion>

      {!vacia && <PorLocal datos={datos} dia={elegido} lunes={lunes} onDia={onDia} />}
    </div>
  )
}
