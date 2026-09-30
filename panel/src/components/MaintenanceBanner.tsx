import { useQuery } from '@tanstack/react-query'
import { CircleAlert, TriangleAlert } from 'lucide-react'

import { fetchMaintenance } from '@/features/admin/maintenance'

/**
 * El aviso de que Ronda está en mantenimiento, arriba de todo.
 *
 * Se pinta solo o no se pinta. Está en los dos shells —el del local y el del
 * equipo— porque el cajero necesita saber por qué los cobros rebotan antes de
 * teclear una orden entera, y el equipo necesita ver que sigue encendido: un
 * mantenimiento que se olvida encendido es una noche entera sin ventas.
 *
 * Ámbar si solo avisa y rojo si los cobros están parados: es un estado, y
 * lleva su icono y su rótulo. El texto va en blanco y gris, no en el color.
 *
 * Se refresca cada minuto: se enciende desde otra pantalla y desde otra
 * persona, y una tablet de barra puede llevar horas abierta sin recargar.
 */
export function MaintenanceBanner() {
  const { data } = useQuery({
    queryKey: ['maintenance'],
    queryFn: fetchMaintenance,
    refetchInterval: 60_000,
    refetchIntervalInBackground: true,
  })

  if (!data?.isActive) return null

  const Icono = data.blocksBalance ? CircleAlert : TriangleAlert

  return (
    <div
      role="status"
      className={`mb-shell-gap-group flex items-start gap-3 rounded-panel-card border px-4 py-3 ${
        data.blocksBalance ? 'border-error/40 bg-error/10' : 'border-warning/40 bg-warning/10'
      }`}
    >
      <Icono
        size={20}
        aria-hidden
        className={`mt-0.5 shrink-0 ${data.blocksBalance ? 'text-error' : 'text-warning'}`}
      />
      <div className="min-w-0">
        <p className="type-panel-body font-semibold text-on-surface">
          {data.blocksBalance ? `${data.title} — los cobros están parados` : data.title}
        </p>
        <p className="type-panel-body text-on-surface-variant">
          {data.message}
          {data.expectedBack ? ` Volvemos ${data.expectedBack}.` : ''}
        </p>
      </div>
    </div>
  )
}
