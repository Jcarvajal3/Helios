import { useId } from 'react'
import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { ArrowRight, Check, CircleHelp, Clock, Play, TriangleAlert } from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

import { Badge, Button, IconoDeArea, NoSePudoLeer, claseDeBoton } from '@/components/ui'
import type { BadgeTone } from '@/components/ui'
import { pantalla } from '@/features/admin/catalogo'
import type { Ambito } from '@/features/admin/catalogo'
import { tonoDeAmbito } from '@/features/admin/areas'
import { rotuloDeEspacio } from '@/features/admin/espacios'
import type { Bloqueo } from './bloqueos'
import type { Plazo } from './colas'
import type { TarjetaDePendiente } from './tarjetasDePendiente'
import type { ColaDeInicio } from './useColas'

/** La pastilla de cada plazo. Lo de hoy avisa; lo que puede esperar no es un estado. */
const PLAZO: Record<Plazo, { tono: BadgeTone; texto: string; icono: boolean | LucideIcon }> = {
  pasado: { tono: 'error', texto: 'Vencido', icono: true },
  hoy: { tono: 'warning', texto: 'Para hoy', icono: Clock },
  puede_esperar: { tono: 'neutral', texto: 'Puede esperar', icono: false },
}

/**
 * La caja de una tarjeta de «Pendiente». Un `article` y no `Card` porque el
 * bloqueo cambia el color del borde, y dos colores de borde en la misma clase
 * no se pisan de forma fiable.
 */
function Marco({
  area,
  error = false,
  children,
}: {
  /** El área de la cola: su icono toma ese tono. */
  area?: Ambito
  error?: boolean
  children: ReactNode
}) {
  return (
    <article
      data-area={area}
      className={`flex h-full min-h-44 flex-col gap-2.5 rounded-panel-card border bg-panel-card p-panel-pad-card ${
        error ? 'border-error/40' : 'border-panel-hairline'
      }`}
    >
      {children}
    </article>
  )
}

/** El icono y el nombre del área de una cola, que salen de su pantalla del catálogo. */
function AreaDeLaCola({ cola, derecha }: { cola: ColaDeInicio; derecha?: ReactNode }) {
  const p = pantalla(cola.pantalla)
  const tono = tonoDeAmbito(p.espacio)
  return (
    <div className="flex min-w-0 items-center gap-2.5">
      <IconoDeArea icon={p.icono} tamano="sm" />
      <span className="min-w-0 truncate type-panel-caption font-semibold text-on-surface-variant">
        {tono === 'neutro' ? p.titulo : rotuloDeEspacio(tono)}
      </span>
      {derecha && <span className="ml-auto shrink-0">{derecha}</span>}
    </div>
  )
}

/** Lo que impide operar: contorno rojo, qué pasa, por qué, y adónde ir a arreglarlo. */
function TarjetaDeBloqueo({ bloqueo, principal }: { bloqueo: Bloqueo; principal: boolean }) {
  const id = useId()
  return (
    <Marco error>
      <div className="flex items-center gap-2.5">
        <IconoDeArea icon={TriangleAlert} tamano="sm" tone="error" />
        <span className="type-panel-caption font-bold text-panel-critico">Bloquea la operación</span>
      </div>
      <h3 id={id} className="text-balance type-panel-body font-semibold text-on-surface">
        {bloqueo.texto}
      </h3>
      <p className="line-clamp-2 type-panel-label font-normal text-panel-muted">{bloqueo.detalle}</p>
      <Link
        {...bloqueo.arreglo.destino}
        aria-describedby={id}
        className={`${claseDeBoton(principal ? 'filled' : 'tonal', 'sm')} mt-auto self-start`}
      >
        Arreglar
        <span className="sr-only">: {bloqueo.arreglo.rotulo}</span>
        <ArrowRight size={14} aria-hidden />
      </Link>
    </Marco>
  )
}

/** Una cola con trabajo, o que no se pudo leer. */
function TarjetaDeCola({ cola, principal }: { cola: ColaDeInicio; principal: boolean }) {
  const { lectura } = cola
  const area = pantalla(cola.pantalla).espacio

  if (lectura.estado !== 'listo') {
    return (
      <Marco area={area}>
        <AreaDeLaCola cola={cola} />
        <h3 className="type-panel-body font-semibold text-on-surface">{cola.nombre}</h3>
        {lectura.estado === 'error' && <NoSePudoLeer onReintentar={lectura.reintentar} className="mt-auto" />}
      </Marco>
    )
  }

  const { resumen } = lectura
  const plazo = PLAZO[resumen.plazo]

  return (
    <Marco area={area}>
      <AreaDeLaCola
        cola={cola}
        derecha={
          <Badge tone={plazo.tono} icono={plazo.icono}>
            {plazo.texto}
          </Badge>
        }
      />
      <div className="flex min-w-0 items-baseline gap-2.5">
        <span className="type-panel-figure text-on-surface">
          {resumen.cantidad}
          {resumen.alTope && '+'}
        </span>
        <h3 className="min-w-0 type-panel-body font-semibold text-on-surface">{cola.nombre}</h3>
      </div>
      {resumen.detalle && (
        <p title={resumen.detalle} className="truncate type-panel-label font-normal text-panel-muted">
          {resumen.detalle}
        </p>
      )}
      <Button
        size="sm"
        variant={principal ? 'filled' : 'tonal'}
        className="mt-auto self-start"
        onClick={() => cola.empezar(resumen)}
      >
        <Play size={14} aria-hidden />
        Empezar
        <span className="sr-only">: {cola.nombre}</span>
      </Button>
    </Marco>
  )
}

/** Una comprobación de bloqueo que no se pudo hacer: puede esconder uno. */
function TarjetaSinComprobar({ que, reintentar }: { que: string; reintentar: () => void }) {
  return (
    <Marco>
      <div className="flex items-center gap-2.5">
        <IconoDeArea icon={CircleHelp} tamano="sm" tone="neutral" />
        <span className="type-panel-caption font-semibold text-on-surface-variant">Sin comprobar</span>
      </div>
      <h3 className="type-panel-body font-semibold text-on-surface">{que}</h3>
      <NoSePudoLeer onReintentar={reintentar} className="mt-auto" />
    </Marco>
  )
}

/** Una tarjeta de «Pendiente». `principal`: la primera con botón, la única en lima. */
export function TarjetaPendiente({
  tarjeta,
  principal,
}: {
  tarjeta: TarjetaDePendiente<ColaDeInicio>
  principal: boolean
}) {
  switch (tarjeta.tipo) {
    case 'bloqueo':
      return <TarjetaDeBloqueo bloqueo={tarjeta.bloqueo} principal={principal} />
    case 'cola':
      return <TarjetaDeCola cola={tarjeta.cola} principal={principal} />
    case 'sin-comprobar':
      return <TarjetaSinComprobar que={tarjeta.que} reintentar={tarjeta.reintentar} />
  }
}

/** Sin nada que hacer: una sola tarjeta tranquila, en verde. */
export function TarjetaAlDia() {
  return (
    <Marco>
      <IconoDeArea icon={Check} tamano="sm" tone="success" />
      <h3 className="type-panel-body font-semibold text-on-surface">Todo al día</h3>
      <p className="type-panel-label font-normal text-panel-muted">
        Ninguna cola tiene trabajo esperando y nada bloquea la operación.
      </p>
    </Marco>
  )
}
