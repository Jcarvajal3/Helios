import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Copy, KeyRound, MessageCircle, Pencil, RefreshCw, Trash2, UserPlus, Users } from 'lucide-react'

import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Card,
  Checkbox,
  ConfirmDialog,
  EmptyState,
  ErrorBox,
  IconButton,
  Input,
  NoSePudoLeer,
  Select,
  SkeletonList,
  formatDateTime,
  formatPhone,
} from '@/components/ui'
import {
  claveNumerosDelBot,
  consultaNumerosDelBot,
  estadoDelPin,
  registrarNumeroDelBot,
  resetearPinDelBot,
  revocarNumeroDelBot,
  telefonoLegible,
} from '@/features/admin/clinicas/bot'
import type { NumeroDelBot } from '@/features/admin/clinicas/bot'
import { celularAE164 } from '@/features/admin/clinicas/clinicas'
import { generatePassword } from '@/features/admin/password'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import {
  ROL,
  ROLES,
  addStaff,
  enviarBienvenida,
  fetchStaff,
  removeStaff,
  setStaffPassword,
  updateStaff,
} from '@/features/merchant/staff'
import type { ResultadoBienvenida, StaffMember } from '@/features/merchant/staff'
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
 * El acceso al bot de WhatsApp (docs/00 §15.4, contrato §2.7) va dentro de
 * la tarjeta de cada persona, en su alta y en su edición, con `conBot`. Solo
 * lo enciende la ficha del superadmin: registrar un número, resetear el PIN
 * o quitar el acceso lo hace el equipo de Helios (super admin), y el gerente
 * no puede ni leer los números (`admin_staff_whatsapp`).
 *
 * Al crear una cuenta se le manda (si se deja marcado) un correo con sus
 * datos de acceso y cómo usar el bot, con copia oculta a Helios
 * (`merchant_staff_send_welcome`).
 *
 * La contraseña se enseña UNA vez y en claro. No es un descuido: el servidor
 * guarda el hash y no la devuelve nunca más, así que si se cierra el aviso
 * sin copiarla hay que generar otra.
 */
export function PersonalDelLocal({ merchantId, conBot = false }: { merchantId: string; conBot?: boolean }) {
  const queryClient = useQueryClient()
  const [anadiendo, setAnadiendo] = useState(false)
  const [editando, setEditando] = useState<StaffMember | null>(null)
  const [reseteando, setReseteando] = useState<StaffMember | null>(null)
  const [quitando, setQuitando] = useState<StaffMember | null>(null)
  const [accionBot, setAccionBot] = useState<AccionBot | null>(null)

  const query = useQuery({
    queryKey: ['merchant-staff', merchantId],
    queryFn: () => fetchStaff(merchantId),
  })
  const numeros = useQuery({ ...consultaNumerosDelBot(merchantId), enabled: conBot })

  function refrescar() {
    void queryClient.invalidateQueries({ queryKey: ['merchant-staff', merchantId] })
    // La ficha del comercio en el super admin trae el personal por su lado.
    void queryClient.invalidateQueries({ queryKey: ['merchant-detail', merchantId] })
    void queryClient.invalidateQueries({ queryKey: ['merchants'] })
    if (conBot) void queryClient.invalidateQueries({ queryKey: claveNumerosDelBot(merchantId) })
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

  /** El número del bot de cada persona (el vigente), o `null` si no tiene. */
  const botDe = (userId: string): EstadoBot => {
    if (!conBot) return { tipo: 'oculto' }
    if (numeros.isLoading) return { tipo: 'cargando' }
    if (numeros.isError) return { tipo: 'error', reintentar: () => void numeros.refetch() }
    const numero = (numeros.data ?? []).find((n) => n.userId === userId && n.revokedAt === null) ?? null
    return { tipo: 'listo', numero }
  }
  const revocados = (numeros.data ?? []).filter((n) => n.revokedAt !== null)

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="max-w-prose type-panel-body text-on-surface-variant">
          Quién puede entrar al panel de esta clínica y qué puede hacer dentro. Cada
          cuenta es personal: por ella se sabe quién registró cada pago en cuotas.
          {conBot && ' Con su WhatsApp registrado, puede hacer lo mismo con el bot.'}
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
          description="Sin personal, esta clínica no puede registrar pagos en cuotas. Añade al menos una cuenta de secretaria."
        />
      ) : (
        <div className="flex flex-col gap-2">
          {personal.map((s) => (
            <Fila
              key={s.userId}
              miembro={s}
              bot={botDe(s.userId)}
              onEditar={() => setEditando(s)}
              onResetear={() => setReseteando(s)}
              onQuitar={() => setQuitando(s)}
              onBot={setAccionBot}
            />
          ))}
        </div>
      )}

      {conBot && revocados.length > 0 && (
        <details>
          <summary className="cursor-pointer type-panel-caption text-panel-muted">
            Números del bot revocados ({revocados.length})
          </summary>
          <ul className="mt-2 flex flex-col gap-1 type-panel-caption text-panel-muted">
            {revocados.map((n) => (
              <li key={n.id}>
                {telefonoLegible(n.phone)} · {n.staffName ?? 'Sin nombre'} · revocado{' '}
                {n.revokedAt ? formatDateTime(n.revokedAt) : ''}
                {n.revokeReason ? ` (${n.revokeReason})` : ''}
              </li>
            ))}
          </ul>
        </details>
      )}

      {anadiendo && (
        <Alta
          merchantId={merchantId}
          conBot={conBot}
          onDone={refrescar}
          onClose={() => setAnadiendo(false)}
        />
      )}

      {editando && (
        <Edicion
          merchantId={merchantId}
          miembro={editando}
          bot={botDe(editando.userId)}
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

      {accionBot && (
        <DialogoDelBot accion={accionBot} onDone={refrescar} onClose={() => setAccionBot(null)} />
      )}
    </div>
  )
}

