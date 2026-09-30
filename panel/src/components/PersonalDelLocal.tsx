import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Copy, KeyRound, Pencil, RefreshCw, Trash2, UserPlus, Users } from 'lucide-react'

import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Card,
  ConfirmDialog,
  EmptyState,
  ErrorBox,
  IconButton,
  Input,
  Select,
  SkeletonList,
  formatDateTime,
  formatPhone,
} from '@/components/ui'
import { generatePassword } from '@/features/admin/password'
import {
  ROL,
  ROLES,
  addStaff,
  fetchStaff,
  removeStaff,
  setStaffPassword,
  updateStaff,
} from '@/features/merchant/staff'
import type { StaffMember } from '@/features/merchant/staff'
import type { MerchantRole } from '@/features/auth/session'
import { describeError } from '@/lib/supabase'

/**
 * El personal de un local: quién entra al panel y con qué llaves.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * UNA pantalla montada en dos sitios: la pestaña Personal de la ficha del
 * comercio en el super admin, y la pantalla Personal del panel del local.
 *
 * No hay ninguna rama por panel a propósito. Quién puede hacer qué lo decide
 * el servidor —`can_manage_merchant_staff`— y si la pantalla lo volviera a
 * decidir por su cuenta, habría dos versiones de la regla y tarde o temprano
 * una diría que sí donde la otra dice que no. Lo único que el panel sabe es
 * `isSelf`, que viene de la propia respuesta, y lo usa para apagar botones
 * antes de que el servidor los rechace.
 *
 * La contraseña se enseña UNA vez y en claro. No es un descuido: el servidor
 * guarda el hash y no la devuelve nunca más, así que si se cierra el aviso
 * sin copiarla hay que generar otra.
 */
export function PersonalDelLocal({ merchantId }: { merchantId: string }) {
  const queryClient = useQueryClient()
  const [anadiendo, setAnadiendo] = useState(false)
  const [editando, setEditando] = useState<StaffMember | null>(null)
  const [reseteando, setReseteando] = useState<StaffMember | null>(null)
  const [quitando, setQuitando] = useState<StaffMember | null>(null)

  const query = useQuery({
    queryKey: ['merchant-staff', merchantId],
    queryFn: () => fetchStaff(merchantId),
  })

  function refrescar() {
    void queryClient.invalidateQueries({ queryKey: ['merchant-staff', merchantId] })
    // La ficha del comercio en el super admin trae el personal por su lado.
    void queryClient.invalidateQueries({ queryKey: ['merchant-detail', merchantId] })
    void queryClient.invalidateQueries({ queryKey: ['merchants'] })
  }

  if (query.isLoading) return <SkeletonList rows={3} />

  if (query.isError) {
    return (
      <ErrorBox
        title="No se pudo leer el personal"
        detail={describeError(query.error)}
      />
    )
  }

  const personal = query.data ?? []

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="max-w-prose type-panel-body text-on-surface-variant">
          Quién puede entrar al panel de esta clínica y qué puede hacer dentro. Cada
          cuenta es personal: por ella se sabe quién generó cada financiamiento.
        </p>
        <Button size="md" onClick={() => setAnadiendo(true)}>
          <UserPlus size={16} />
          Añadir
        </Button>
      </div>

      {personal.length === 0 ? (
        <EmptyState
          icon={<Users size={44} />}
          title="Todavía no hay nadie"
          description="Sin personal, esta clínica no puede generar financiamientos. Añade al menos una cuenta de secretaria."
        />
      ) : (
        <div className="flex flex-col gap-2">
          {personal.map((s) => (
            <Fila
              key={s.userId}
              miembro={s}
              onEditar={() => setEditando(s)}
              onResetear={() => setReseteando(s)}
              onQuitar={() => setQuitando(s)}
            />
          ))}
        </div>
      )}

      {anadiendo && (
        <Alta
          merchantId={merchantId}
          onDone={refrescar}
          onClose={() => setAnadiendo(false)}
        />
      )}

      {editando && (
        <Edicion
          merchantId={merchantId}
          miembro={editando}
          onDone={refrescar}
          onClose={() => setEditando(null)}
        />
      )}

      {reseteando && (
        <Reseteo
          merchantId={merchantId}
          miembro={reseteando}
          onClose={() => setReseteando(null)}
        />
      )}

      {quitando && (
        <Baja
          merchantId={merchantId}
          miembro={quitando}
          onDone={refrescar}
          onClose={() => setQuitando(null)}
        />
      )}
    </div>
  )
}

