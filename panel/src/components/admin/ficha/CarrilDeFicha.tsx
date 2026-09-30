import type { ReactNode } from 'react'

import { Badge, Card, InfoDot, NoSePudoLeer, SkeletonBlock } from '@/components/ui'
import type { EstadoCifra, SenalDeCifra } from '@/components/ui'

/** Una cifra del carril. El número va en blanco; el estado, en la pastilla. */
export type CifraDeFicha = {
  label: string
  value: ReactNode
  /** Qué es y cómo se calcula, en el `InfoDot`. */
  info?: string
  /** Una línea debajo: de cuánto, desde cuándo, por qué. */
  hint?: ReactNode
  /** Solo cuando algo ESTÁ mal o en alerta: «3 días de atraso». */
  senal?: SenalDeCifra
  /** Debajo de la cifra: un `Meter`. */
  visual?: ReactNode
  /** Si la cifra sale de una consulta aparte: nunca un cero que no se ha leído. */
  estado?: EstadoCifra
  onReintentar?: () => void
}

/**
 * Las tres o cuatro cifras que contestan la primera pregunta de la ficha,
 * una debajo de otra en una sola tarjeta.
 *
 * Una tarjeta por cifra, apiladas en 320 px, eran cuatro cajas con cuatro
 * bordes para cuatro números; aquí las separa una raya de un pelo.
 */
export function ResumenDeFicha({
  titulo = 'Resumen',
  info,
  cifras,
  children,
}: {
  titulo?: string
  info?: string
  cifras: ReadonlyArray<CifraDeFicha>
  /** Debajo de las cifras: un enlace a la lista de donde salen. */
  children?: ReactNode
}) {
  return (
    <Card as="section" className="flex flex-col gap-4">
      <TituloDelCarril titulo={titulo} info={info} />
      <dl className="flex flex-col divide-y divide-panel-hairline">
        {cifras.map((c) => (
          <Cifra key={c.label} cifra={c} />
        ))}
      </dl>
      {children}
    </Card>
  )
}

function Cifra({ cifra: c }: { cifra: CifraDeFicha }) {
  const estado = c.estado ?? 'listo'

  return (
    <div className="flex flex-col gap-1.5 py-4 first:pt-0 last:pb-0">
      <dt className="flex items-center gap-1.5 type-panel-label text-on-surface-variant">
        {c.label}
        {c.info && <InfoDot title={c.label} what={c.info} />}
      </dt>
      <dd className="flex min-h-8.5 flex-wrap items-center gap-x-2.5 gap-y-1.5">
        {estado === 'cargando' && <SkeletonBlock className="h-8 w-28" />}
        {estado === 'error' && <NoSePudoLeer onReintentar={c.onReintentar} />}
        {estado === 'listo' && (
          <>
            <span className="type-panel-figure text-on-surface">{c.value}</span>
            {c.senal && (
              <Badge tone={c.senal.tone} icono>
                {c.senal.texto}
              </Badge>
            )}
          </>
        )}
      </dd>
      {estado === 'listo' && c.visual && <dd className="pt-1">{c.visual}</dd>}
      {estado === 'listo' && c.hint && (
        <dd className="type-panel-caption text-panel-muted">{c.hint}</dd>
      )}
    </div>
  )
}

/**
 * Las acciones de todos los días, en el carril. Las destructivas no van
 * aquí: van en el «⋯» de la cabecera.
 *
 * `aviso` es la línea que explica por qué están apagadas (falta de permiso),
 * una vez para todas y no debajo de cada botón.
 */
export function AccionesDeFicha({
  titulo = 'Acciones',
  info,
  aviso,
  children,
}: {
  titulo?: string
  /** Qué hace cada una, en el `InfoDot` del título: los botones no llevan párrafo. */
  info?: string
  aviso?: string
  children: ReactNode
}) {
  return (
    <Card as="section" className="flex flex-col gap-3">
      <TituloDelCarril titulo={titulo} info={info} />
      {aviso && <p className="type-panel-caption text-panel-muted">{aviso}</p>}
      <div className="flex flex-wrap items-start gap-2">{children}</div>
    </Card>
  )
}

/** El rótulo de una tarjeta del carril, con su explicación en el `InfoDot`. */
function TituloDelCarril({ titulo, info }: { titulo: string; info?: string }) {
  return (
    <div className="flex items-center gap-1.5">
      <h2 className="type-panel-label text-on-surface-variant">{titulo}</h2>
      {info && <InfoDot title={titulo} what={info} />}
    </div>
  )
}