// ── El bot ─────────────────────────────────────────────────────────────────

/** El acceso al bot de una persona, tal como lo pinta su tarjeta. */
type EstadoBot =
  | { tipo: 'oculto' }
  | { tipo: 'cargando' }
  | { tipo: 'error'; reintentar: () => void }
  | { tipo: 'listo'; numero: NumeroDelBot | null }

type AccionBot = { tipo: 'revocar' | 'pin'; numero: NumeroDelBot; quien: string }

/** El renglón del bot dentro de la tarjeta: su número, su PIN y qué hacer. */
function LineaDelBot({
  bot,
  quien,
  onBot,
}: {
  bot: EstadoBot
  quien: string
  onBot: (accion: AccionBot) => void
}) {
  const isSuperAdmin = useIsSuperAdmin()
  if (bot.tipo === 'oculto') return null

  return (
    <div className="flex w-full flex-wrap items-center gap-3 border-t border-outline-variant pt-3">
      <MessageCircle size={16} aria-hidden className="shrink-0 text-on-surface-variant" />
      {bot.tipo === 'cargando' && <p className="type-panel-caption text-panel-muted">Leyendo su acceso al bot…</p>}
      {bot.tipo === 'error' && (
        <p className="type-panel-caption text-panel-muted">
          Bot: <NoSePudoLeer onReintentar={bot.reintentar} />
        </p>
      )}
      {bot.tipo === 'listo' && !bot.numero && (
        <p className="flex-1 type-panel-caption text-panel-muted">
          Sin acceso al bot. Para dárselo, pon su WhatsApp en «Editar».
        </p>
      )}
      {bot.tipo === 'listo' && bot.numero && (
        <>
          <p className="min-w-0 flex-1 basis-56 type-panel-caption text-on-surface-variant tabular-nums">
            Bot desde el <span className="text-on-surface">{telefonoLegible(bot.numero.phone)}</span>
            {bot.numero.lastInboundAt
              ? ` · último mensaje ${formatDateTime(bot.numero.lastInboundAt)}`
              : ' · todavía no ha escrito'}
          </p>
          <Badge tone={estadoDelPin(bot.numero).tone} icono>
            {estadoDelPin(bot.numero).texto}
          </Badge>
          <Button
            size="sm"
            variant="text"
            disabled={!isSuperAdmin || !bot.numero.hasPin}
            motivoApagado={!isSuperAdmin ? SOLO_SUPER_ADMIN : 'Todavía no ha creado su PIN'}
            onClick={() => bot.numero && onBot({ tipo: 'pin', numero: bot.numero, quien })}
          >
            Resetear PIN
          </Button>
          <Button
            size="sm"
            variant="text"
            disabled={!isSuperAdmin}
            motivoApagado={SOLO_SUPER_ADMIN}
            onClick={() => bot.numero && onBot({ tipo: 'revocar', numero: bot.numero, quien })}
          >
            Quitar acceso
          </Button>
        </>
      )}
    </div>
  )
}

