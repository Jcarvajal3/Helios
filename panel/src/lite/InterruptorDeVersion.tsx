import { cambiarVersionDelAdmin, useVersionDelAdmin } from './version'
import type { VersionDelAdmin } from './version'

const OPCIONES: ReadonlyArray<{ version: VersionDelAdmin; rotulo: string; corto: string }> = [
  { version: 'pro', rotulo: 'Helios Pro', corto: 'Pro' },
  { version: 'lite', rotulo: 'Helios Lite', corto: 'Lite' },
]

/**
 * El interruptor entre Helios Pro y Helios Lite, arriba del todo del menú.
 *
 * Cambiar de versión no cambia de pantalla: las dos abren las mismas rutas,
 * así que se sigue en el mismo sitio con el otro marco. Solo Inicio y el
 * Resumen comparten dirección (`/admin`) y cambian entre sí.
 *
 * Se viste de cada versión: en Pro con las utilidades del panel, en Lite con
 * las clases de la maqueta (`lt-interruptor`, en `estilos/maqueta.css`).
 *
 * `compacto`: en una barra de iconos (Pro plegado, Lite) no cabe «Helios
 * Pro»; quedan «Pro» y «Lite», uno encima del otro.
 */
export function InterruptorDeVersion({
  compacto = false,
  estilo = 'pro',
}: {
  compacto?: boolean
  estilo?: VersionDelAdmin
}) {
  const version = useVersionDelAdmin()

  if (estilo === 'lite') {
    return (
      <div role="radiogroup" aria-label="Versión del panel" className="lt-interruptor">
        {OPCIONES.map((o) => (
          <button
            key={o.version}
            type="button"
            role="radio"
            aria-checked={version === o.version}
            title={o.rotulo}
            onClick={() => cambiarVersionDelAdmin(o.version)}
          >
            {o.corto}
          </button>
        ))}
      </div>
    )
  }

  return (
    <div
      role="radiogroup"
      aria-label="Versión del panel"
      className={`flex gap-0.5 rounded-full border border-panel-hairline bg-panel-card p-0.5 ${
        compacto ? 'flex-col rounded-2xl' : ''
      }`}
    >
      {OPCIONES.map((o) => {
        const activa = version === o.version
        return (
          <button
            key={o.version}
            type="button"
            role="radio"
            aria-checked={activa}
            title={o.rotulo}
            onClick={() => cambiarVersionDelAdmin(o.version)}
            className={`flex-1 rounded-full px-2.5 py-1 text-xs font-semibold tracking-[-0.01em] transition-colors duration-(--transition-fast) ${
              compacto ? 'rounded-xl px-1.5' : ''
            } ${
              activa
                ? 'bg-[#157EFD] text-white shadow-[0_4px_10px_rgba(21,126,253,0.25)]'
                : 'text-panel-muted hover:text-on-surface'
            }`}
          >
            {compacto ? o.corto : o.rotulo}
          </button>
        )
      })}
    </div>
  )
}
