import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Phone, Plus, RotateCcw, Trash2 } from 'lucide-react'

import { useToast } from '@/components/Toast'
import {
  Button,
  Callout,
  Card,
  ConfirmDialog,
  EmptyState,
  Input,
  NoSePudoLeer,
  Seccion,
  SkeletonTable,
  Table,
  Td,
  Tr,
  formatDateTime,
  formatPhone,
} from '@/components/ui'
import { CLAVE_DEMO, anadirNumero, consultaDemo, quitarNumero, reiniciarDemo } from '@/features/admin/demo/api'
import { BORRADOR_VACIO, faltaEnBorrador, resumenDeReinicio } from '@/features/admin/demo/demo'
import type { BorradorDeNumero, EstadoDeDemo, NumeroDeCapacitacion } from '@/features/admin/demo/demo'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

/**
 * Números de capacitación (20261014100200): los WhatsApp del equipo de
 * Helios que capacita a los médicos en su propia clínica.
 *
 * El médico registra un paciente nuevo con datos inventados y uno de estos
 * números, en su panel o en su bot. Ese paciente nace de prueba: la pregunta
 * llega al WhatsApp de quien capacita, a la clínica no se le paga nada y a
 * medianoche se borran del todo, el paciente y sus órdenes. «Reiniciar» lo hace al
 * momento, entre una capacitación y otra.
 */
export function NumerosDeCapacitacion() {
  const demo = useQuery(consultaDemo())

  if (demo.isPending) return <SkeletonTable rows={3} columns={4} />
  if (demo.isError) {
    return (
      <Card>
        <NoSePudoLeer onReintentar={() => void demo.refetch()} />
      </Card>
    )
  }
  return <Pantalla estado={demo.data} />
}

type Reinicio = { numero: NumeroDeCapacitacion | null }

function Pantalla({ estado }: { estado: EstadoDeDemo }) {
  const esSuperAdmin = useIsSuperAdmin()
  const motivoApagado = esSuperAdmin ? undefined : SOLO_SUPER_ADMIN
  const [anadiendo, setAnadiendo] = useState(false)
  const [quitando, setQuitando] = useState<NumeroDeCapacitacion | null>(null)
  const [reiniciando, setReiniciando] = useState<Reinicio | null>(null)
  const ultimo = estado.ultimoReinicio

  return (
    <div className="flex flex-col gap-shell-gap-block">
      <Callout tone="info" titulo="Cómo se usa en una capacitación">
        El médico registra un paciente nuevo con datos inventados y, como teléfono, el WhatsApp de quien capacita. Ese
        paciente queda de prueba: la pregunta llega a ese WhatsApp, a la clínica no se le paga nada y no cuenta en
        ninguna cifra. A medianoche se borra todo, paciente y órdenes, y la cédula vuelve a estar libre. Usen cédulas inventadas que
        empiecen por 99 (V-99123456): una cédula real llevaría a un paciente real.
      </Callout>

      <Seccion
        titulo="Números de capacitación"
        info="Un paciente que se registre con uno de estos WhatsApp, en cualquier clínica, nace de prueba."
        controles={
          <>
            <Button
              size="sm"
              variant="outlined"
              disabled={!esSuperAdmin || estado.numeros.length === 0}
              motivoApagado={motivoApagado}
              onClick={() => setReiniciando({ numero: null })}
            >
              <RotateCcw size={14} /> Reiniciar todos
            </Button>
            <Button size="sm" disabled={!esSuperAdmin} motivoApagado={motivoApagado} onClick={() => setAnadiendo(true)}>
              <Plus size={14} /> Añadir número
            </Button>
          </>
        }
      >
        {estado.numeros.length === 0 ? (
          <EmptyState
            icon={<Phone size={40} />}
            title="Todavía no hay números de capacitación"
            description="Añade el WhatsApp de cada persona que da capacitaciones."
          />
        ) : (
          <Table headers={['Quién capacita', 'WhatsApp', 'Pacientes de hoy', 'Órdenes abiertas', '']} apilada>
            {estado.numeros.map((n) => (
              <Tr key={n.phone}>
                <Td className="font-medium">{n.label}</Td>
                <Td className="whitespace-nowrap">{formatPhone(n.phone)}</Td>
                <Td>{n.patients}</Td>
                <Td>
                  {n.openOrders}
                  {n.pendingOrders > 0 && (
                    <div className="type-panel-caption text-on-surface-variant">
                      {n.pendingOrders === 1 ? '1 esperando el «sí»' : `${n.pendingOrders} esperando el «sí»`}
                    </div>
                  )}
                </Td>
                <Td className="whitespace-nowrap">
                  <Button
                    size="sm"
                    variant="text"
                    disabled={!esSuperAdmin || n.patients === 0}
                    motivoApagado={motivoApagado}
                    onClick={() => setReiniciando({ numero: n })}
                  >
                    <RotateCcw size={14} /> Reiniciar
                  </Button>
                  <Button
                    size="sm"
                    variant="text"
                    disabled={!esSuperAdmin}
                    motivoApagado={motivoApagado}
                    onClick={() => setQuitando(n)}
                  >
                    <Trash2 size={14} /> Quitar
                  </Button>
                </Td>
              </Tr>
            ))}
          </Table>
        )}

        <p className="mt-3 type-panel-caption text-on-surface-variant">
          {ultimo
            ? `Último reinicio: ${formatDateTime(ultimo.at)} (${ultimo.automatico ? 'el de medianoche' : 'a mano'}). ${resumenDeReinicio(ultimo)}.`
            : 'Todavía no se ha reiniciado nunca. Se reinicia solo cada medianoche.'}
        </p>
        {ultimo && ultimo.sinReiniciar.length > 0 && (
          <ul className="mt-2 list-disc pl-5 type-panel-caption text-error">
            {ultimo.sinReiniciar.map((s, i) => (
              <li key={i}>
                {s.orderNumber ? `Orden ${s.orderNumber}: ` : ''}
                {s.motivo}
              </li>
            ))}
          </ul>
        )}
      </Seccion>

      {anadiendo && <NuevoNumero onClose={() => setAnadiendo(false)} />}
      {quitando && <QuitarNumero numero={quitando} onClose={() => setQuitando(null)} />}
      {reiniciando && <ConfirmarReinicio numero={reiniciando.numero} onClose={() => setReiniciando(null)} />}
    </div>
  )
}

