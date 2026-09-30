import type { SiNoHayNada } from '@/components/admin/paleta'

/**
 * Lo que la paleta dice debajo de «Nada con…» cuando hay asistente: que lo
 * tecleado se le puede preguntar. La opción para hacerlo ya está en la lista,
 * así que Enter la elige sin mover nada.
 */
export const siNoHayNadaDelAsistente: SiNoHayNada = () => (
  <p className="mt-2 type-panel-caption text-panel-muted">
    Pulsa Enter para preguntárselo al asistente.
  </p>
)
