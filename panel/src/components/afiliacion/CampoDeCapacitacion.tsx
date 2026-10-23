import { Bloque } from '@/components/afiliacion/CamposDeAlta'
import { sumarDias } from '@/components/kit/rango'
import { Input } from '@/components/ui'
import { CAPACITACION_HASTA_DIAS } from '@/features/admin/clinicas/clinicas'
import type { Capacitacion } from '@/features/admin/clinicas/clinicas'

/**
 * La capacitación presencial que pide el médico en la portada: el día y la
 * hora, opcionales. Llega a la agenda del equipo como su visita
 * (`helios_leads_al_llegar_la_solicitud`). De mañana a 90 días, como la base.
 */
export function CampoDeCapacitacion({
  id,
  valor,
  hoy,
  onChange,
}: {
  id: string
  valor: Capacitacion
  /** El día de Caracas, 'YYYY-MM-DD'. */
  hoy: string
  onChange: (siguiente: Capacitacion) => void
}) {
  return (
    <Bloque
      titulo="Capacitación presencial (opcional)"
      nota="Elige el día y la hora en que prefieres que te enseñemos a usar Helios en persona."
    >
      <Input
        id={`${id}-capacitacion-dia`}
        label="Día"
        type="date"
        min={sumarDias(hoy, 1)}
        max={sumarDias(hoy, CAPACITACION_HASTA_DIAS)}
        value={valor.dia}
        onChange={(dia) => onChange({ ...valor, dia })}
      />
      <Input
        id={`${id}-capacitacion-hora`}
        label="Hora"
        type="time"
        value={valor.hora}
        onChange={(hora) => onChange({ ...valor, hora })}
      />
    </Bloque>
  )
}