function useAlTerminar(onClose: () => void) {
  const client = useQueryClient()
  return () => {
    void client.invalidateQueries({ queryKey: CLAVE_DEMO })
    void client.invalidateQueries({ queryKey: ['admin-audit'] })
    onClose()
  }
}

function NuevoNumero({ onClose }: { onClose: () => void }) {
  const avisar = useToast()
  const terminar = useAlTerminar(onClose)
  const [b, setB] = useState<BorradorDeNumero>(BORRADOR_VACIO)
  const campo = (k: keyof BorradorDeNumero) => (v: string) => setB((prev) => ({ ...prev, [k]: v }))

  const anadir = useMutation({
    mutationFn: () => anadirNumero(b),
    onSuccess: () => {
      avisar(`Los pacientes nuevos con el ${formatPhone(b.phone)} serán de prueba`)
      terminar()
    },
  })

  return (
    <ConfirmDialog
      title="Añadir número de capacitación"
      summary="Desde ahora, todo paciente nuevo que se registre con este WhatsApp, en cualquier clínica, será de prueba."
      detail={
        <div className="flex flex-col gap-3">
          <Input id="demo-quien" label="Quién capacita" value={b.label} onChange={campo('label')} placeholder="Carla Pérez" />
          <Input
            id="demo-whatsapp"
            label="Su WhatsApp"
            value={b.phone}
            onChange={campo('phone')}
            inputMode="tel"
            placeholder="0414 1234567"
            hint="Si también es médico registrado con este número, tiene que aceptar con el botón «Sí, acepto», no escribiendo «sí»."
          />
        </div>
      }
      bloqueo={faltaEnBorrador(b)}
      confirmLabel="Añadir"
      busy={anadir.isPending}
      error={anadir.isError ? describeError(anadir.error) : undefined}
      onConfirm={() => anadir.mutate()}
      onClose={onClose}
    />
  )
}

function QuitarNumero({ numero, onClose }: { numero: NumeroDeCapacitacion; onClose: () => void }) {
  const avisar = useToast()
  const terminar = useAlTerminar(onClose)

  const quitar = useMutation({
    mutationFn: () => quitarNumero(numero.phone),
    onSuccess: () => {
      avisar(`${formatPhone(numero.phone)} ya no es de capacitación`)
      terminar()
    },
  })

  return (
    <ConfirmDialog
      title={`Quitar el número de ${numero.label}`}
      summary={`Los pacientes nuevos con el ${formatPhone(numero.phone)} volverán a ser reales. Los de prueba que ya tiene se borran a medianoche.`}
      confirmLabel="Quitar"
      danger
      busy={quitar.isPending}
      error={quitar.isError ? describeError(quitar.error) : undefined}
      onConfirm={() => quitar.mutate()}
      onClose={onClose}
    />
  )
}

function ConfirmarReinicio({ numero, onClose }: { numero: NumeroDeCapacitacion | null; onClose: () => void }) {
  const avisar = useToast()
  const terminar = useAlTerminar(onClose)

  const reiniciar = useMutation({
    mutationFn: () => reiniciarDemo(numero?.phone ?? null),
    onSuccess: (r) => {
      avisar(resumenDeReinicio(r))
      terminar()
    },
  })

  return (
    <ConfirmDialog
      title={numero ? `Reiniciar el número de ${numero.label}` : 'Reiniciar todos los números'}
      summary="Se borran del todo los pacientes de prueba de este número y sus órdenes, también la que esté esperando el «sí». Sus cédulas vuelven a estar libres y las órdenes desaparecen de la lista del médico."
      confirmLabel="Reiniciar"
      busy={reiniciar.isPending}
      error={reiniciar.isError ? describeError(reiniciar.error) : undefined}
      onConfirm={() => reiniciar.mutate()}
      onClose={onClose}
    />
  )
}