// ── La fila ────────────────────────────────────────────────────────────────

/** Por qué no se puede dar de baja a quien está mirando. Lo dice también el servidor. */
const NO_A_SI_MISMO = 'No puedes darte de baja a ti mismo: que lo haga otro administrador o el equipo de Helios.'

function Fila({
  miembro,
  onEditar,
  onResetear,
  onQuitar,
}: {
  miembro: StaffMember
  onEditar: () => void
  onResetear: () => void
  onQuitar: () => void
}) {
  const rol = ROL[miembro.role]
  const quien = miembro.name ?? miembro.email ?? 'esta persona'

  return (
    <div className="flex flex-wrap items-center gap-x-4 gap-y-3 rounded-[var(--radius-panel-card)] bg-shell-card p-4">
      <div className="min-w-48 flex-1">
        <p className="flex flex-wrap items-center gap-2 type-panel-body font-semibold text-on-surface">
          {miembro.name ?? 'Sin nombre'}
          {miembro.isSelf && <Badge tone="brand">Tú</Badge>}
        </p>
        <p className="type-panel-body text-on-surface-variant">
          {/* Solo las cuentas antiguas tienen teléfono y no correo: el alta de
              personal buscaba por teléfono en vez de crear la cuenta. */}
          {contactoDe(miembro)}
        </p>
      </div>

      <div className="min-w-48 flex-1">
        <p className="type-panel-body text-on-surface">
          {rol.label}
          {miembro.branch && (
            <span className="text-on-surface-variant"> · {miembro.branch}</span>
          )}
        </p>
        <p className="type-panel-body text-on-surface-variant">{rol.hace}</p>
      </div>

      <p className="hidden type-panel-body text-on-surface-variant lg:block">
        Desde {formatDateTime(miembro.createdAt)}
      </p>

      <div className="flex items-center gap-1">
        <IconButton variant="text" label={`Editar a ${quien}`} onClick={onEditar}>
          <Pencil size={18} />
        </IconButton>

        <IconButton
          variant="text"
          label={`Contraseña nueva para ${quien}`}
          onClick={onResetear}
        >
          <KeyRound size={18} />
        </IconButton>

        {/* Darse de baja a uno mismo dejaría al local sin nadie que pueda
            gestionar su propio personal: lo rechaza el servidor, y aquí se
            apaga con el motivo escrito para no dejar pulsar y fallar. */}
        <IconButton
          variant="danger"
          label={`Dar de baja a ${quien}`}
          disabled={miembro.isSelf}
          title={miembro.isSelf ? NO_A_SI_MISMO : undefined}
          onClick={onQuitar}
        >
          <Trash2 size={18} />
        </IconButton>
      </div>

      {miembro.isSelf && (
        <p className="w-full text-right type-label-medium text-on-surface-variant">
          {NO_A_SI_MISMO}
        </p>
      )}
    </div>
  )
}

/**
 * Con qué se identifica esta cuenta.
 *
 * El correo es lo normal desde 2026-08-22. Las cuentas de antes se dieron de
 * alta buscando por teléfono y no tienen ninguno, así que cae al teléfono; y
 * si tampoco, se dice que no hay — en vez de un hueco que parece un fallo de
 * carga.
 */
function contactoDe(miembro: StaffMember): string {
  if (miembro.email) return miembro.email
  if (miembro.phone) return formatPhone(miembro.phone)
  return 'sin contacto'
}

