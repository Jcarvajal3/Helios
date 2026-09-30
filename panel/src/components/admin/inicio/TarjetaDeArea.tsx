import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { ArrowRight } from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

import { Badge, Card, IconoDeArea, InfoDot, NoSePudoLeer, SkeletonBlock } from '@/components/ui'
import type { EstadoCifra, SenalDeCifra } from '@/components/ui'
import type { Ambito, Destino } from '@/features/admin/catalogo'

/**
 * Una tarjeta de «Hoy en cifras»: UNA cifra de un área, con su forma.
 *
 * La anatomía es la de `Stat` con el icono del área delante del rótulo: el
 * número en blanco, la pastilla al lado (solo con color si cruza un umbral),
 * la forma debajo o a la derecha y un pie de una línea. La tarjeta entera
 * lleva a la pantalla del área: el rótulo es el enlace y su `::after` la
 * cubre, así el `InfoDot` y «Reintentar» siguen pulsándose sin navegar.
 */
export function TarjetaDeArea({
  area,
  icono,
  rotulo,
  info,
  destino,
  estado,
  onReintentar,
  valor,
  senal,
  visual,
  lateral,
  pie,
}: {
  area: Ambito
  icono: LucideIcon
  rotulo: string
  /** Qué es la cifra y cómo se calcula, en el `InfoDot` del rótulo. */
  info?: string
  destino: Destino
  estado: EstadoCifra
  onReintentar?: () => void
  /** La cifra ya formateada. Solo se pinta lista. */
  valor: string
  senal?: SenalDeCifra
  /** Debajo de la cifra, pegado al pie: un `Meter`, unas `MiniBarras`. */
  visual?: ReactNode
  /** A la derecha de la cifra: un `Ring`. */
  lateral?: ReactNode
  pie?: ReactNode
}) {
  const listo = estado === 'listo'

  const pastilla = senal && (
    <Badge tone={senal.tone} icono>
      {senal.texto}
    </Badge>
  )
  const cifra = <p className="type-panel-figure text-on-surface">{valor}</p>

  return (
    <Card
      as="article"
      area={area}
      className="group/tarjeta relative flex h-full min-h-42.5 flex-col gap-2 transition-colors duration-(--transition-fast) hover:border-panel-hairline-strong hover:bg-panel-raised motion-reduce:transition-none"
    >
      <div className="flex min-w-0 items-center gap-2.5">
        <IconoDeArea icon={icono} tamano="sm" />
        <h3 className="min-w-0 truncate type-panel-label text-on-surface-variant transition-colors group-hover/tarjeta:text-on-surface">
          <Link
            {...destino}
            // El anillo de foco lo lleva el `::after`, que mide la tarjeta
            // entera; en línea porque el anillo global va sin capa y ganaría.
            style={{ outline: 'none' }}
            className="after:absolute after:inset-0 after:rounded-panel-card focus-visible:after:ring-2 focus-visible:after:ring-primary"
          >
            {rotulo}
          </Link>
        </h3>
        {info && (
          <span className="relative z-10 inline-flex opacity-60 transition-opacity duration-(--transition-fast) group-hover/tarjeta:opacity-100 focus-within:opacity-100 motion-reduce:transition-none">
            <InfoDot title={rotulo} what={info} />
          </span>
        )}
        <ArrowRight
          size={15}
          aria-hidden
          className="ml-auto shrink-0 text-on-surface-variant opacity-0 transition-opacity duration-(--transition-fast) group-hover/tarjeta:opacity-100 group-focus-within/tarjeta:opacity-100 motion-reduce:transition-none"
        />
      </div>

      {estado === 'cargando' && <SkeletonBlock className="h-8.5 w-28" />}
      {estado === 'error' && <NoSePudoLeer onReintentar={onReintentar} className="relative z-10" />}

      {listo &&
        (lateral ? (
          <div className="flex flex-1 items-center gap-3">
            <div className="flex min-w-0 flex-1 flex-col items-start gap-2">
              {cifra}
              {pastilla}
            </div>
            <div className="shrink-0">{lateral}</div>
          </div>
        ) : (
          <div className="flex flex-wrap items-center gap-x-2.5 gap-y-1.5">
            {cifra}
            {pastilla}
          </div>
        ))}

      {listo && visual && <div className="mt-auto pt-1">{visual}</div>}
      {listo && pie && (
        <p className={`truncate type-panel-caption text-panel-muted ${visual || lateral ? '' : 'mt-auto'}`}>
          {pie}
        </p>
      )}
    </Card>
  )
}
