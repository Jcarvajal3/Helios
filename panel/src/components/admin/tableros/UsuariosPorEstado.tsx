import { Link } from '@tanstack/react-router'

import { SERIE, StackedBar, colorDeTono } from '@/components/charts'
import { VALORES_ESTADO_PERSONA, estadoDePersona } from '@/features/admin/estados'
import { unoDe } from '@/lib/busqueda'

/** Cuántas personas hay en un estado. `estado` es el de la base, tal cual. */
export type PersonasEnEstado = { estado: string; personas: number }

const personas = (n: number) => `${n}`

/**
 * El padrón por estado: una barra al 100 % y, debajo, cada estado con su
 * cuenta, que abre Personas filtrada por él.
 *
 * La leyenda es la de la barra y a la vez la puerta a la lista: por eso se
 * dibuja aquí y no con la de `StackedBar`, que no enlaza. Un estado a cero se
 * queda en la leyenda, apagado: «Expulsados 0» también es un dato.
 */
export function UsuariosPorEstado({ filas }: { filas: ReadonlyArray<PersonasEnEstado> }) {
  const segmentos = filas.map((f) => {
    const visual = estadoDePersona(f.estado)
    return { clave: f.estado, rotulo: visual.plural, valor: f.personas, tono: visual.tone }
  })

  return (
    <div className="flex flex-col gap-3">
      <StackedBar segmentos={segmentos} leyenda={false} formato={personas} rotulo="Pacientes por estado" />

      <ul aria-label="Abrir en Pacientes" className="flex flex-wrap gap-x-4 gap-y-1.5">
        {segmentos.map((s) => (
          <li key={s.clave}>
            <Link
              to="/admin/pacientes"
              search={{ estado: unoDe(VALORES_ESTADO_PERSONA, s.clave) }}
              className={`inline-flex items-center gap-1.5 type-panel-caption underline-offset-2 hover:underline ${
                s.valor > 0 ? 'text-on-surface' : 'text-panel-muted'
              }`}
            >
              <span
                aria-hidden
                className="size-2 shrink-0 rounded-full"
                style={{ backgroundColor: s.valor > 0 ? colorDeTono(s.tono) : SERIE.vacio }}
              />
              {s.rotulo} {s.valor}
            </Link>
          </li>
        ))}
      </ul>
    </div>
  )
}