/**
 * La contraseña, escrita o generada.
 *
 * Un solo campo y no dos modos. Nace con una generada —que es lo correcto por
 * defecto: una contraseña tecleada con prisa delante de alguien acaba siendo
 * la misma en los cinco locales— pero se puede escribir encima sin cambiar de
 * pestaña ni marcar nada. Quien quiera otra generada pulsa al lado.
 *
 * Va en claro y sin ocultar a propósito. No es la contraseña de quien mira:
 * es la de otra persona, y el gesto siguiente es leerla en voz alta o pegarla
 * en un chat. Ocultarla solo obligaría a destaparla.
 *
 * El mínimo son ocho y lo impone el servidor; aquí se dice antes de pulsar
 * para no gastar un viaje en enterarse.
 */
const MINIMO = 8

function CampoContrasena({
  id,
  value,
  onChange,
}: {
  id: string
  value: string
  onChange: (value: string) => void
}) {
  // Incluye el campo vacío a propósito: es el mismo caso que una demasiado
  // corta —el botón está apagado— y con dos avisos distintos para el mismo
  // bloqueo, el de abajo parecería que no va con el de arriba.
  const corta = value.length < MINIMO

  return (
    <div>
      <div className="flex items-end gap-2">
        <Input
          id={id}
          label="Contraseña"
          value={value}
          onChange={onChange}
          placeholder={`Al menos ${MINIMO} caracteres`}
          // Es la credencial de OTRA persona: sin esto, el gestor de
          // contraseñas del operador se ofrece a guardarla como suya.
          autoComplete="off"
          error={corta}
          className="flex-1"
        />
        <Button
          size="md"
          variant="tonal"
          onClick={() => onChange(generatePassword())}
          title="Genera una contraseña nueva en el campo"
        >
          <RefreshCw size={16} />
          Generar
        </Button>
      </div>

      <p
        className={`mt-2 type-panel-body ${
          corta ? 'text-warning' : 'text-on-surface-variant'
        }`}
      >
        {corta
          ? `Muy corta: necesita al menos ${MINIMO} caracteres.`
          : 'Escríbela o genera una. Al terminar se enseña para copiarla.'}
      </p>
    </div>
  )
}

// ── Alta ───────────────────────────────────────────────────────────────────

function Alta({
  merchantId,
  onDone,
  onClose,
}: {
  merchantId: string
  onDone: () => void
  onClose: () => void
}) {
  const [fullName, setFullName] = useState('')
  const [email, setEmail] = useState('')
  const [role, setRole] = useState<MerchantRole>('cajero')
  // Nace generada y se puede escribir encima. El inicializador es una función
  // para que solo corra al montar: si se regenerara en cada repintado, la que
  // se copia no sería la que se guarda.
  const [password, setPassword] = useState(() => generatePassword())
  const [creada, setCreada] = useState(false)

  const mutation = useMutation({
    mutationFn: () => addStaff({ merchantId, email, password, fullName, role }),
    onSuccess: () => {
      setCreada(true)
      onDone()
    },
  })

  const correoOk = /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email.trim())

  // Creada: el diálogo deja de ser un formulario y pasa a ser el único
  // momento en que esta contraseña existe en algún sitio legible.
  if (creada) {
    return (
      <ConfirmDialog
        title="Cuenta creada"
        summary={`${fullName || email} ya puede entrar al panel de esta clínica como ${ROL[role].label.toLowerCase()}.`}
        detail={<Credenciales email={email.trim()} password={password} />}
        confirmLabel="Ya la copié"
        onConfirm={onClose}
        onClose={onClose}
      />
    )
  }

  return (
    <ConfirmDialog
      title="Añadir personal"
      summary="Se crea una cuenta con este correo y la contraseña que pongas aquí. Después no vuelve a mostrarse."
      detail={
        <div className="flex flex-col gap-3">
          <Input
            id="alta-nombre"
            label="Nombre y apellido"
            value={fullName}
            onChange={setFullName}
            placeholder="María González"
            autoFocus
          />
          <Input
            id="alta-correo"
            label="Correo"
            value={email}
            onChange={setEmail}
            placeholder="maria@ejemplo.com"
            type="email"
            error={email !== '' && !correoOk}
          />
          <Select
            id="alta-rol"
            label="Rol"
            value={role}
            options={ROLES}
            onChange={setRole}
          />
          <p className="type-panel-body text-on-surface-variant">{ROL[role].hace}</p>

          <CampoContrasena id="alta-clave" value={password} onChange={setPassword} />
        </div>
      }
      confirmLabel="Crear la cuenta"
      bloqueo={
        fullName.trim() === ''
          ? 'Falta el nombre'
          : !correoOk
            ? 'El correo no es válido'
            : password.length < MINIMO
              ? `La contraseña necesita al menos ${MINIMO} caracteres`
              : undefined
      }
      busy={mutation.isPending}
      error={mutation.isError ? describeError(mutation.error) : undefined}
      onConfirm={() => mutation.mutate()}
      onClose={onClose}
    />
  )
}

