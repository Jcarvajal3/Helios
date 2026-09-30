import { useState } from 'react'
import type { ReactNode } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { NotebookPen } from 'lucide-react'

import { useToast } from '@/components/Toast'
import { Button, ConfirmDialog, IconButton, Input, Select, diaOperativo } from '@/components/ui'
import { refrescarTrasAnotar } from '@/features/admin/cobranza/consultas'
import {
  CANALES,
  RESULTADO,
  RESULTADOS,
  ROTULO_CANAL,
  aGestion,
  avisoDeGestionAnotada,
  borradorInicial,
  motivoParaNoAnotar,
  resumenDeGestion,
} from '@/features/admin/cobranza/gestion'
import type { BorradorGestion, GestionNueva } from '@/features/admin/cobranza/gestion'
import { logContact } from '@/features/admin/contacts'
import { describeError } from '@/lib/supabase'

const OPCIONES_CANAL = CANALES.map((value) => ({ value, label: ROTULO_CANAL[value] }))
const OPCIONES_RESULTADO = RESULTADOS.map((value) => ({ value, label: RESULTADO[value].label }))

/**
 * «Anotar una gestión»: por dónde, qué pasó, qué prometió y cuándo volver.
 *
 * <DialogoGestion userId={id} nombre="Ana Pérez" onClose={() => setAbierto(false)} />
 *
 * Con `inicial` llega rellenado: el botón de WhatsApp lo abre con el canal y
 * «Mensaje enviado» ya puestos, y la persona solo confirma. Guarda con
 * `admin_log_contact` y refresca la cartera, el caso, las promesas y la
 * bitácora.
 */
export function DialogoGestion({
  userId,
  nombre,
  inicial,
  onClose,
  onAnotada,
}: {
  userId: string
  /** Cómo se llama la persona, para la frase del resumen. */
  nombre: string
  inicial?: Partial<BorradorGestion>
  onClose: () => void
  onAnotada?: () => void
}) {
  const client = useQueryClient()
  const avisar = useToast()
  const [borrador, setBorrador] = useState(() => borradorInicial(inicial))
  // El día operativo al abrir: con él valida la base.
  const [hoy] = useState(() => diaOperativo(new Date()))

  const anotar = useMutation({
    mutationFn: (g: GestionNueva) => logContact(userId, g),
    onSuccess: (_nada, g) => {
      refrescarTrasAnotar(client, userId)
      avisar(avisoDeGestionAnotada(g))
      onAnotada?.()
      onClose()
    },
  })

  function cambiar(parte: Partial<BorradorGestion>) {
    setBorrador((b) => ({ ...b, ...parte }))
  }

  const bloqueo = motivoParaNoAnotar(borrador, hoy)

  return (
    <SinPropagar>
      <ConfirmDialog
        title="Anotar una gestión"
        summary={resumenDeGestion(nombre, borrador)}
        detail={
          <div className="flex flex-col gap-3">
            <Select
              id="gestion-canal"
              label="Por dónde"
              value={borrador.canal}
              options={OPCIONES_CANAL}
              onChange={(canal) => cambiar({ canal })}
            />
            <Select
              id="gestion-resultado"
              label="Qué pasó"
              value={borrador.resultado}
              placeholder="Elige el resultado"
              options={OPCIONES_RESULTADO}
              onChange={(resultado) => cambiar({ resultado })}
            />
            {borrador.resultado === 'promesa' && (
              <Input
                id="gestion-promesa"
                label="Día en que prometió pagar"
                type="date"
                min={hoy}
                value={borrador.fechaPrometida}
                onChange={(fechaPrometida) => cambiar({ fechaPrometida })}
                hint="La promesa no descongela la cuenta ni frena el cargo por atraso."
              />
            )}
            <Input
              id="gestion-nota"
              label="Nota (opcional)"
              value={borrador.nota}
              onChange={(nota) => cambiar({ nota })}
              placeholder="Dice que cobra el viernes y paga ese mismo día"
            />
            <Input
              id="gestion-volver"
              label="Volver a llamar el (opcional)"
              type="date"
              min={hoy}
              value={borrador.volverALlamar}
              onChange={(volverALlamar) => cambiar({ volverALlamar })}
            />
          </div>
        }
        bloqueo={bloqueo}
        confirmLabel="Anotar"
        busy={anotar.isPending}
        error={anotar.isError ? describeError(anotar.error) : undefined}
        onConfirm={() => {
          if (borrador.resultado === '' || bloqueo) return
          anotar.mutate(aGestion({ ...borrador, resultado: borrador.resultado }))
        }}
        onClose={onClose}
      />
    </SinPropagar>
  )
}

/**
 * El botón que abre `DialogoGestion`. `compacto` es el icono de una fila de
 * tabla; si no, el botón con su rótulo.
 */
export function BotonAnotarGestion({
  userId,
  nombre,
  compacto = false,
}: {
  userId: string
  nombre: string
  compacto?: boolean
}) {
  const [abierto, setAbierto] = useState(false)

  return (
    <>
      {compacto ? (
        <IconButton
          variant="text"
          label="Anotar una gestión"
          title="Anotar una gestión por cualquier canal, o una promesa de pago"
          onClick={() => setAbierto(true)}
        >
          <NotebookPen size={15} />
        </IconButton>
      ) : (
        <Button size="sm" variant="tonal" onClick={() => setAbierto(true)}>
          <NotebookPen size={15} aria-hidden /> Anotar una gestión
        </Button>
      )}

      {abierto && (
        <DialogoGestion userId={userId} nombre={nombre} onClose={() => setAbierto(false)} />
      )}
    </>
  )
}

/**
 * Un diálogo que se abre desde una fila de tabla vive, para React, dentro de
 * esa fila: un clic en su texto subiría hasta la fila y abriría la ficha. Esto
 * lo corta. Solo el clic: el teclado lo necesita la ventana para Escape y Tab.
 */
export function SinPropagar({ children }: { children: ReactNode }) {
  return (
    <div className="contents" onClick={(e) => e.stopPropagation()}>
      {children}
    </div>
  )
}
