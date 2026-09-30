import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { Check, X } from 'lucide-react'

// ═══════════════════════════════════════════════════════════════════════════
// El aviso de que algo salió bien.
//
// El panel tenía todo el camino del error resuelto —`ErrorBox`,
// `describeError`, un `ConfirmDialog` con palabra de confirmación y motivo— y
// ni un solo aviso de acierto. Registrabas un cobro de €520 y no pasaba nada
// visible: la lista se refrescaba sola y ya. En una operación de dinero el
// silencio no se lee como "hecho", se lee como "no se guardó", y lo que sigue
// es volver a pulsar.
//
// Abajo a la derecha y no arriba: arriba está la barra con el título y la
// acción de la pantalla, y un aviso ahí tapa justo el botón que se acaba de
// pulsar.
// ═══════════════════════════════════════════════════════════════════════════

type Aviso = { id: number; texto: string }

const Contexto = createContext<(texto: string) => void>(() => {})

/** Cuánto se queda. Lo bastante para leerlo de reojo, no tanto como para que
 *  haya que esperarlo antes de seguir trabajando. */
const DURACION = 4000

export function ToastProvider({ children }: { children: ReactNode }) {
  const [avisos, setAvisos] = useState<Array<Aviso>>([])
  const siguienteId = useRef(0)

  // Estable: las pantallas lo meten en las dependencias de sus `onSuccess`.
  const avisar = useCallback((texto: string) => {
    const id = siguienteId.current++
    setAvisos((previos) => [...previos, { id, texto }])
  }, [])

  const cerrar = useCallback((id: number) => {
    setAvisos((previos) => previos.filter((a) => a.id !== id))
  }, [])

  return (
    <Contexto.Provider value={avisar}>
      {children}

      {/*
        `role="status"` y no `alert`: un acierto no interrumpe. El lector de
        pantalla lo anuncia cuando termine lo que esté diciendo, que es el
        trato correcto para "hecho".
      */}
      <div
        role="status"
        aria-live="polite"
        className="pointer-events-none fixed bottom-4 right-4 z-50 flex flex-col items-end gap-2"
      >
        {avisos.map((aviso) => (
          <Tarjeta key={aviso.id} aviso={aviso} onCerrar={() => cerrar(aviso.id)} />
        ))}
      </div>
    </Contexto.Provider>
  )
}

/**
 * Dice que algo salió bien, en pasado y con el dato concreto:
 * `avisar(\`Cobro de \${formatUsd(monto)} conciliado\`)`.
 *
 * Para lo que sale mal ya está `ErrorBox`, que se queda en pantalla: un error
 * que se va solo a los cuatro segundos es un error que nadie llega a leer.
 */
export function useToast(): (texto: string) => void {
  return useContext(Contexto)
}

function Tarjeta({ aviso, onCerrar }: { aviso: Aviso; onCerrar: () => void }) {
  useEffect(() => {
    const id = setTimeout(onCerrar, DURACION)
    return () => clearTimeout(id)
  }, [onCerrar])

  return (
    <div className="anim-aviso pointer-events-auto flex max-w-sm items-start gap-2.5 rounded-panel-card border border-panel-hairline-strong bg-panel-raised py-2.5 pl-3 pr-2 shadow-2xl">
      {/* Verde de estado y no lima: el lima es la acción, esto es «hecho». */}
      <Check size={16} aria-hidden className="mt-0.5 shrink-0 text-success" />
      <p className="type-panel-body text-on-surface">{aviso.texto}</p>
      <button
        type="button"
        onClick={onCerrar}
        aria-label="Cerrar el aviso"
        className="inline-flex size-6 shrink-0 items-center justify-center rounded-panel-control text-on-surface-variant transition-colors duration-[var(--transition-fast)] hover:bg-panel-control hover:text-on-surface"
      >
        <X size={14} />
      </button>
    </div>
  )
}
