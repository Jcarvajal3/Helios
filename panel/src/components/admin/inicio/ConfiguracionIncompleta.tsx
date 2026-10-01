import { Link } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'

import { Callout, claseDeBoton } from '@/components/ui'
import { consultaEstadoDeConfiguracion } from '@/features/admin/contacto/api'
import { faltantesDeConfiguracion } from '@/features/admin/contacto/contacto'

/**
 * «Configuración incompleta» (plan H11): lo que falta para que el paciente
 * sepa a dónde pagar, a quién escribir y reciba su comprobante, cada cosa con
 * el enlace a donde se arregla. Sale de `helios_config_status()`.
 *
 * Con todo configurado, o mientras se lee, no pinta nada. Si la lectura
 * falla tampoco: no bloquea la operación y no se inventa un aviso.
 */
export function ConfiguracionIncompleta() {
  const estado = useQuery(consultaEstadoDeConfiguracion())
  if (!estado.data) return null

  const faltan = faltantesDeConfiguracion(estado.data)
  if (faltan.length === 0) return null

  return (
    <Callout
      tone="warning"
      titulo={`Configuración incompleta: ${faltan.length === 1 ? 'falta una cosa' : `faltan ${faltan.length} cosas`}`}
      detalles={
        <ul className="flex flex-col gap-2">
          {faltan.map((f) => (
            <li key={f.id} className="flex flex-wrap items-center justify-between gap-2">
              <span>
                <span className="block type-panel-body text-on-surface">{f.texto}</span>
                <span className="block type-panel-caption text-on-surface-variant">{f.efecto}</span>
              </span>
              {f.arreglo && (
                <Link {...f.arreglo.destino} className={claseDeBoton('tonal', 'sm')}>
                  {f.arreglo.rotulo}
                </Link>
              )}
            </li>
          ))}
        </ul>
      }
    >
      {faltan.map((f) => f.texto).join(' ')}
    </Callout>
  )
}
