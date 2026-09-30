import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { MessageCircle } from 'lucide-react'

import { Button, claseDeBoton } from '@/components/ui'
import type { CollectionRow } from '@/features/admin/cobranza/cartera'
import {
  consultaCasoDeCobranza,
  consultaCuentasDeCobro,
  consultaPlantillas,
  consultaTasa,
} from '@/features/admin/cobranza/consultas'
import { lecturaDe, whatsAppDeCobro } from '@/features/admin/cobranza/whatsapp'
import type { Lectura } from '@/features/admin/cobranza/whatsapp'
import { cortesDeTramo } from '@/features/admin/tramos'
import { useParametros } from '@/features/admin/useParametros'
import { DialogoGestion } from './CobranzaGestion'

/**
 * La fila de la cartera de una persona (`admin_collection_case`), sin cargar
 * la cartera entera al abrir una ficha. `null` si no debe nada vencido ni por
 * vencer esta semana.
 */
export function useCasoDeCobranza(userId: string, enabled = true) {
  return useQuery({ ...consultaCasoDeCobranza(userId), enabled })
}

/**
 * «Escribir por WhatsApp» con la plantilla de su tramo de atraso (o la de
 * antes de vencer), y anotar lo que pasó.
 *
 * <BotonWhatsAppCobranza userId={id} />                    en una cabecera
 * <BotonWhatsAppCobranza userId={fila.userId} persona={fila} compacto />   en una fila
 *
 * Abre el chat con el mensaje ya rellenado y, a la vez, «Anotar una gestión»
 * con canal WhatsApp y «Mensaje enviado»: la persona confirma lo que de verdad
 * pasó. Pulsar ya no anota nada por sí solo. Si falta la plantilla, la cuenta
 * de cobro o el teléfono, el botón se ve apagado con el motivo escrito.
 */
export function BotonWhatsAppCobranza({
  userId,
  persona,
  compacto = false,
  principal = false,
}: {
  userId: string
  /** La fila de la cartera, si ya se tiene; sin ella se pide el caso. */
  persona?: CollectionRow
  /** Para una fila de tabla: rótulo corto. */
  compacto?: boolean
  /** La acción principal de la pantalla (la cabecera de la ficha): en lima. */
  principal?: boolean
}) {
  const [anotando, setAnotando] = useState(false)

  const fila = useCasoDeCobranza(userId, persona === undefined)
  const plantillas = useQuery(consultaPlantillas())
  const cuentas = useQuery(consultaCuentasDeCobro())
  const tasa = useQuery(consultaTasa())
  const parametros = useParametros()

  const lecturaPersona: Lectura<CollectionRow | null> = persona
    ? { estado: 'listo', valor: persona }
    : lecturaDe(fila)

  const whatsapp = whatsAppDeCobro({
    persona: lecturaPersona,
    plantillas: lecturaDe({
      isError: plantillas.isError,
      isPending: plantillas.isPending,
      data: plantillas.data?.rows,
    }),
    cuentas: lecturaDe(cuentas),
    tasa: lecturaDe({
      isError: tasa.isError,
      isPending: tasa.isPending,
      data: tasa.data ? tasa.data.rate : undefined,
    }),
    cortes: lecturaDe({
      isError: parametros.isError,
      isPending: parametros.isPending,
      data: parametros.data ? cortesDeTramo(parametros.data) : undefined,
    }),
  })

  const rotulo = compacto ? 'WhatsApp' : 'Escribir por WhatsApp'
  const nombre = (persona ?? fila.data)?.fullName ?? 'este paciente'

  if (!whatsapp.listo) {
    return (
      <Button size="sm" variant={principal ? 'filled' : 'tonal'} disabled motivoApagado={whatsapp.motivo}>
        <MessageCircle size={14} aria-hidden /> {rotulo}
      </Button>
    )
  }

  return (
    <>
      <a
        href={whatsapp.href}
        target="_blank"
        rel="noreferrer"
        onClick={() => setAnotando(true)}
        title={`Abre WhatsApp con la plantilla «${whatsapp.plantilla}» rellenada. El texto se edita en Cobranza › Recordatorios.`}
        className={`whitespace-nowrap ${claseDeBoton(principal ? 'filled' : 'tonal', 'sm')}`}
      >
        <MessageCircle size={14} aria-hidden /> {rotulo}
      </a>

      {anotando && (
        <DialogoGestion
          userId={userId}
          nombre={nombre}
          inicial={{ canal: 'whatsapp', resultado: 'mensaje_enviado', plantilla: whatsapp.plantilla }}
          onClose={() => setAnotando(false)}
        />
      )}
    </>
  )
}
