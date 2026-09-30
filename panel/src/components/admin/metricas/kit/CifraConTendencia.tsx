import type { ReactNode } from 'react'
import type { RegisteredRouter, ValidateLinkOptions } from '@tanstack/react-router'

import { DataLabel, InfoDot, Stat } from '@/components/ui'
import type { EstadoCifra, SenalDeCifra } from '@/components/ui'
import { comoTendencia } from '@/features/admin/metricas/formato'
import type { Delta } from '@/features/admin/metricas/formato'
import { Chispa } from './Chispa'
import type { ChispaProps } from './Chispa'
import { NoSeParte } from './NoSeParte'

export type CifraConTendenciaProps<
  TRouter extends RegisteredRouter = RegisteredRouter,
  TOptions = unknown,
> = {
  titulo: string
  /** La cifra ya escrita («€912,40», «81 %»). Solo se pinta con `estado` en `listo`. */
  valor: string
  /**
   * El cambio frente a la semana anterior (a la misma altura si la elegida
   * está en curso), hecho con `delta()` de `features/admin/metricas/formato`.
   * Va en una pastilla al lado de la cifra: verde si es buena noticia, roja si
   * es mala y gris si no es ninguna de las dos.
   */
  delta?: Delta | null
  /**
   * La pastilla de estado, SOLO si la cifra cruza un `umbral_*` de
   * `business_parameters` (`senalPorUmbral` de `features/admin/umbrales`).
   */
  senal?: SenalDeCifra
  /** Una línea debajo: «Meta semanal €1.000 · va al 91 %», o el desglose de una cuota. */
  pie?: ReactNode
  /** Las N semanas de la cifra en barras mínimas; la elegida en el tono del área. */
  chispa?: Omit<ChispaProps, 'alto'>
  /** Qué es la cifra y cómo se calcula, en el `InfoDot` del título. */
  info?: string
  /**
   * Adónde lleva la tarjeta entera: la pestaña o la pantalla que la explica.
   * Tipado como un `<Link>`, igual que el `link` de `Stat`:
   * `{ to: '/admin/metricas', search: { vista: 'mora' } }`.
   */
  link?: ValidateLinkOptions<TRouter, TOptions>
  /** `cargando`: esqueleto. `error`: «No se pudo leer» con «Reintentar». Nunca un cero. */
  estado?: EstadoCifra
  onReintentar?: () => void
  /**
   * La cifra no se parte por el local elegido: en su lugar va `NoSeParte`,
   * nunca un cero. Con texto, es el motivo.
   */
  noSeParte?: boolean | string
}

/**
 * Una cifra de Métricas: el `Stat` del panel con el cambio frente a la
 * semana anterior y la chispa de las últimas semanas.
 *
 * Es la tarjeta de la maqueta (título, cifra, cambio, una línea y la chispa),
 * con la anatomía de todas las cifras del panel: el número en blanco, la
 * pastilla de estado solo al cruzar un umbral y el `InfoDot` atenuado. Con
 * `link`, la tarjeta entera es un enlace.
 */
export function CifraConTendencia<TRouter extends RegisteredRouter, TOptions>({
  titulo,
  valor,
  delta,
  senal,
  pie,
  chispa,
  info,
  link,
  estado = 'listo',
  onReintentar,
  noSeParte = false,
}: CifraConTendenciaProps<TRouter, TOptions>): ReactNode {
  if (noSeParte !== false) {
    return (
      <SinPartir titulo={titulo} info={info} motivo={typeof noSeParte === 'string' ? noSeParte : undefined} />
    )
  }

  return (
    // Con los mismos parámetros de tipo: así el enlace se valida contra las
    // rutas en quien llama, como en un `Stat` directo.
    <Stat<TRouter, TOptions>
      label={titulo}
      value={valor}
      trend={delta ? comoTendencia(delta) : undefined}
      senal={senal}
      hint={pie}
      visual={chispa ? <Chispa {...chispa} /> : undefined}
      info={info}
      link={link}
      estado={estado}
      onReintentar={onReintentar}
    />
  )
}

/**
 * La tarjeta de una cifra que no se parte por local: la misma caja y el
 * mismo título que un `Stat`, y `NoSeParte` donde iría el número. Sin enlace:
 * no hay nada de ese local que ir a ver.
 */
function SinPartir({ titulo, info, motivo }: { titulo: string; info?: string; motivo?: string }) {
  return (
    <div className="flex h-full flex-col gap-2 rounded-panel-card border border-panel-hairline bg-panel-card p-panel-pad-card">
      <div className="flex min-w-0 items-center gap-1.5">
        <DataLabel className="min-w-0">{titulo}</DataLabel>
        {info && (
          <span className="inline-flex opacity-60">
            <InfoDot title={titulo} what={info} />
          </span>
        )}
      </div>
      <div className="flex min-h-8.5 items-center">
        <NoSeParte motivo={motivo} />
      </div>
    </div>
  )
}
