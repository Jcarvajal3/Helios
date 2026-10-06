import { Check } from 'lucide-react'

import type { PasoDelAlta } from '@/features/merchant/registro'

const PASOS: Array<{ paso: PasoDelAlta; label: string }> = [
  { paso: 'cedula', label: 'Cédula' },
  { paso: 'datos', label: 'Datos del paciente' },
  { paso: 'monto', label: 'Monto' },
  { paso: 'confirmar', label: 'Confirmar' },
]

/**
 * Dónde va el alta: cuatro pasos en una fila, el actual marcado.
 *
 * No se pulsan. Volver atrás se hace con el botón de cada paso, que es donde
 * está la mano; una fila de pasos que se pulsan invita a saltarse la
 * vista previa, que es justo lo que no se puede saltar.
 *
 * Con un paciente conocido «Datos del paciente» se tacha: sus datos ya los
 * tiene Helios y la clínica no los puede cambiar.
 */
export function Pasos({ actual, sinDatos }: { actual: PasoDelAlta; sinDatos: boolean }) {
  const indice = PASOS.findIndex((p) => p.paso === actual)

  return (
    <ol aria-label="Pasos del alta" className="mb-5 flex flex-wrap items-center gap-x-2 gap-y-2 sm:mb-6">
      {PASOS.map((p, i) => {
        const hecho = i < indice
        const esActual = i === indice
        const saltado = p.paso === 'datos' && sinDatos
        return (
          <li key={p.paso} className="flex items-center gap-2">
            {i > 0 && <span aria-hidden className="h-px w-3 bg-panel-hairline-strong sm:w-5" />}
            <span
              aria-current={esActual ? 'step' : undefined}
              className={`inline-flex h-8 items-center gap-2 rounded-full px-3 type-panel-label ${esActual ? '' : 'max-sm:px-1.5'} ${
                esActual
                  ? 'bg-panel-control font-semibold text-on-surface'
                  : 'text-panel-muted'
              } ${saltado ? 'line-through' : ''}`}
            >
              <span
                aria-hidden
                className={`flex size-5 items-center justify-center rounded-full type-panel-caption font-bold ${
                  esActual
                    ? 'bg-primary text-on-primary'
                    : hecho
                      ? 'bg-success/15 text-success'
                      : 'bg-panel-control text-panel-muted'
                }`}
              >
                {hecho ? <Check size={12} strokeWidth={3} /> : i + 1}
              </span>
              {/* En el teléfono solo el paso actual dice su nombre: los
                  cuatro rótulos partían la fila en dos y empujaban el
                  formulario media pantalla abajo. Los demás quedan para el
                  lector de pantalla. */}
              <span className={esActual ? undefined : 'max-sm:sr-only'}>{p.label}</span>
              {saltado && <span className="sr-only"> (no hace falta: paciente conocido)</span>}
              {hecho && !saltado && <span className="sr-only"> (hecho)</span>}
            </span>
          </li>
        )
      })}
    </ol>
  )
}
