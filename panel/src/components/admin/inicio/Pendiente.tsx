import { useState } from 'react'
import { ArrowRight } from 'lucide-react'

import { Button, Modal, Seccion, SkeletonCard, StatGrid } from '@/components/ui'
import { Entrada } from './Entrada'
import { TARJETAS_EN_LA_FILA } from './tarjetasDePendiente'
import { TarjetaAlDia, TarjetaPendiente } from './TarjetaPendiente'
import { TuCola } from './TuCola'
import { usePendiente } from './usePendiente'

/**
 * «Pendiente»: lo que pide atención hoy, en una fila de cuatro tarjetas como
 * mucho. Primero lo que bloquea la operación y luego las colas con trabajo,
 * de la más urgente a la que puede esperar; sin nada, una sola tarjeta que
 * lo dice. La cola entera, vacías incluidas, está en «Ver toda la cola».
 */
export function Pendiente() {
  const pendiente = usePendiente()
  const [verCola, setVerCola] = useState(false)

  return (
    <Seccion
      titulo="Pendiente"
      info="Primero lo que impide operar y después las colas de trabajo de los cuatro equipos, de la más urgente a la que puede esperar. Las colas vacías no salen aquí: están en «Ver toda la cola». «Empezar» abre la primera ficha y deja la barra para pasar a la siguiente."
      controles={
        <Button variant="text" size="sm" onClick={() => setVerCola(true)}>
          Ver toda la cola
          <ArrowRight size={14} aria-hidden />
        </Button>
      }
    >
      <StatGrid cols={4}>
        {pendiente.estado === 'cargando' &&
          Array.from({ length: TARJETAS_EN_LA_FILA }, (_, i) => (
            <SkeletonCard key={i} className="h-full min-h-44" />
          ))}

        {pendiente.estado === 'al-dia' && (
          <Entrada orden={0}>
            <TarjetaAlDia />
          </Entrada>
        )}

        {pendiente.estado === 'con-trabajo' &&
          pendiente.tarjetas.map((tarjeta, i) => (
            <Entrada key={tarjeta.clave} orden={i}>
              <TarjetaPendiente tarjeta={tarjeta} principal={tarjeta.clave === pendiente.principal} />
            </Entrada>
          ))}
      </StatGrid>

      {verCola && (
        <Modal title="Tu cola" width="lg" onClose={() => setVerCola(false)}>
          <TuCola />
        </Modal>
      )}
    </Seccion>
  )
}
