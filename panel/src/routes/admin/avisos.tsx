import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { Construction } from 'lucide-react'

import { PlantillasCobranza } from '@/components/admin/PlantillasCobranza'
import { EmptyState, Tabs } from '@/components/ui'
import { unoDe } from '@/lib/busqueda'

type Vista = 'hoy' | 'plantillas'

const VISTAS: Array<{ value: Vista; label: string }> = [
  { value: 'hoy', label: 'Avisos de hoy' },
  { value: 'plantillas', label: 'Plantillas de WhatsApp' },
]

type AvisosSearch = { vista?: Vista }

export const Route = createFileRoute('/admin/avisos')({
  staticData: { title: 'Avisos' },
  component: AvisosPage,
  validateSearch: (search: Record<string, unknown>): AvisosSearch => ({
    vista: unoDe(
      VISTAS.map((v) => v.value),
      search.vista,
    ),
  }),
})

/**
 * Avisos: lo que el equipo le manda a cada paciente por WhatsApp.
 *
 *   Avisos de hoy           la cola diaria de mensajes (plan §7.2): cada fila
 *                           con el texto ya escrito, «Abrir WhatsApp» y
 *                           «Enviado». FASE 3, sobre `outbound_messages`.
 *   Plantillas de WhatsApp  lo que el operador copia cuando escribe a cobrar.
 *
 * Sustituye a las Notificaciones de Ronda (push y promociones): Helios no
 * tiene app, así que nada sale solo.
 */
function AvisosPage() {
  const navigate = useNavigate({ from: '/admin/avisos' })
  const { vista = 'hoy' } = Route.useSearch()

  return (
    <>
      <Tabs
        options={VISTAS}
        value={vista}
        onChange={(v) => void navigate({ search: { vista: v === 'hoy' ? undefined : v } })}
      />

      {vista === 'hoy' && (
        <EmptyState
          icon={<Construction size={48} />}
          title="Avisos de hoy — en construcción"
          description="Aquí va a estar la cola diaria de mensajes por WhatsApp: cada aviso con su texto listo, un botón para abrir el chat y otro para marcarlo como enviado."
        />
      )}
      {vista === 'plantillas' && <PlantillasCobranza />}
    </>
  )
}
