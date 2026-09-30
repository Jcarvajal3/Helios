import { Check, LoaderCircle, X } from 'lucide-react'

import { bloquesDeRespuesta } from '@/features/admin/asistente/conversacion'
import type { Bloque, MensajeAsistente as Mensaje } from '@/features/admin/asistente/conversacion'
import { enlaceValido } from '@/features/admin/asistente/enlaces'
import type { EstadoHerramienta, Herramienta } from '@/features/admin/asistente/protocolo'
import { AvisoDeFallo } from './AvisoDeFallo'
import { EnlaceAsistente } from './EnlaceAsistente'
import { GraficoAsistente } from './GraficoAsistente'
import { TablaAsistente } from './TablaAsistente'
import { TextoAsistente } from './TextoAsistente'

const MARCA = 'inline-flex size-4.5 shrink-0 items-center justify-center rounded-full'

/** El circulito de cada consulta: gira mientras corre y se queda con su resultado. */
function MarcaDeConsulta({ estado }: { estado: EstadoHerramienta }) {
  switch (estado) {
    case 'hecho':
      return (
        <span className={`${MARCA} bg-success/15 text-success`}>
          <Check size={11} strokeWidth={2.5} aria-hidden />
        </span>
      )
    case 'error':
      return (
        <span className={`${MARCA} bg-error/15 text-error`}>
          <X size={11} strokeWidth={2.5} aria-hidden />
        </span>
      )
    case 'consultando':
      return (
        <span className={MARCA}>
          <LoaderCircle size={14} aria-hidden className="animate-spin" />
        </span>
      )
  }
}

/**
 * Las consultas a la base de esta respuesta, una línea discreta cada una: lo
 * que el asistente leyó para contestar, sin quitarle sitio a la respuesta.
 */
function Consultas({ herramientas }: { herramientas: ReadonlyArray<Herramienta> }) {
  return (
    <ul className="flex flex-col gap-1.5" aria-label="Consultas a la base">
      {herramientas.map((h) => (
        <li key={h.id} className="flex min-w-0 items-center gap-2 type-panel-caption text-panel-muted">
          <MarcaDeConsulta estado={h.estado} />
          <span className="truncate" title={h.rotulo}>
            {h.rotulo}
            {h.estado === 'consultando' ? '…' : ''}
            {h.estado === 'error' && <span className="sr-only"> (no terminó)</span>}
          </span>
        </li>
      ))}
    </ul>
  )
}

function BloqueDeRespuesta({ bloque, alNavegar }: { bloque: Bloque; alNavegar: () => void }) {
  if (bloque.tipo === 'enlaces') {
    // Los que no llevan a ninguna pantalla no salen; sin ninguno, ni la fila.
    const validos = bloque.enlaces.filter((e) => enlaceValido(e) !== null)
    if (validos.length === 0) return null
    return (
      <div className="flex flex-wrap gap-2">
        {validos.map((e, i) => (
          <EnlaceAsistente key={i} enlace={e} alNavegar={alNavegar} />
        ))}
      </div>
    )
  }
  const { pieza } = bloque
  switch (pieza.tipo) {
    case 'texto':
      return <TextoAsistente texto={pieza.texto} />
    case 'grafico':
      return <GraficoAsistente grafico={pieza.grafico} />
    case 'tabla':
      return <TablaAsistente tabla={pieza.tabla} />
  }
}

/**
 * Una respuesta del asistente: las consultas que hizo, el texto con lo que
 * dibujó intercalado (los enlaces seguidos, en una fila) y, si algo falló,
 * el aviso con su causa.
 *
 * Sin burbuja: la respuesta ocupa el ancho de la columna, como un documento,
 * y la burbuja queda para lo que escribió la persona.
 */
export function MensajeAsistente({
  mensaje,
  esLaUltima,
  pregunta,
  alNavegar,
}: {
  mensaje: Mensaje
  esLaUltima: boolean
  /** La pregunta a la que contesta: el aviso de un fallo la lleva a la paleta. */
  pregunta: string | null
  alNavegar: () => void
}) {
  const { piezas, herramientas, estado, fallo } = mensaje
  const pensando =
    estado === 'escribiendo' && piezas.length === 0 && herramientas.every((h) => h.estado !== 'consultando')

  return (
    <div className="flex min-w-0 flex-col gap-3.5">
      <span className="sr-only">El asistente:</span>
      {herramientas.length > 0 && <Consultas herramientas={herramientas} />}
      {bloquesDeRespuesta(piezas).map((b, i) => (
        <BloqueDeRespuesta key={i} bloque={b} alNavegar={alNavegar} />
      ))}
      {pensando && (
        <p className="flex items-center gap-2 type-panel-caption text-panel-muted">
          <LoaderCircle size={14} aria-hidden className="animate-spin" />
          Pensando…
        </p>
      )}
      {estado === 'parada' && (
        <p className="type-panel-caption text-panel-muted">Respuesta detenida. Lo que se ve puede estar incompleto.</p>
      )}
      {fallo && <AvisoDeFallo fallo={fallo} esLaUltima={esLaUltima} pregunta={pregunta} />}
    </div>
  )
}
