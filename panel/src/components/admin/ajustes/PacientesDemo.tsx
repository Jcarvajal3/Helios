import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { RotateCcw, UserPlus, Users } from 'lucide-react'

import { useToast } from '@/components/Toast'
import {
  Badge,
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
  formatDocument,
  formatPhone,
  formatUsd,
} from '@/components/ui'
import { CLAVE_DEMO, cambiarLimiteDemo, consultaDemo, crearPacienteDemo, reiniciarDemo } from '@/features/admin/demo/api'
import { BORRADOR_VACIO, faltaEnBorrador, resumenDeReinicio } from '@/features/admin/demo/demo'
import type { BorradorDePacienteDemo, EstadoDeDemo, PacienteDemo } from '@/features/admin/demo/demo'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

const MOTIVO_NO_DISPONIBLE: Record<string, string> = {
  cuota_vencida: 'Tiene una cuota vencida: reinícialo',
  estado: 'La cuenta no está activa',
  bloqueo: 'Bloqueado o en mantenimiento',
}

/**
 * Pacientes demo (20261014100100): con ellos el equipo de Helios capacita a
 * los médicos en su propia clínica, con su panel y su bot.
 *
 * El médico busca la cédula demo y registra una consulta; la pregunta llega
 * al WhatsApp de quien capacita, que contesta «sí». Las órdenes demo no le
 * liquidan nada a la clínica y se revierten solas cada noche a las 23:30; el
 * botón «Reiniciar» lo hace al momento, entre una capacitación y otra.
 */
export function PacientesDemo() {
  const demo = useQuery(consultaDemo())

  if (demo.isPending) return <SkeletonTable rows={3} columns={5} />
  if (demo.isError) {
    return (
      <Card>
        <NoSePudoLeer onReintentar={() => void demo.refetch()} />
      </Card>
    )
  }
  return <PantallaDeDemo estado={demo.data} />
}

type Reinicio = { quien: PacienteDemo | null }

function PantallaDeDemo({ estado }: { estado: EstadoDeDemo }) {
  const esSuperAdmin = useIsSuperAdmin()
  const motivoApagado = esSuperAdmin ? undefined : SOLO_SUPER_ADMIN
  const [creando, setCreando] = useState(false)
  const [cambiandoLimite, setCambiandoLimite] = useState(false)
  const [reiniciando, setReiniciando] = useState<Reinicio | null>(null)
  const ultimo = estado.ultimoReinicio

  return (
    <div className="flex flex-col gap-shell-gap-block">
      <Callout tone="info" titulo="Cómo se usa en una capacitación">
        El médico busca la cédula demo en su panel o escribe a su bot y registra una consulta. La pregunta llega al
        WhatsApp de quien capacita, que contesta «sí». Las órdenes demo no le pagan nada a la clínica y se revierten
        solas cada noche a las 23:30. Cada paciente demo admite una sola pregunta esperando a la vez.
      </Callout>

      <Seccion
        titulo="Pacientes demo"
        info="Pacientes de prueba ligados al WhatsApp del equipo de Helios. Sirven en cualquier clínica y no cuentan en ninguna cifra."
        controles={
          <>
            <Button
              size="sm"
              variant="outlined"
              disabled={!esSuperAdmin || estado.pacientes.length === 0}
              motivoApagado={motivoApagado}
              onClick={() => setReiniciando({ quien: null })}
            >
              <RotateCcw size={14} /> Reiniciar todos
            </Button>
            <Button size="sm" disabled={!esSuperAdmin} motivoApagado={motivoApagado} onClick={() => setCreando(true)}>
              <UserPlus size={14} /> Crear paciente demo
            </Button>
          </>
        }
      >
        {estado.pacientes.length === 0 ? (
          <EmptyState
            icon={<Users size={40} />}
            title="Todavía no hay pacientes demo"
            description="Crea uno por cada persona que da capacitaciones, con su WhatsApp."
          />
        ) : (
          <Table headers={['Paciente', 'Cédula', 'WhatsApp', 'Disponible', 'Órdenes abiertas', '']} apilada>
            {estado.pacientes.map((p) => (
              <Tr key={p.id}>
                <Td className="font-medium">
                  {p.fullName}
                  {p.email && <div className="type-panel-caption text-on-surface-variant">{p.email}</div>}
                </Td>
                <Td className="whitespace-nowrap">{formatDocument(p.documentNumber)}</Td>
                <Td className="whitespace-nowrap">{formatPhone(p.phone)}</Td>
                <Td className="whitespace-nowrap">
                  {p.blockedReason ? (
                    <Badge tone="warning">{MOTIVO_NO_DISPONIBLE[p.blockedReason] ?? 'No disponible'}</Badge>
                  ) : (
                    formatUsd(p.availableUsd)
                  )}
                </Td>
                <Td>
                  {p.openOrders}
                  {p.pendingOrders > 0 && (
                    <div className="type-panel-caption text-on-surface-variant">Esperando el «sí»</div>
                  )}
                </Td>
                <Td>
                  <Button
                    size="sm"
                    variant="text"
                    disabled={!esSuperAdmin || (p.openOrders === 0 && p.pendingOrders === 0)}
                    motivoApagado={motivoApagado}
                    onClick={() => setReiniciando({ quien: p })}
                  >
                    <RotateCcw size={14} /> Reiniciar
                  </Button>
                </Td>
              </Tr>
            ))}
          </Table>
        )}
      </Seccion>

      <Seccion
        titulo="Límite de la demo"
        info="Lo que cada paciente demo puede tener abierto a la vez. Es aparte del límite de los pacientes reales y vuelve entero con cada reinicio."
        controles={
          <Button
            size="sm"
            variant="outlined"
            disabled={!esSuperAdmin}
            motivoApagado={motivoApagado}
            onClick={() => setCambiandoLimite(true)}
          >
            Cambiar
          </Button>
        }
      >
        <Card>
          <p className="type-panel-figure">{formatUsd(estado.limitUsd)}</p>
          <p className="type-panel-caption text-on-surface-variant">
            {ultimo
              ? `Último reinicio: ${formatDateTime(ultimo.at)} (${ultimo.automatico ? 'el de la noche' : 'a mano'}). ${resumenDeReinicio(ultimo)}.`
              : 'Todavía no se ha reiniciado nunca.'}
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
        </Card>
      </Seccion>

      {creando && <NuevoPacienteDemo onClose={() => setCreando(false)} />}
      {cambiandoLimite && <CambiarLimite actual={estado.limitUsd} onClose={() => setCambiandoLimite(false)} />}
      {reiniciando && <ConfirmarReinicio quien={reiniciando.quien} onClose={() => setReiniciando(null)} />}
    </div>
  )
}

