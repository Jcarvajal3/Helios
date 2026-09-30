import { OpcionPaleta } from './OpcionPaleta'
import type { Grupo } from './grupos'
import type { Opcion } from './opciones'

/**
 * Un grupo de resultados: su rótulo, su estado y sus opciones.
 *
 * Mientras espera al servidor pinta una sola línea discreta, «Buscando…»; si
 * falló, su única opción es el aviso, que se elige para reintentar. Un grupo
 * nunca se queda en blanco sin decir por qué.
 */
export function GrupoPaleta({
  grupo,
  idBase,
  idDe,
  activa,
  desplegada,
  onSenalar,
  onElegir,
}: {
  grupo: Grupo
  idBase: string
  /** El id del DOM de cada opción, para `aria-activedescendant`. */
  idDe: (clave: string) => string
  activa: string | null
  desplegada: string | null
  onSenalar: (clave: string) => void
  onElegir: (opcion: Opcion, nuevaPestana: boolean) => void
}) {
  const idRotulo = `${idBase}-grupo-${grupo.id}`

  return (
    <div role="group" aria-labelledby={idRotulo} className="py-1">
      {/* Oculto al lector: ya lo lee como nombre del grupo. */}
      <div
        id={idRotulo}
        aria-hidden
        className="px-3 pb-1 pt-2 type-panel-label text-on-surface-variant"
      >
        {grupo.titulo}
      </div>

      {grupo.estado === 'cargando' && (
        <div
          role="option"
          aria-selected={false}
          aria-disabled
          className="px-3 py-2 type-panel-body text-panel-muted"
        >
          Buscando…
        </div>
      )}

      {grupo.opciones.map((opcion) => (
        <OpcionPaleta
          key={opcion.clave}
          opcion={opcion}
          id={idDe(opcion.clave)}
          activa={opcion.clave === activa}
          desplegada={opcion.clave === desplegada}
          onSenalar={onSenalar}
          onElegir={onElegir}
        />
      ))}
    </div>
  )
}