// ── Edición ────────────────────────────────────────────────────────────────

function Edicion({
  merchantId,
  miembro,
  onDone,
  onClose,
}: {
  merchantId: string
  miembro: StaffMember
  onDone: () => void
  onClose: () => void
}) {
  const avisar = useToast()
  const [fullName, setFullName] = useState(miembro.name ?? '')
  const [role, setRole] = useState<MerchantRole>(miembro.role)

  const mutation = useMutation({
    mutationFn: () =>
      updateStaff({ merchantId, userId: miembro.userId, fullName, role }),
    onSuccess: () => {
      avisar(`${fullName || 'La cuenta'} queda como ${ROL[role].label.toLowerCase()}`)
      onDone()
      onClose()
    },
  })

  const cambioDeRol = role !== miembro.role
  const cambioDeNombre = fullName.trim() !== (miembro.name ?? '')

  return (
    <ConfirmDialog
      title="Editar"
      summary={`${contactoDe(miembro)} entra al panel de esta clínica.`}
      detail={
        <div className="flex flex-col gap-3">
          <Input
            id="editar-nombre"
            label="Nombre y apellido"
            value={fullName}
            onChange={setFullName}
            autoFocus
          />

          <Select
            id="editar-rol"
            label="Rol"
            value={role}
            options={ROLES}
            onChange={setRole}
          />
          <p className="type-panel-body text-on-surface-variant">{ROL[role].hace}</p>

          {/* Cambiarse el rol a uno mismo deja al local sin nadie que pueda
              gestionar su personal. Lo rechaza el servidor; aquí se dice
              antes de pulsar. */}
          {miembro.isSelf && cambioDeRol && (
            <p className="type-panel-body text-warning">
              No puedes cambiarte el rol a ti mismo. Que lo haga otro administrador o el
              equipo de Helios.
            </p>
          )}

          {cambioDeRol && !miembro.isSelf && (
            <p className="type-panel-body text-on-surface-variant">
              El cambio es inmediato: la próxima pantalla que abra ya será la de{' '}
              {ROL[role].label.toLowerCase()}.
            </p>
          )}
        </div>
      }
      confirmLabel="Guardar"
      bloqueo={
        fullName.trim() === ''
          ? 'Falta el nombre'
          : miembro.isSelf && cambioDeRol
            ? 'No puedes cambiarte el rol a ti mismo'
            : !cambioDeRol && !cambioDeNombre
              ? 'No has cambiado nada'
              : undefined
      }
      busy={mutation.isPending}
      error={mutation.isError ? describeError(mutation.error) : undefined}
      onConfirm={() => mutation.mutate()}
      onClose={onClose}
    />
  )
}

// ── Contraseña nueva ───────────────────────────────────────────────────────

