import { useEffect, useState } from 'react'
import { WifiOff } from 'lucide-react'

import { supabase } from '@/lib/supabase'

export type ConnectionStatus = 'online' | 'degraded' | 'offline'

/**
 * Indicador de conexión.
 *
 * No basta con `navigator.onLine`: dice si hay red local, no si Ronda
 * responde. El caso que hay que detectar en un local es el wifi que sigue
 * "conectado" pero sin salida — y ahí el QR no se genera y se forma cola en
 * la barra (docs/06-REGLAS §2: sin internet no se cobra).
 *
 * Por eso se sondea el servidor de verdad con una consulta trivial, y se
 * distingue "sin red" de "con red pero Ronda no contesta".
 *
 * Cada llamada sondea por su cuenta: la barra lateral lo llama una vez y
 * reparte el estado entre el punto del avatar y el aviso.
 */
export function useConnectionStatus(): ConnectionStatus {
  const [status, setStatus] = useState<ConnectionStatus>('online')

  useEffect(() => {
    let cancelled = false

    async function check() {
      if (!navigator.onLine) {
        if (!cancelled) setStatus('offline')
        return
      }

      try {
        // La consulta más barata que aún atraviesa PostgREST y la base.
        const { error } = await supabase
          .from('exchange_rates')
          .select('effective_date')
          .limit(1)

        if (!cancelled) setStatus(error ? 'degraded' : 'online')
      } catch {
        if (!cancelled) setStatus('degraded')
      }
    }

    void check()
    const id = setInterval(() => void check(), 20_000)

    // Los eventos del navegador dan la reacción inmediata; el sondeo cubre lo
    // que esos eventos no ven.
    const onOnline = () => void check()
    const onOffline = () => setStatus('offline')
    window.addEventListener('online', onOnline)
    window.addEventListener('offline', onOffline)

    return () => {
      cancelled = true
      clearInterval(id)
      window.removeEventListener('online', onOnline)
      window.removeEventListener('offline', onOffline)
    }
  }, [])

  return status
}

const COPY: Record<ConnectionStatus, { label: string; detail: string }> = {
  online: { label: 'Conectado', detail: 'Puedes cobrar con normalidad.' },
  degraded: {
    label: 'Sin conexión con Helios',
    detail: 'Hay internet, pero no llegamos al servidor. No se puede cobrar.',
  },
  offline: {
    label: 'Sin internet',
    detail: 'Revisa el wifi de la clínica. Sin conexión no se puede cobrar.',
  },
}

/**
 * El punto sobre el avatar de la cuenta: verde si Ronda contesta y rojo si no.
 * Es decorativo; lo que se lee lo dice `ConnectionIndicator`.
 */
export function PuntoDeConexion({ estado }: { estado: ConnectionStatus }) {
  return (
    <span
      aria-hidden
      className={`absolute -right-px -bottom-px size-2.25 rounded-full border-2 border-panel-bar ${
        estado === 'online' ? 'bg-success' : 'bg-error'
      }`}
    />
  )
}

/**
 * Lo que la barra lateral dice de la conexión.
 *
 * Conectado es lo normal y no ocupa sitio: lo dice el punto verde del avatar.
 * Sin conexión sí se escribe, en rojo y encima de la cuenta: sin internet no
 * se cobra, y el local tiene que enterarse antes de tener cola en la barra.
 * El contenedor es siempre el mismo `role="status"` para que un lector de
 * pantalla oiga el cambio en los dos sentidos.
 */
export function ConnectionIndicator({
  estado,
  plegado,
}: {
  estado: ConnectionStatus
  /** Plegada la barra, queda el icono; el rótulo va en el `title`. */
  plegado: boolean
}) {
  const copy = COPY[estado]

  return (
    <div role="status" aria-live="polite">
      {estado === 'online' ? (
        <span className="sr-only">{copy.label}</span>
      ) : (
        <div
          title={plegado ? copy.label : undefined}
          className={`flex items-center gap-2 rounded-panel-control bg-error/15 px-2.5 py-2 type-panel-label text-error ${
            plegado ? 'lg:justify-center lg:px-0' : ''
          }`}
        >
          <WifiOff size={16} aria-hidden className="shrink-0" />
          <span className={plegado ? 'lg:sr-only' : undefined}>{copy.label}</span>
        </div>
      )}
    </div>
  )
}