function NuevoPacienteDemo({ onClose }: { onClose: () => void }) {
  const avisar = useToast()
  const client = useQueryClient()
  const [b, setB] = useState<BorradorDePacienteDemo>(BORRADOR_VACIO)
  const campo = (k: keyof BorradorDePacienteDemo) => (v: string) => setB((prev) => ({ ...prev, [k]: v }))

  const crear = useMutation({
    mutationFn: () => crearPacienteDemo(b),
    onSuccess: () => {
      avisar(`${b.firstName.trim()} ${b.lastName.trim()} ya se puede usar en cualquier clínica`)
      void client.invalidateQueries({ queryKey: CLAVE_DEMO })
      void client.invalidateQueries({ queryKey: ['admin-audit'] })
      onClose()
    },
  })

  return (
    <ConfirmDialog
      title="Crear paciente demo"
      summary="Las preguntas y los comprobantes de sus órdenes llegan a este WhatsApp y a este correo. Usa una cédula que no sea de nadie, por ejemplo V-99000001."
      detail={
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Input id="demo-cedula" label="Cédula demo" value={b.document} onChange={campo('document')} placeholder="V-99000001" />
          <Input
            id="demo-whatsapp"
            label="WhatsApp de quien capacita"
            value={b.phone}
            onChange={campo('phone')}
            inputMode="tel"
            placeholder="0414 1234567"
          />
          <Input id="demo-nombre" label="Nombre" value={b.firstName} onChange={campo('firstName')} placeholder="Paciente" />
          <Input id="demo-apellido" label="Apellido" value={b.lastName} onChange={campo('lastName')} placeholder="Demo" />
          <div className="sm:col-span-2">
            <Input
              id="demo-correo"
              label="Correo"
              type="email"
              value={b.email}
              onChange={campo('email')}
              placeholder="capacitaciones@conhelios.com"
            />
          </div>
        </div>
      }
      bloqueo={faltaEnBorrador(b)}
      confirmLabel="Crear"
      busy={crear.isPending}
      error={crear.isError ? describeError(crear.error) : undefined}
      onConfirm={() => crear.mutate()}
      onClose={onClose}
    />
  )
}

function CambiarLimite({ actual, onClose }: { actual: number; onClose: () => void }) {
  const avisar = useToast()
  const client = useQueryClient()
  const [valor, setValor] = useState(String(actual))
  const monto = Number(valor.replace(',', '.'))

  const guardar = useMutation({
    mutationFn: () => cambiarLimiteDemo(monto),
    onSuccess: () => {
      avisar(`Límite de la demo: ${formatUsd(monto)}`)
      void client.invalidateQueries({ queryKey: CLAVE_DEMO })
      void client.invalidateQueries({ queryKey: ['admin-audit'] })
      onClose()
    },
  })

  return (
    <ConfirmDialog
      title="Cambiar el límite de la demo"
      summary={`Ahora es ${formatUsd(actual)}. Vale para todos los pacientes demo desde la próxima consulta de cédula.`}
      detail={
        <Input id="demo-limite" label="Límite en dólares" value={valor} onChange={setValor} inputMode="decimal" />
      }
      bloqueo={!Number.isFinite(monto) || monto <= 0 ? 'Escribe un monto mayor que cero.' : undefined}
      confirmLabel="Guardar"
      busy={guardar.isPending}
      error={guardar.isError ? describeError(guardar.error) : undefined}
      onConfirm={() => guardar.mutate()}
      onClose={onClose}
    />
  )
}

function ConfirmarReinicio({ quien, onClose }: { quien: PacienteDemo | null; onClose: () => void }) {
  const avisar = useToast()
  const client = useQueryClient()

  const reiniciar = useMutation({
    mutationFn: () => reiniciarDemo(quien?.id ?? null),
    onSuccess: (r) => {
      avisar(resumenDeReinicio(r))
      void client.invalidateQueries({ queryKey: CLAVE_DEMO })
      void client.invalidateQueries({ queryKey: ['admin-audit'] })
      onClose()
    },
  })

  return (
    <ConfirmDialog
      title={quien ? `Reiniciar a ${quien.fullName}` : 'Reiniciar todos los pacientes demo'}
      summary="Se revierten sus órdenes confirmadas y se anula la pregunta que esté esperando el «sí». El médico las verá como revertidas y el límite vuelve entero."
      confirmLabel="Reiniciar"
      busy={reiniciar.isPending}
      error={reiniciar.isError ? describeError(reiniciar.error) : undefined}
      onConfirm={() => reiniciar.mutate()}
      onClose={onClose}
    />
  )
}
