/** Preguntas de ejemplo: se pulsan y se mandan tal cual. */
export const SUGERENCIAS = [
  '¿Cuánto se cobró esta semana?',
  '¿Qué clínicas tienen más mora?',
  'Resume el día de ayer',
] as const

/**
 * Las sugerencias en píldora, para una conversación vacía: la del cajón y la
 * barra de Inicio. Enseñan qué se puede preguntar sin un párrafo que lo
 * explique.
 */
export function SugerenciasDelAsistente({
  onElegir,
  className = '',
}: {
  onElegir: (texto: string) => void
  /** Para alinearlas: a la izquierda en el cajón, centradas en Inicio. */
  className?: string
}) {
  return (
    <ul aria-label="Preguntas de ejemplo" className={`flex flex-wrap gap-2 ${className}`}>
      {SUGERENCIAS.map((s) => (
        <li key={s}>
          <button
            type="button"
            onClick={() => onElegir(s)}
            className="inline-flex h-panel-control-sm items-center rounded-full border border-panel-hairline bg-panel-card px-3.5 type-panel-label text-on-surface-variant transition-colors duration-[var(--transition-fast)] hover:bg-panel-raised hover:text-on-surface"
          >
            {s}
          </button>
        </li>
      ))}
    </ul>
  )
}
