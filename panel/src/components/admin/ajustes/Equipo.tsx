import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Eye, EyeOff } from 'lucide-react'

import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  CLASE_CAMPO,
  Card,
  ConfirmDialog,
  DataLabel,
  ErrorBox,
  Input,
  Seccion,
  Segmented,
  SkeletonTable,
  Table,
  Td,
  Tr,
  bordeDeCampo,
  formatDateTime,
} from '@/components/ui'
import {
  addTeamMember,
  fetchTeam,
  restoreTeamMember,
  revokeTeamMember,
} from '@/features/admin/ops'
import type { RolDelPanel, TeamMember } from '@/features/admin/ops'
import { generatePassword } from '@/features/admin/password'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { useSession } from '@/features/auth/session'
import { describeError } from '@/lib/supabase'

const ROLES: Array<{ value: RolDelPanel; label: string }> = [
  { value: 'operador', label: 'Operador' },
  { value: 'super_admin', label: 'Super admin' },
]

function rotuloDeRol(rol: RolDelPanel): string {
  return rol === 'super_admin' ? 'Super admin' : 'Operador'
}

/**
 * Quién entra al panel.
 *
 * Crear un super admin es crítico: esa persona podrá mover dinero, cambiar las
 * reglas y dar acceso a otras. Revocar y devolver un acceso piden motivo.
 */
export function Equipo() {
  const query = useQuery({ queryKey: ['admin-team'], queryFn: fetchTeam })
  const isSuperAdmin = useIsSuperAdmin()
  const session = useSession()
  const yo = session?.user.id ?? null

  return (
    <div className="flex flex-col gap-shell-gap-block">
      <DarAcceso isSuperAdmin={isSuperAdmin} />

      <Seccion
        titulo="Quién entra a este panel"
        info="Retirar un acceso o devolverlo pide motivo y queda en la bitácora. Las acciones de quien pierde el acceso se conservan."
      >
        {query.isLoading && <SkeletonTable rows={5} columns={7} />}
        {query.isError && (
          <ErrorBox title="No se pudo leer el equipo" detail={describeError(query.error)} />
        )}
        {query.data && (
          <TablaDelEquipo miembros={query.data} isSuperAdmin={isSuperAdmin} yo={yo} />
        )}
      </Seccion>
    </div>
  )
}

