import { Equal, Plus } from 'lucide-react'

import { CifraConTendencia } from '@/components/admin/metricas/kit'
import type { EstadoCifra } from '@/components/ui'
import {
  CIFRAS_DEL_DESGLOSE,
  CIFRAS_QUE_CUENTAN,
  TITULOS_DEL_RESUMEN,
} from '@/features/admin/metricas/semana/resumen/cifras'
import type { CifraDelResumen, IdCifraResumen } from '@/features/admin/metricas/semana/resumen/cifras'

/**
 * Las cinco cifras de la semana, en dos filas:
 *
 *   [Total facturado (sin fee)]  +  [Service fee + IVA]  =  [Total a cobrar]
 *   (el total a cobrar no dice «+ fee» en su título: sus dos sumandos están
 *   a su izquierda, con los signos)
 *   [Consumos]  [Usuarios que consumieron]
 *
 * La primera es un desglose que suma y se lee como tal: los signos van entre
 * las tarjetas, y el total a cobrar (que lleva el fee dentro) nunca aparece
 * sin sus dos sumandos al lado. En fila desde 50rem, cuando cada tarjeta
 * pasa de ~15rem y el pie del total a cobrar (sus dos partes) cabe entero;
 * más estrecho, una debajo de otra, con los signos entre ellas.
 *
 * Mide su contenedor, no la ventana: el menú lateral abierto no las aprieta.
 */
export function CifrasDelResumen({
  cifras,
  estado,
  onReintentar,
  linea,
}: {
  /** `null` mientras no hay respuesta (o si falló): van los títulos con su estado. */
  cifras: ReadonlyArray<CifraDelResumen> | null
  estado: EstadoCifra
  onReintentar: () => void
  /** Con qué se compara cada cifra, en una línea encima. */
  linea: string | null
}) {
  function tarjeta(id: IdCifraResumen) {
    const c = estado === 'listo' ? cifras?.find((x) => x.id === id) : undefined
    if (!c) {
      return (
        <CifraConTendencia
          titulo={TITULOS_DEL_RESUMEN[id]}
          valor=""
          estado={estado === 'listo' ? 'cargando' : estado}
          onReintentar={onReintentar}
        />
      )
    }
    return (
      <CifraConTendencia
        titulo={c.titulo}
        valor={c.valor}
        delta={c.delta}
        pie={c.pie}
        info={c.info}
        chispa={c.chispa}
      />
    )
  }

  const [facturado, fee, total] = CIFRAS_DEL_DESGLOSE
  const [consumos, usuarios] = CIFRAS_QUE_CUENTAN

  return (
    <div className="@container flex flex-col gap-3">
      {linea && <p className="type-panel-caption text-panel-muted">{linea}</p>}

      <div
        role="group"
        aria-label="Desglose: total financiado más service fee e IVA es igual al total a cobrar"
        className="grid grid-cols-1 gap-2 @min-[50rem]:grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)_auto_minmax(0,1fr)]"
      >
        {tarjeta(facturado)}
        <Operador signo="mas" />
        {tarjeta(fee)}
        <Operador signo="igual" />
        {tarjeta(total)}
      </div>

      <div className="grid grid-cols-1 gap-4 @min-[32rem]:grid-cols-2">
        {tarjeta(consumos)}
        {tarjeta(usuarios)}
      </div>
    </div>
  )
}

/**
 * El signo entre dos tarjetas del desglose. Se ve como un círculo pequeño
 * con el signo; el lector de pantalla lo lee con palabras entre las cifras.
 */
function Operador({ signo }: { signo: 'mas' | 'igual' }) {
  const Icono = signo === 'mas' ? Plus : Equal
  return (
    <div className="flex items-center justify-center">
      <span
        aria-hidden
        className="flex size-7 items-center justify-center rounded-full border border-panel-hairline-strong bg-panel-raised text-on-surface-variant"
      >
        <Icono size={15} strokeWidth={2.25} />
      </span>
      <span className="sr-only">{signo === 'mas' ? 'más' : 'es igual a'}</span>
    </div>
  )
}
