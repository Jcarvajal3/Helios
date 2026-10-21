import { useState } from 'react'

import { useToast } from '@/components/Toast'
import { Button } from '@/components/ui'
import { enlaceDelComprobanteDePago } from '@/features/admin/pagosRegistrados/api'

/**
 * La captura que mandó el paciente por WhatsApp, del bucket privado
 * `payment-receipts`: el enlace se firma al pulsar y caduca en diez minutos.
 * La subió el equipo al registrar el pago, o el lector de comprobantes.
 */
export function VerCaptura({ ruta, rotulo = 'Ver la captura del pago' }: { ruta: string; rotulo?: string }) {
  const avisar = useToast()
  const [abriendo, setAbriendo] = useState(false)

  async function abrir() {
    setAbriendo(true)
    try {
      window.open(await enlaceDelComprobanteDePago(ruta), '_blank', 'noopener,noreferrer')
    } catch {
      avisar('No se pudo abrir la captura')
    } finally {
      setAbriendo(false)
    }
  }

  return (
    <div>
      <Button size="sm" variant="tonal" disabled={abriendo} onClick={() => void abrir()}>
        {abriendo ? 'Abriendo…' : rotulo}
      </Button>
    </div>
  )
}
