import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ExternalLink } from 'lucide-react'

import { useToast } from '@/components/Toast'
import { Badge, Button, Spinner } from '@/components/ui'
import { CLAVE_LAB, enlaceDeLaCaptura, esPdf, mensajeDeError } from '@/features/lab/admin'
import { ROTULO_ESTADO, ROTULO_PAGO, TONO_ESTADO, TONO_PAGO } from '@/features/lab/tipos'
import type { EstadoMuestra, EstadoPago } from '@/features/lab/tipos'

export function InsigniaEstado({ estado }: { estado: EstadoMuestra }) {
  return (
    <Badge tone={TONO_ESTADO[estado]} icono>
      {ROTULO_ESTADO[estado]}
    </Badge>
  )
}

export function InsigniaPago({ pago }: { pago: EstadoPago }) {
  return (
    <Badge tone={TONO_PAGO[pago]} icono>
      {ROTULO_PAGO[pago]}
    </Badge>
  )
}

/**
 * Una escritura del equipo: al terminar avisa, refresca todo Lab y deja el
 * error ya en castellano en `mensaje`.
 */
export function useEscritura<TVariables>(fn: (v: TVariables) => Promise<unknown>, ok: string, alTerminar?: () => void) {
  const qc = useQueryClient()
  const avisar = useToast()
  const m = useMutation({
    mutationFn: fn,
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: CLAVE_LAB })
      avisar(ok)
      alTerminar?.()
    },
  })
  return { ...m, mensaje: m.isError ? mensajeDeError(m.error) : undefined }
}

/** La captura del pago, con enlace firmado: imagen que se abre grande, o PDF. */
export function Captura({ ruta, compacta = false }: { ruta: string; compacta?: boolean }) {
  const q = useQuery({
    queryKey: [...CLAVE_LAB, 'captura', ruta],
    queryFn: () => enlaceDeLaCaptura(ruta),
    staleTime: 5 * 60_000,
  })

  if (q.isPending) return <Spinner />
  if (q.isError) return <span className="type-panel-caption text-error">No se pudo abrir la captura.</span>

  const url = q.data
  if (compacta || esPdf(ruta)) {
    return (
      <a href={url} target="_blank" rel="noreferrer" className="inline-flex">
        <Button size="sm" variant="outlined">
          <ExternalLink size={14} aria-hidden />
          {esPdf(ruta) ? 'Abrir PDF' : 'Ver captura'}
        </Button>
      </a>
    )
  }
  return (
    <a href={url} target="_blank" rel="noreferrer" className="block">
      <img
        src={url}
        alt="Captura del Pago Móvil"
        className="max-h-80 w-auto max-w-full rounded-panel-control border border-panel-hairline object-contain"
      />
    </a>
  )
}

/** «Anterior · Página 2 de 5 · Siguiente». */
export function Paginacion({
  pagina,
  total,
  porPagina,
  onPagina,
}: {
  pagina: number
  total: number
  porPagina: number
  onPagina: (p: number) => void
}) {
  const paginas = Math.max(1, Math.ceil(total / porPagina))
  if (paginas <= 1) return null
  return (
    <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
      <span className="type-panel-caption text-panel-muted">{total.toLocaleString('es-VE')} en total</span>
      <div className="flex items-center gap-2">
        <Button size="sm" variant="outlined" disabled={pagina <= 1} onClick={() => onPagina(pagina - 1)}>
          Anterior
        </Button>
        <span className="type-panel-body tabular-nums">
          Página {pagina} de {paginas}
        </span>
        <Button size="sm" variant="outlined" disabled={pagina >= paginas} onClick={() => onPagina(pagina + 1)}>
          Siguiente
        </Button>
      </div>
    </div>
  )
}
