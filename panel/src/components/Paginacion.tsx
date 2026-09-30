import { ChevronLeft, ChevronRight } from 'lucide-react'

import { Button } from '@/components/ui'

/** '1 a 50 de 312', con los miles a la venezolana. */
export function rangoDePagina(pagina: number, porPagina: number, total: number): string {
  if (total === 0) return '0 de 0'
  const primera = (pagina - 1) * porPagina + 1
  const ultima = Math.min(pagina * porPagina, total)
  const n = (x: number) => x.toLocaleString('es-VE')
  return `${n(primera)} a ${n(ultima)} de ${n(total)}`
}

/** Cuántas páginas hacen falta para `total` filas. Nunca menos de una. */
export function paginasDe(total: number, porPagina: number): number {
  return Math.max(1, Math.ceil(total / porPagina))
}

/**
 * Las flechas de una lista que pagina en el servidor: «‹ Anterior · Página 2
 * de 7 · Siguiente ›». La página va en la URL (`?pagina=`), así que el enlace
 * que se pega en un chat abre la misma página, y la 1 no se escribe.
 *
 * Con una sola página no se pinta: dos botones apagados solo ocupan sitio.
 */
export function Paginacion({
  pagina,
  porPagina,
  total,
  onPagina,
}: {
  /** Desde 1. */
  pagina: number
  porPagina: number
  total: number
  onPagina: (pagina: number) => void
}) {
  const paginas = paginasDe(total, porPagina)
  if (paginas <= 1 && pagina <= 1) return null

  return (
    <nav aria-label="Páginas" className="mt-4 flex flex-wrap items-center justify-end gap-3">
      <span className="type-panel-caption text-panel-muted">
        Página {pagina.toLocaleString('es-VE')} de {paginas.toLocaleString('es-VE')}
      </span>
      <div className="flex gap-2">
        <Button size="sm" variant="tonal" disabled={pagina <= 1} onClick={() => onPagina(pagina - 1)}>
          <ChevronLeft size={14} aria-hidden /> Anterior
        </Button>
        <Button
          size="sm"
          variant="tonal"
          disabled={pagina >= paginas}
          onClick={() => onPagina(pagina + 1)}
        >
          Siguiente <ChevronRight size={14} aria-hidden />
        </Button>
      </div>
    </nav>
  )
}