/** Resetear el PIN o quitar el acceso al bot, con su motivo (bitácora). */
function DialogoDelBot({
  accion,
  onDone,
  onClose,
}: {
  accion: AccionBot
  onDone: () => void
  onClose: () => void
}) {
  const avisar = useToast()
  const mutation = useMutation({
    mutationFn: async (motivo: string) => {
      if (accion.tipo === 'revocar') await revocarNumeroDelBot(accion.numero.id, motivo)
      else await resetearPinDelBot(accion.numero.userId, motivo)
    },
    onSuccess: () => {
      avisar(accion.tipo === 'revocar' ? 'Acceso al bot quitado' : 'PIN reseteado: lo creará de nuevo en su próximo mensaje')
      onDone()
      onClose()
    },
  })

  const revocar = accion.tipo === 'revocar'
  return (
    <ConfirmDialog
      title={revocar ? '¿Quitar el acceso al bot?' : '¿Resetear el PIN?'}
      summary={
        revocar
          ? `${accion.quien} ya no podrá usar el bot desde el ${telefonoLegible(accion.numero.phone)}. Sigue entrando al panel.`
          : `${accion.quien} tendrá que crear un PIN nuevo en su próximo mensaje al bot.`
      }
      confirmLabel={revocar ? 'Quitar acceso' : 'Resetear PIN'}
      nivel="sensible"
      reasonLabel="Motivo"
      reasonPlaceholder={revocar ? 'Perdió el teléfono, ya no trabaja aquí…' : 'Lo olvidó, se bloqueó…'}
      danger={revocar}
      busy={mutation.isPending}
      error={mutation.isError ? describeError(mutation.error) : undefined}
      onConfirm={(motivo) => mutation.mutate(motivo)}
      onClose={onClose}
    />
  )
}

/** Si el WhatsApp escrito para el bot no vale, por qué; vacío vale (sin bot). */
function motivoDelWhatsApp(valor: string): string | undefined {
  if (valor.trim() === '') return undefined
  return celularAE164(valor) ? undefined : 'El WhatsApp del bot tiene que ser un celular: 0414 1234567'
}

// ── La fila ────────────────────────────────────────────────────────────────

/** Por qué no se puede dar de baja a quien está mirando. Lo dice también el servidor. */
const NO_A_SI_MISMO = 'No puedes darte de baja a ti mismo: que lo haga otro administrador o el equipo de Helios.'

