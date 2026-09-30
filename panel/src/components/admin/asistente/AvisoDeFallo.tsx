import { useEffect, useState } from 'react'
import { CircleAlert, RotateCcw, Search, SquarePen, TriangleAlert } from 'lucide-react'

import { abrirPaleta } from '@/components/admin/paleta'
import { Button } from '@/components/ui'
import type { Fallo } from '@/features/admin/asistente/conversacion'
import { avisoDelFallo, seReintentaSolo } from '@/features/admin/asistente/errores'
import { useAsistentePanel, useConversacionDelAsistente } from './contexto'

const TONO = {
  warning: { caja: 'border-warning/30 bg-warning/7', icono: 'text-warning', Icono: TriangleAlert },
  error: { caja: 'border-error/30 bg-error/7', icono: 'text-error', Icono: CircleAlert },
} as const

/**
 * Los segundos que faltan para el reintento automático, contados aquí para
 * no repintar la conversación entera cada segundo.
 *
 * La cifra que cambia no se lee en voz alta: el registro de la conversación
 * es una región viva y la anunciaría segundo a segundo. El lector oye una
 * sola frase.
 */
function CuentaAtras({ hasta }: { hasta: number }) {
  const [ahora, setAhora] = useState(() => Date.now())
  useEffect(() => {
    const id = window.setInterval(() => setAhora(Date.now()), 250)
    return () => window.clearInterval(id)
  }, [])
  const segundos = Math.max(0, Math.ceil((hasta - ahora) / 1000))

  return (
    <p className="type-panel-body text-on-surface-variant">
      <span aria-hidden>Se vuelve a intentar en {segundos} s.</span>
      <span className="sr-only">Se volverá a intentar en unos segundos.</span>
    </p>
  )
}

/**
 * Por qué una respuesta no llegó, con lo que se puede hacer.
 *
 * Ámbar cuando el asistente no está disponible (ocupado, sin configurar, al
 * límite) y rojo cuando esta respuesta falló. Si está ocupado, la pregunta se
 * repite sola a los diez segundos, una vez, con la cuenta atrás a la vista y
 * la opción de cancelarla; mientras, «Buscar en el panel» lleva lo preguntado
 * a la paleta. Lo técnico va plegado en «Detalle técnico», nunca en la frase.
 *
 * Las acciones solo salen en la última respuesta: reintentar una de antes
 * cambiaría la conversación que vino después.
 */
export function AvisoDeFallo({
  fallo,
  esLaUltima,
  pregunta,
}: {
  fallo: Fallo
  esLaUltima: boolean
  /** La pregunta que falló, para buscarla en la paleta. */
  pregunta: string | null
}) {
  const { conversacion } = useConversacionDelAsistente()
  const { nuevaConversacion } = useAsistentePanel()
  const { reintentar, reintentoAutomatico, cancelarReintento } = conversacion

  const aviso = avisoDelFallo(fallo)
  const tono = TONO[aviso.tono]
  const esperando = esLaUltima && reintentoAutomatico !== null && seReintentaSolo(fallo)

  const cancelar = esperando
  const repetir = !esperando && fallo.reintentar
  const buscar = aviso.buscar ? pregunta : null
  const hayAcciones = esLaUltima && (cancelar || repetir || buscar !== null || aviso.empezarDeNuevo)

  const acciones = hayAcciones && (
    <div className="mt-2 flex flex-wrap gap-2">
      {cancelar && (
        <Button variant="tonal" size="sm" onClick={cancelarReintento}>
          Cancelar
        </Button>
      )}
      {repetir && (
        <Button variant="tonal" size="sm" onClick={reintentar}>
          <RotateCcw size={14} aria-hidden />
          Reintentar
        </Button>
      )}
      {buscar !== null && (
        <Button variant="tonal" size="sm" onClick={() => abrirPaleta(buscar)}>
          <Search size={14} aria-hidden />
          Buscar en el panel
        </Button>
      )}
      {aviso.empezarDeNuevo && (
        <Button variant="tonal" size="sm" onClick={nuevaConversacion}>
          <SquarePen size={14} aria-hidden />
          Empezar una conversación nueva
        </Button>
      )}
    </div>
  )

  return (
    <div className={`flex gap-3 rounded-panel-card border p-3.5 ${tono.caja}`}>
      <tono.Icono size={18} aria-hidden className={`mt-px shrink-0 ${tono.icono}`} />
      <div className="flex min-w-0 flex-1 flex-col gap-1">
        <p className="type-panel-body font-semibold text-on-surface">{aviso.titulo}</p>
        {esperando ? (
          <CuentaAtras hasta={reintentoAutomatico.hasta} />
        ) : (
          aviso.linea && <p className="type-panel-body text-on-surface-variant">{aviso.linea}</p>
        )}
        {acciones}
        {fallo.detalle && (
          <details className="mt-1">
            <summary className="cursor-pointer type-panel-caption text-panel-muted hover:text-on-surface-variant">
              Detalle técnico
            </summary>
            <p className="mt-1 break-words font-mono type-panel-caption text-panel-muted">{fallo.detalle}</p>
          </details>
        )}
      </div>
    </div>
  )
}