function DarAcceso({ isSuperAdmin }: { isSuperAdmin: boolean }) {
  const avisar = useToast()
  const client = useQueryClient()

  const [name, setName] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState(() => generatePassword())
  const [showPassword, setShowPassword] = useState(false)
  const [role, setRole] = useState<RolDelPanel>('operador')
  const [confirmando, setConfirmando] = useState(false)

  const add = useMutation({
    // Un operador se crea sin diálogo y sin motivo; un super admin, con los dos.
    mutationFn: (nota: string | null) =>
      addTeamMember({ email: email.trim(), password, fullName: name.trim(), role, note: nota }),
    onSuccess: () => {
      avisar(`${name.trim() || email.trim()} ya puede entrar al panel como ${rotuloDeRol(role).toLowerCase()}.`)
      setName('')
      setEmail('')
      setPassword(generatePassword())
      setRole('operador')
      setConfirmando(false)
      void client.invalidateQueries({ queryKey: ['admin-team'] })
    },
  })

  const motivoApagado = !isSuperAdmin
    ? SOLO_SUPER_ADMIN
    : !name.trim()
      ? 'Falta el nombre.'
      : !email.includes('@')
        ? 'Falta un correo válido.'
        : password.length < 8
          ? 'La contraseña provisional necesita al menos 8 caracteres.'
          : undefined

  return (
    <Seccion
      titulo="Dar acceso"
      info="Un operador registra y aprueba pagos, manda los avisos y trabaja la cobranza. Un super admin además mueve dinero, cambia las reglas y da acceso a otras personas; crearlo pide motivo y confirmación."
    >
      <Card>
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          <Input id="team-name" label="Nombre" value={name} onChange={setName} placeholder="María Pérez" />
          <Input
            id="team-email"
            label="Correo"
            value={email}
            onChange={setEmail}
            type="email"
            placeholder="maria@helios.com"
          />
        </div>

        <div className="mt-4">
          <label htmlFor="team-password" className="mb-shell-gap-stack block">
            <DataLabel>Contraseña provisional</DataLabel>
          </label>
          <div className="flex gap-2">
            <div className="relative flex-1">
              {/* El campo del kit sin el ojo: el relleno de la derecha lo
                  pone el botón, así que pisa al de `CLASE_CAMPO`. */}
              <input
                id="team-password"
                type={showPassword ? 'text' : 'password'}
                value={password}
                autoComplete="off"
                aria-describedby="team-password-aviso"
                onChange={(e) => setPassword(e.target.value)}
                className={`h-panel-control-md ${CLASE_CAMPO} ${bordeDeCampo(false)} pr-11`}
              />
              <button
                type="button"
                onClick={() => setShowPassword((v) => !v)}
                aria-label={showPassword ? 'Ocultar la contraseña' : 'Mostrar la contraseña'}
                className="absolute inset-y-0 right-0 flex w-11 items-center justify-center text-on-surface-variant hover:text-on-surface"
              >
                {showPassword ? <EyeOff size={18} /> : <Eye size={18} />}
              </button>
            </div>
            <Button variant="tonal" size="md" onClick={() => setPassword(generatePassword())}>
              Generar otra
            </Button>
          </div>
          {/* Escrito: después de crear la cuenta no hay forma de volver a verla. */}
          <p id="team-password-aviso" className="mt-2 type-panel-caption text-on-surface-variant">
            Entrégasela por otro canal: al crear la cuenta deja de mostrarse.
          </p>
        </div>

        <div className="mt-4 flex flex-col gap-shell-gap-stack">
          <DataLabel>Rol</DataLabel>
          <Segmented etiqueta="Rol" options={ROLES} value={role} onChange={setRole} />
        </div>

        {add.isError && !confirmando && (
          <div className="mt-4">
            <ErrorBox title="No se pudo dar acceso" detail={describeError(add.error)} />
          </div>
        )}

        <Button
          className="mt-4"
          size="md"
          disabled={add.isPending || motivoApagado !== undefined}
          motivoApagado={motivoApagado}
          // Un operador se da de alta de un clic; un super admin, no.
          onClick={() => (role === 'super_admin' ? setConfirmando(true) : add.mutate(null))}
        >
          {add.isPending ? 'Creando…' : 'Crear la cuenta y dar acceso'}
        </Button>

        {confirmando && (
          <ConfirmDialog
            nivel="critico"
            title="Dar acceso de super admin"
            summary={`${name.trim()} podrá mover dinero, cambiar la tasa, los parámetros y la cuenta de cobro, y dar o quitar acceso a otras personas.`}
            detail={
              <ul className="flex flex-col gap-1 type-panel-body text-on-surface-variant">
                <li>Correo: {email.trim()}</li>
                <li>Rol: Super admin</li>
              </ul>
            }
            reasonPlaceholder="Se incorpora como responsable de caja"
            confirmLabel="Crear el super admin"
            busy={add.isPending}
            error={add.isError ? describeError(add.error) : undefined}
            onConfirm={(nota) => add.mutate(nota)}
            onClose={() => setConfirmando(false)}
          />
        )}
      </Card>
    </Seccion>
  )
}

type Cambio = { miembro: TeamMember; accion: 'revocar' | 'devolver' }

