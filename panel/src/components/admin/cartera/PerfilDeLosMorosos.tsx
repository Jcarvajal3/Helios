import { useQuery } from '@tanstack/react-query'

import { ErrorConReintento } from '@/components/admin/ErrorConReintento'
import { SERIE } from '@/components/charts'
import { MarcaConGlobo } from '@/components/charts/lectura'
import { InfoDot, SkeletonBlock, formatNumero } from '@/components/ui'
import { consultaPerfilDeMorosos } from '@/features/admin/cobranza/consultas'
import { filasDeRasgos } from '@/features/admin/cobranza/perfilDeMorosos'
import type { CeldaDeRasgo, PerfilDeMorosos } from '@/features/admin/cobranza/perfilDeMorosos'

/** Quien debe, en ámbar (algo está pendiente); quien está al día, en el tono del área. */
const COLOR_MOROSOS = 'var(--color-warning)'
const COLOR_AL_DIA = SERIE.principal

/**
 * Cómo es la gente que debe algo vencido, frente a la que ya tuvo que pagar y
 * está al día: los mismos rasgos en dos columnas (edad, sexo, teléfono,
 * antigüedad, grupo, avisos, consumo, nivel y ciudad), de todas las semanas y
 * locales. Lo que se parece no dice nada; lo que se separa es lo que
 * distingue a quien no paga. Los porcentajes llevan barra para que la
 * diferencia se vea sin leer las cifras.
 */
export function PerfilDeLosMorosos() {
  const perfil = useQuery(consultaPerfilDeMorosos())

  return (
    <section aria-labelledby="perfil-morosos" className="flex flex-col gap-3">
      <div className="flex items-center gap-2">
        <h3 id="perfil-morosos" className="type-panel-section text-on-surface">
          Cómo es quien debe
        </h3>
        <span className="inline-flex opacity-60 hover:opacity-100">
          <InfoDot
            title="Cómo es quien debe"
            what="Quien debe algo vencido hoy frente a quien ya tuvo que pagar alguna cuota y está al día, de todas las semanas y todas las clínicas. Cada porcentaje va sobre quien tiene ese dato."
          />
        </span>
      </div>

      {perfil.isError ? (
        <ErrorConReintento
          title="No se pudo leer el perfil de quien debe"
          error={perfil.error}
          onReintentar={() => void perfil.refetch()}
        />
      ) : !perfil.data ? (
        <SkeletonBlock aria-hidden className="h-96 w-full rounded-panel-card" />
      ) : (
        <TablaDePerfil perfil={perfil.data} />
      )}
    </section>
  )
}

function TablaDePerfil({ perfil: p }: { perfil: PerfilDeMorosos }) {
  const morosos = p.morosos?.personas ?? 0
  const alDia = p.alDia?.personas ?? 0
  const filas = filasDeRasgos(p)

  return (
    <article className="flex flex-col gap-3 rounded-panel-card border border-panel-hairline bg-panel-card p-panel-pad-card">
      {p.morosos && p.morosos.atrasoMedioDias !== null && (
        <p className="type-panel-caption text-panel-muted">
          {formatNumero(p.morosos.atrasoMedioDias, 1)} días de atraso de media entre quien debe
        </p>
      )}

      <table className="w-full border-collapse tabular-nums">
        <caption className="sr-only">Los rasgos de quien debe algo vencido frente a quien está al día</caption>
        <thead>
          <tr>
            <th scope="col" className="w-[36%] pb-2 text-left type-panel-caption font-normal text-panel-muted">
              <span className="sr-only">Rasgo</span>
            </th>
            <th scope="col" className="pb-2 pl-2 text-left type-panel-caption font-bold text-on-surface">
              <span className="inline-flex items-center gap-1.5">
                <span aria-hidden className="size-2 rounded-[3px]" style={{ backgroundColor: COLOR_MOROSOS }} />
                Morosos · {morosos}
              </span>
            </th>
            <th scope="col" className="pb-2 pl-2 text-left type-panel-caption font-bold text-on-surface">
              <span className="inline-flex items-center gap-1.5">
                <span aria-hidden className="size-2 rounded-[3px]" style={{ backgroundColor: COLOR_AL_DIA }} />
                Al día · {alDia}
              </span>
            </th>
          </tr>
        </thead>
        <tbody>
          {filas.map((f) => (
            <tr key={f.clave} className="border-t border-panel-hairline align-top">
              <th scope="row" className="py-2 pr-2 text-left font-normal">
                <MarcaConGlobo
                  titulo={f.rotulo}
                  filas={[]}
                  nota={f.ayuda}
                  className="type-panel-caption text-on-surface-variant underline decoration-panel-hairline-strong decoration-dotted underline-offset-4 outline-none focus-visible:ring-2 focus-visible:ring-primary"
                >
                  {f.rotulo}
                </MarcaConGlobo>
              </th>
              <td className="py-2 pl-2">
                <Celda celda={f.morosos} color={COLOR_MOROSOS} vacio={morosos === 0 ? 'Nadie debe' : 'Sin dato'} />
              </td>
              <td className="py-2 pl-2">
                <Celda celda={f.alDia} color={COLOR_AL_DIA} vacio={alDia === 0 ? 'Nadie al día' : 'Sin dato'} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </article>
  )
}

function Celda({ celda, color, vacio }: { celda: CeldaDeRasgo; color: string; vacio: string }) {
  if (celda === null) return <span className="type-panel-caption text-panel-muted">{vacio}</span>
  return (
    <span className="flex flex-col gap-1">
      <span className="type-panel-body text-on-surface">{celda.texto}</span>
      {celda.pct !== null && (
        <span aria-hidden className="h-1.5 w-full overflow-hidden rounded-full" style={{ backgroundColor: SERIE.vacio }}>
          <span
            className="block h-full rounded-full"
            style={{ width: `${Math.min(Math.max(celda.pct, 0), 100)}%`, backgroundColor: color }}
          />
        </span>
      )}
    </span>
  )
}
