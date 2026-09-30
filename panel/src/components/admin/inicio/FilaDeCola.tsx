import { Link } from '@tanstack/react-router'
import { Play } from 'lucide-react'

import { Button, NoSePudoLeer, SkeletonBlock } from '@/components/ui'
import type { Plazo } from './colas'
import type { ColaDeInicio } from './useColas'

const PUNTO: Record<Plazo, { clase: string; texto: string }> = {
  pasado: { clase: 'bg-error', texto: 'Plazo pasado' },
  hoy: { clase: 'bg-warning', texto: 'Para hoy' },
  puede_esperar: { clase: 'bg-on-surface-variant', texto: 'Puede esperar' },
}

/** El punto del plazo. Hueco si la cola está vacía, cargando o sin leer. */
function Punto({ plazo }: { plazo: Plazo | null }) {
  if (!plazo) {
    return <span aria-hidden className="size-2.5 shrink-0 rounded-full border border-outline" />
  }
  return (
    <>
      <span aria-hidden title={PUNTO[plazo].texto} className={`size-2.5 shrink-0 rounded-full ${PUNTO[plazo].clase}`} />
      <span className="sr-only">{PUNTO[plazo].texto}.</span>
    </>
  )
}

/**
 * Una cola: el punto de su plazo, el nombre y la cantidad (que llevan a la
 * lista ya filtrada), el dato que urge y «Empezar». Vacía, se apaga y dice
 * «Nada esperando»; sin leer, lo dice y ofrece reintentar, nunca un cero.
 *
 * `principal` es la primera con trabajo: la única con el botón en lima.
 */
export function FilaDeCola({ cola, principal }: { cola: ColaDeInicio; principal: boolean }) {
  const { lectura } = cola
  const resumen = lectura.estado === 'listo' ? lectura.resumen : null
  const conTrabajo = resumen !== null && resumen.cantidad > 0

  return (
    <li className="flex flex-wrap items-center gap-x-6 gap-y-2 py-3">
      <Link
        {...cola.lista}
        // El lima es de la acción principal: el enlace se subraya al pasar.
        className={`flex min-w-0 flex-1 basis-60 items-baseline justify-between gap-3 rounded-panel-control underline-offset-4 outline-none transition-colors hover:underline focus-visible:ring-2 focus-visible:ring-primary/70 sm:max-w-80 ${
          conTrabajo ? 'text-on-surface' : 'text-on-surface-variant'
        }`}
      >
        <span className="flex min-w-0 items-center gap-3 self-center type-panel-control">
          <Punto plazo={conTrabajo ? resumen.plazo : null} />
          <span className="truncate">{cola.nombre}</span>
        </span>
        {lectura.estado === 'cargando' && <SkeletonBlock className="h-6 w-10" />}
        {conTrabajo && (
          <span className="type-panel-figure tabular-nums">
            {resumen.cantidad}
            {resumen.alTope && '+'}
          </span>
        )}
      </Link>

      <div className="min-w-0 flex-2 basis-72 type-panel-body text-on-surface-variant">
        {lectura.estado === 'error' && <NoSePudoLeer onReintentar={lectura.reintentar} />}
        {lectura.estado === 'cargando' && <SkeletonBlock className="h-4 w-48" />}
        {resumen && (conTrabajo ? resumen.detalle : 'Nada esperando')}
      </div>

      {conTrabajo && (
        <Button size="sm" variant={principal ? 'filled' : 'tonal'} onClick={() => cola.empezar(resumen)}>
          <Play size={14} aria-hidden /> Empezar
        </Button>
      )}
    </li>
  )
}