function TablaDelEquipo({
  miembros,
  isSuperAdmin,
  yo,
}: {
  miembros: TeamMember[]
  isSuperAdmin: boolean
  yo: string | null
}) {
  const avisar = useToast()
  const client = useQueryClient()
  const [cambio, setCambio] = useState<Cambio | null>(null)

  const mutation = useMutation({
    mutationFn: ({ c, nota }: { c: Cambio; nota: string }) =>
      c.accion === 'revocar'
        ? revokeTeamMember(c.miembro.userId, nota)
        : restoreTeamMember(c.miembro.userId, nota),
    onSuccess: (_data, { c }) => {
      const quien = c.miembro.fullName ?? c.miembro.email ?? 'Esa persona'
      avisar(
        c.accion === 'revocar'
          ? `${quien} ya no puede entrar al panel.`
          : `${quien} vuelve a poder entrar al panel.`,
      )
      setCambio(null)
      void client.invalidateQueries({ queryKey: ['admin-team'] })
    },
  })

  return (
    <>
      <Table headers={['Persona', 'Correo', 'Rol', 'Acciones', 'Última acción', 'Estado', '']}>
        {miembros.map((m) => {
          const soyYo = m.userId === yo
          const motivoApagado = !isSuperAdmin
            ? SOLO_SUPER_ADMIN
            : soyYo && m.isActive
              ? 'No puedes revocar tu propio acceso.'
              : undefined
          return (
            <Tr key={m.userId}>
              <Td className="font-medium">{m.fullName ?? 'Sin nombre'}</Td>
              <Td className="font-mono type-panel-caption">{m.email ?? '—'}</Td>
              <Td>
                {/* Un rol no es un estado: neutro, y lo distingue el texto. */}
                <Badge>{rotuloDeRol(m.role)}</Badge>
              </Td>
              <Td className="tabular-nums text-on-surface-variant">{m.actionCount}</Td>
              <Td className="whitespace-nowrap type-panel-caption text-on-surface-variant">
                {formatDateTime(m.lastActionAt)}
              </Td>
              <Td>
                {m.isActive ? (
                  <Badge tone="success" icono>
                    Activo
                  </Badge>
                ) : (
                  <Badge>Revocado</Badge>
                )}
              </Td>
              <Td>
                <Button
                  size="sm"
                  variant="text"
                  disabled={motivoApagado !== undefined}
                  motivoApagado={motivoApagado}
                  onClick={() =>
                    setCambio({ miembro: m, accion: m.isActive ? 'revocar' : 'devolver' })
                  }
                >
                  {m.isActive ? 'Revocar' : 'Devolver el acceso'}
                </Button>
              </Td>
            </Tr>
          )
        })}
      </Table>

      {cambio && (
        <ConfirmDialog
          nivel="sensible"
          title={cambio.accion === 'revocar' ? 'Retirar el acceso al panel' : 'Devolver el acceso al panel'}
          summary={
            cambio.accion === 'revocar'
              ? `${cambio.miembro.fullName ?? cambio.miembro.email ?? 'Esta persona'} dejará de poder entrar al panel. Su sesión abierta deja de servir en cuanto vuelva a cargar.`
              : `${cambio.miembro.fullName ?? cambio.miembro.email ?? 'Esta persona'} volverá a entrar al panel con el mismo rol que tenía.`
          }
          detail={
            <ul className="flex flex-col gap-1 type-panel-body text-on-surface-variant">
              <li>Correo: {cambio.miembro.email ?? '—'}</li>
              <li>Rol: {rotuloDeRol(cambio.miembro.role)}</li>
              <li>
                {cambio.miembro.actionCount}{' '}
                {cambio.miembro.actionCount === 1 ? 'acción registrada' : 'acciones registradas'} en
                la bitácora, que se conservan.
              </li>
            </ul>
          }
          confirmLabel={cambio.accion === 'revocar' ? 'Retirar el acceso' : 'Devolver el acceso'}
          danger={cambio.accion === 'revocar'}
          busy={mutation.isPending}
          error={mutation.isError ? describeError(mutation.error) : undefined}
          onConfirm={(nota) => mutation.mutate({ c: cambio, nota })}
          onClose={() => setCambio(null)}
        />
      )}
    </>
  )
}
