import { useState } from 'react'
import {
  CalendarClock,
  CircleCheck,
  CircleX,
  Clock,
  Handshake,
  Lock,
  MessageSquareOff,
  TrendingDown,
} from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

import { MarcaConGlobo } from '@/components/charts/lectura'
import { RELLENO_DE_TONO, TINTE_DE_TONO } from '@/components/kit/tonos'
import type { BadgeTone } from '@/components/ui'
import { ROTULO_INTENCION, intencionDe } from '@/features/admin/cobranza/senales'
import type { ClaveDeSenal, Intencion, Senal, TonoDeSenal } from '@/features/admin/cobranza/senales'

/** El tono de pastilla de cada clase de señal: verde a favor, rojo en contra. */
const TONO: Record<TonoDeSenal, BadgeTone> = {
  intencion: 'success',
  evita: 'error',
  aviso: 'warning',
  historia: 'neutral',
}

/** Cada señal con su forma: se tiene que poder leer sin distinguir el color. */
const ICONO: Record<ClaveDeSenal, LucideIcon> = {
  en_revision: Clock,
  rechazado: CircleX,
  promete: Handshake,
  promesa_rota: Handshake,
  sin_respuesta: MessageSquareOff,
  nunca_pago: CircleX,
  siempre_a_tiempo: CircleCheck,
  suele_tarde: TrendingDown,
  congelada: Lock,
  baja_pronto: CalendarClock,
}

/** Las que se ven sin pedir más: el resto se abre con «+N». */
const A_LA_VISTA = 4

/**
 * Las señales de un deudor en pastillas, con su globo (qué quiere decir y
 * desde cuándo), y debajo la barra de intención que las resume. Pulsar «+N»
 * enseña las que no caben; no navega, así que no abre el caso de la fila.
 */
export function Senales({ senales, compacta = false }: { senales: ReadonlyArray<Senal>; compacta?: boolean }) {
  const [todas, setTodas] = useState(false)
  const vistas = todas ? senales : senales.slice(0, A_LA_VISTA)
  const quedan = senales.length - vistas.length

  return (
    <div className="flex min-w-0 flex-col gap-2">
      {senales.length === 0 ? (
        <span className="type-panel-caption text-panel-muted">Sin señales</span>
      ) : (
        // Pulsar una señal enseña su globo, no abre el caso de la fila.
        <span onClick={(e) => e.stopPropagation()} className={`flex flex-wrap gap-1.5 ${compacta ? 'max-w-72' : 'max-w-md'}`}>
          {vistas.map((s) => (
            <PastillaDeSenal key={s.clave} senal={s} />
          ))}
          {quedan > 0 && (
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation()
                setTodas(true)
              }}
              className="inline-flex h-6 items-center rounded-full px-2 type-panel-caption font-bold text-on-surface-variant hover:text-on-surface"
            >
              +{quedan}
            </button>
          )}
        </span>
      )}
      <MedidorDeIntencion intencion={intencionDe(senales)} />
    </div>
  )
}

function PastillaDeSenal({ senal: s }: { senal: Senal }) {
  const Icono = ICONO[s.clave]
  return (
    <MarcaConGlobo
      titulo={s.texto}
      filas={[]}
      nota={s.ayuda}
      lado="abajo"
      className={`inline-flex h-6 max-w-full items-center gap-1.5 rounded-full px-2.5 type-panel-caption font-bold outline-none focus-visible:ring-2 focus-visible:ring-primary ${TINTE_DE_TONO[TONO[s.tono]]}`}
    >
      <Icono size={12} strokeWidth={2.25} aria-hidden className="shrink-0" />
      <span className="truncate">{s.texto}</span>
    </MarcaConGlobo>
  )
}

const RELLENO_INTENCION: Record<Intencion, { llenas: number; tono: BadgeTone }> = {
  quiere: { llenas: 3, tono: 'success' },
  dudosa: { llenas: 2, tono: 'warning' },
  evita: { llenas: 1, tono: 'error' },
}

/**
 * Tres rayas: tres verdes quiere pagar, dos ámbar no está claro, una roja lo
 * evita. Qué suma cada señal lo dice la ayuda de la columna.
 */
export function MedidorDeIntencion({ intencion }: { intencion: Intencion }) {
  const { llenas, tono } = RELLENO_INTENCION[intencion]
  return (
    <span className="flex items-center gap-2 type-panel-caption text-on-surface-variant">
      <span aria-hidden className="flex gap-0.75">
        {[0, 1, 2].map((i) => (
          <span
            key={i}
            className={`h-1.5 w-4 rounded-full ${i < llenas ? RELLENO_DE_TONO[tono] : 'bg-panel-control'}`}
          />
        ))}
      </span>
      {ROTULO_INTENCION[intencion]}
    </span>
  )
}
