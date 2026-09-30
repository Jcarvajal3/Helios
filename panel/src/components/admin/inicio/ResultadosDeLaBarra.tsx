import { siNoHayNadaDelAsistente } from '@/components/admin/asistente'
import { GrupoPaleta } from '@/components/admin/paleta/GrupoPaleta'
import type { EstadoPaleta } from '@/components/admin/paleta/usePaleta'

/**
 * Lo que encuentra la barra de Inicio, debajo de ella: los mismos grupos y
 * las mismas opciones que la paleta (Ctrl K), con «Preguntarle al asistente»
 * el primero cuando lo escrito parece una pregunta.
 *
 * Las opciones no se llevan el foco: se sigue escribiendo en la barra y la
 * señalada se anuncia con `aria-activedescendant`, como en la paleta.
 */
export function ResultadosDeLaBarra({
  paleta: p,
  idBase,
  idLista,
  idDe,
  conAsistente,
}: {
  paleta: EstadoPaleta
  /** Si lo que no se encuentra se le puede preguntar al asistente. */
  conAsistente: boolean
  idBase: string
  idLista: string
  /** El id del DOM de cada opción, el que señala la barra. */
  idDe: (clave: string) => string
}) {
  return (
    <>
      <div id={idLista} role="listbox" aria-label="Resultados" className="max-h-80 overflow-y-auto p-1.5">
        {p.grupos.map((grupo) => (
          <GrupoPaleta
            key={grupo.id}
            grupo={grupo}
            idBase={idBase}
            idDe={idDe}
            activa={p.activa?.clave ?? null}
            desplegada={p.desplegada}
            onSenalar={p.senalar}
            onElegir={p.elegir}
          />
        ))}
      </div>

      {p.vacia && (
        <div className="border-t border-panel-hairline px-4 py-3">
          <p className="type-panel-body text-on-surface">Nada con «{p.consulta.texto}».</p>
          {conAsistente && siNoHayNadaDelAsistente(p.consulta)}
        </div>
      )}
    </>
  )
}