function Fila({
  miembro,
  bot,
  onEditar,
  onResetear,
  onQuitar,
  onBot,
}: {
  miembro: StaffMember
  bot: EstadoBot
  onEditar: () => void
  onResetear: () => void
  onQuitar: () => void
  onBot: (accion: AccionBot) => void
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

      <LineaDelBot bot={bot} quien={miembro.name ?? miembro.email ?? 'Esta persona'} onBot={onBot} />
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

/**
 * Lo que pasó después de crear la cuenta. La cuenta ya existe: si el bot o
 * el correo fallan, se dice, pero no se deshace nada.
 */
type DespuesDelAlta = {
  /** `null` si no se pidió el bot; si no, el error o `'ok'`. */
  bot: 'ok' | { error: string } | null
  /** `null` si no se pidió el correo. */
  correo: ResultadoBienvenida | { status: 'error'; error: string } | null
}

function Alta({
  merchantId,
  conBot,
  onDone,
  onClose,
}: {
  merchantId: string
  conBot: boolean
  onDone: () => void
  onClose: () => void
}) {
  const isSuperAdmin = useIsSuperAdmin()
  const [fullName, setFullName] = useState('')
  const [email, setEmail] = useState('')
  const [role, setRole] = useState<MerchantRole>('cajero')
  // Nace generada y se puede escribir encima. El inicializador es una función
  // para que solo corra al montar: si se regenerara en cada repintado, la que
  // se copia no sería la que se guarda.
  const [password, setPassword] = useState(() => generatePassword())
  const [whatsapp, setWhatsapp] = useState('')
  const [mandarCorreo, setMandarCorreo] = useState(true)
  const [despues, setDespues] = useState<DespuesDelAlta | null>(null)

  const conWhatsapp = conBot && whatsapp.trim() !== ''

  const mutation = useMutation({
    mutationFn: async (): Promise<DespuesDelAlta> => {
      const userId = await addStaff({ merchantId, email, password, fullName, role })

      // El bot va antes del correo: así el correo ya dice su número.
      let bot: DespuesDelAlta['bot'] = null
      if (conWhatsapp) {
        try {
          await registrarNumeroDelBot({ userId, merchantId, phone: whatsapp })
          bot = 'ok'
        } catch (e) {
          bot = { error: describeError(e) ?? 'No se pudo registrar' }
        }
      }

      let correo: DespuesDelAlta['correo'] = null
      if (mandarCorreo) {
        try {
          correo = await enviarBienvenida({ merchantId, userId, password })
        } catch (e) {
          correo = { status: 'error', error: describeError(e) ?? 'No se pudo enviar' }
        }
      }
      return { bot, correo }
    },
    onSuccess: (resultado) => {
      setDespues(resultado)
      onDone()
    },
  })

  const correoOk = /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email.trim())

  // Creada: el diálogo deja de ser un formulario y pasa a ser el único
  // momento en que esta contraseña existe en algún sitio legible.
  if (despues) {
    return (
      <ConfirmDialog
        title="Cuenta creada"
        summary={`${fullName || email} ya puede entrar al panel de esta clínica como ${ROL[role].label.toLowerCase()}.`}
        detail={
          <div className="flex flex-col gap-3">
            <Credenciales email={email.trim()} password={password} />
            <ResumenDelAlta despues={despues} email={email.trim()} whatsapp={whatsapp} />
          </div>
        }
        confirmLabel="Listo"
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

          {conBot && (
            <div>
              <Input
                id="alta-whatsapp"
                label="WhatsApp para el bot (opcional)"
                value={whatsapp}
                onChange={setWhatsapp}
                placeholder="0414 1234567"
                inputMode="tel"
                error={!!motivoDelWhatsApp(whatsapp)}
              />
              <p className="mt-2 type-panel-body text-on-surface-variant">
                Desde ese número podrá registrar pagos en cuotas con el bot. La primera vez el bot le pide crear un PIN.
              </p>
            </div>
          )}

          <Checkbox
            id="alta-bienvenida"
            label={`Enviarle por correo sus datos de acceso y cómo usar el bot (con copia a Helios)`}
            checked={mandarCorreo}
            onChange={setMandarCorreo}
          />
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
              : conWhatsapp && !isSuperAdmin
                ? SOLO_SUPER_ADMIN
                : conBot
                  ? motivoDelWhatsApp(whatsapp)
                  : undefined
      }
      busy={mutation.isPending}
      error={mutation.isError ? describeError(mutation.error) : undefined}
      onConfirm={() => mutation.mutate()}
      onClose={onClose}
    />
  )
}

/** Qué pasó con el bot y con el correo, debajo de las credenciales. */
function ResumenDelAlta({
  despues,
  email,
  whatsapp,
}: {
  despues: DespuesDelAlta
  email: string
  whatsapp: string
}) {
  const lineas: Array<{ ok: boolean; texto: string }> = []

  if (despues.bot === 'ok') {
    lineas.push({ ok: true, texto: `Puede usar el bot desde el ${whatsapp.trim()}.` })
  } else if (despues.bot) {
    lineas.push({ ok: false, texto: `No se registró su WhatsApp para el bot: ${despues.bot.error}. Ponlo desde «Editar».` })
  }

  const c = despues.correo
  if (c?.status === 'enviado') {
    lineas.push({ ok: true, texto: `Le enviamos sus datos de acceso a ${email}, con copia a Helios.` })
  } else if (c?.status === 'sin_configurar') {
    lineas.push({ ok: false, texto: 'No se envió el correo: el envío de correos de Helios no está configurado. Pásale los datos por otro canal.' })
  } else if (c) {
    lineas.push({ ok: false, texto: `No se pudo enviar el correo${c.error ? ` (${c.error})` : ''}. Pásale los datos por otro canal.` })
  }

  if (lineas.length === 0) return null
  return (
    <ul className="flex flex-col gap-1">
      {lineas.map((l) => (
        <li key={l.texto} className={`type-panel-body ${l.ok ? 'text-on-surface-variant' : 'text-warning'}`}>
          {l.texto}
        </li>
      ))}
    </ul>
  )
}

// ── Edición ────────────────────────────────────────────────────────────────

function Edicion({
  merchantId,
  miembro,
  bot,
  onDone,
  onClose,
}: {
  merchantId: string
  miembro: StaffMember
  bot: EstadoBot
  onDone: () => void
  onClose: () => void
}) {
  const avisar = useToast()
  const isSuperAdmin = useIsSuperAdmin()
  const [fullName, setFullName] = useState(miembro.name ?? '')
  const [role, setRole] = useState<MerchantRole>(miembro.role)

  // El bot solo se edita con los números ya leídos al abrir: sin ellos no
  // se sabe si el campo vacío es «no tiene» o «no se pudo leer», y si
  // llegaran con la ventana abierta, el campo vacío se leería como «quitarle
  // el acceso». Por eso se congela lo que había al abrir.
  const [botAlAbrir] = useState(bot)
  const conBot = botAlAbrir.tipo === 'listo'
  const numeroActual = botAlAbrir.tipo === 'listo' ? botAlAbrir.numero : null
  const telefonoActual = numeroActual ? telefonoLegible(numeroActual.phone) : ''
  const [whatsapp, setWhatsapp] = useState(telefonoActual)

  const cambioDeRol = role !== miembro.role
  const cambioDeNombre = fullName.trim() !== (miembro.name ?? '')
  const nuevoE164 = celularAE164(whatsapp)
  const cambioDeBot =
    conBot &&
    (whatsapp.trim() === ''
      ? numeroActual !== null
      : nuevoE164 !== null && nuevoE164 !== numeroActual?.phone)
  const quitaElBot = cambioDeBot && whatsapp.trim() === ''

  const mutation = useMutation({
    mutationFn: async () => {
      if (cambioDeRol || cambioDeNombre) {
        await updateStaff({ merchantId, userId: miembro.userId, fullName, role })
      }
      if (cambioDeBot) {
        if (quitaElBot && numeroActual) {
          await revocarNumeroDelBot(numeroActual.id, 'Se quitó al editar la cuenta')
        } else {
          // Si ya tenía otro número, la base lo revoca: «cambio de número».
          await registrarNumeroDelBot({ userId: miembro.userId, merchantId, phone: whatsapp })
        }
      }
    },
    onSuccess: () => {
      avisar(`${fullName || 'La cuenta'} guardada`)
      onDone()
      onClose()
    },
  })

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

          {conBot && (
            <div>
              <Input
                id="editar-whatsapp"
                label="WhatsApp del bot"
                value={whatsapp}
                onChange={setWhatsapp}
                placeholder="Sin acceso al bot"
                inputMode="tel"
                error={!!motivoDelWhatsApp(whatsapp)}
              />
              <p className="mt-2 type-panel-body text-on-surface-variant">
                {quitaElBot
                  ? `Al guardar, ya no podrá usar el bot desde el ${telefonoActual}.`
                  : cambioDeBot && numeroActual
                    ? `Al guardar, el ${telefonoActual} deja de servir y tendrá que crear un PIN nuevo desde el número nuevo.`
                    : numeroActual
                      ? 'Bórralo para quitarle el acceso al bot, o escribe otro para cambiarlo.'
                      : 'Escríbelo para que pueda registrar pagos en cuotas con el bot.'}
              </p>
            </div>
          )}
          {(botAlAbrir.tipo === 'error' || botAlAbrir.tipo === 'cargando') && (
            <p className="type-panel-body text-on-surface-variant">
              Su acceso al bot no se ha podido leer: aquí solo se cambian el nombre y el rol.
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
            : conBot && motivoDelWhatsApp(whatsapp)
              ? motivoDelWhatsApp(whatsapp)
              : cambioDeBot && !isSuperAdmin
                ? SOLO_SUPER_ADMIN
                : !cambioDeRol && !cambioDeNombre && !cambioDeBot
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
          La cuenta no se borra: los pagos en cuotas que registró siguen apuntando a ella, y sin
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