function Reseteo({
  merchantId,
  miembro,
  onClose,
}: {
  merchantId: string
  miembro: StaffMember
  onClose: () => void
}) {
  const [password, setPassword] = useState(() => generatePassword())
  const [hecho, setHecho] = useState(false)

  const mutation = useMutation({
    mutationFn: () =>
      setStaffPassword({ merchantId, userId: miembro.userId, password }),
    onSuccess: () => setHecho(true),
  })

  const quien = miembro.name ?? miembro.email ?? 'Esta persona'

  if (hecho) {
    return (
      <ConfirmDialog
        title="Contraseña cambiada"
        summary={`La anterior ya no sirve. ${quien} entra con esta.`}
        detail={<Credenciales email={miembro.email} password={password} />}
        confirmLabel="Ya la copié"
        onConfirm={onClose}
        onClose={onClose}
      />
    )
  }

  return (
    <ConfirmDialog
      title="Cambiar la contraseña"
      summary={`${quien} dejará de poder entrar con la que tiene.`}
      detail={
        <div className="flex flex-col gap-3">
          <p className="type-panel-body leading-5 text-on-surface-variant">
            Es lo que se hace cuando alguien la olvida. No hace falta saber la
            anterior — nadie la sabe, la base solo guarda su huella.
          </p>

          <CampoContrasena id="reset-clave" value={password} onChange={setPassword} />
        </div>
      }
      confirmLabel="Cambiar la contraseña"
      bloqueo={
        password.length < MINIMO
          ? `La contraseña necesita al menos ${MINIMO} caracteres`
          : undefined
      }
      busy={mutation.isPending}
      error={mutation.isError ? describeError(mutation.error) : undefined}
      onConfirm={() => mutation.mutate()}
      onClose={onClose}
    />
  )
}

/**
 * El correo y la contraseña, para copiarlos.
 *
 * En monoespaciada y con botón de copiar porque lo siguiente que pasa es que
 * alguien las teclea en un WhatsApp: una ele y un uno se confunden, y una
 * contraseña mal copiada es otra llamada.
 */
function Credenciales({
  email,
  password,
}: {
  email: string | null
  password: string
}) {
  const avisar = useToast()

  return (
    <Card tone="inset" className="flex flex-col gap-3">
      {email && (
        <div>
          <p className="type-panel-label text-on-surface-variant">Correo</p>
          <p className="font-mono type-panel-body text-on-surface">{email}</p>
        </div>
      )}

      <div>
        <p className="type-panel-label text-on-surface-variant">Contraseña</p>
        <div className="flex flex-wrap items-center gap-3">
          <p className="font-mono type-panel-body tracking-wide text-on-surface">
            {password}
          </p>
          <Button
            size="sm"
            variant="tonal"
            onClick={() => {
              void navigator.clipboard
                .writeText(password)
                .then(() => avisar('Contraseña copiada'))
                // Sin permiso de portapapeles —o sin HTTPS— no se puede
                // copiar, pero la contraseña está a la vista para teclearla.
                .catch(() => avisar('No se pudo copiar: cópiala a mano'))
            }}
          >
            <Copy size={14} />
            Copiar
          </Button>
        </div>
      </div>

      <p className="type-panel-body text-on-surface-variant">
        Pásasela por otro canal. No vuelve a mostrarse.
      </p>
    </Card>
  )
}

// ── Baja ───────────────────────────────────────────────────────────────────

function Baja({
  merchantId,
  miembro,
  onDone,
  onClose,
}: {
  merchantId: string
  miembro: StaffMember
  onDone: () => void
  onClose: () => void
}) {
  const avisar = useToast()
  const quien = miembro.name ?? miembro.email ?? 'Esta persona'

  const mutation = useMutation({
    mutationFn: () => removeStaff({ merchantId, userId: miembro.userId }),
    onSuccess: () => {
      avisar(`${quien} ya no entra al panel de la clínica`)
      onDone()
      onClose()
    },
  })

  return (
    <ConfirmDialog
      title="Dar de baja"
      summary={`${quien} deja de poder entrar al panel de esta clínica, con efecto inmediato.`}
      detail={
        <p className="type-panel-body leading-5 text-on-surface-variant">
          La cuenta no se borra: los financiamientos que generó siguen apuntando a ella, y sin
          eso el historial no sabría quién cobró. Si vuelve, se le da de alta otra
          vez.
        </p>
      }
      confirmLabel="Dar de baja"
      danger
      busy={mutation.isPending}
      error={mutation.isError ? describeError(mutation.error) : undefined}
      onConfirm={() => mutation.mutate()}
      onClose={onClose}
    />
  )
}
