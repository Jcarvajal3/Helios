-- ============================================================================
-- Ronda — Los avisos automáticos se editan desde el panel
--
-- Hasta hoy el texto de los 15 avisos automáticos vivía dentro de funciones
-- PL/pgSQL. Cambiar una coma era una migración, y nadie fuera de esta carpeta
-- sabía siquiera qué avisos existen: el equipo que escribe el producto no
-- podía leer lo que la app le dice a la gente todos los días.
--
-- ---------------------------------------------------------------------------
-- 1. Un catálogo, no un archivo de textos
-- ---------------------------------------------------------------------------
-- `notification_templates` no guarda solo el copy. Guarda lo que hace falta
-- para MIRAR un aviso sin abrir el SQL: qué lo dispara, qué datos tiene
-- disponibles, si se puede apagar y si su texto se puede tocar desde el panel.
-- Un catálogo que solo tuviera título y cuerpo obligaría a mantener la
-- explicación en otro sitio, y esa explicación es justo lo que falta hoy.
--
-- ---------------------------------------------------------------------------
-- 2. El texto de fábrica NO se borra
-- ---------------------------------------------------------------------------
-- `default_title` / `default_body` son el texto que hay hoy en el código, y se
-- quedan ahí para siempre. Lo que el equipo publica va en `title` / `body`, y
-- se usa SOLO si se puede renderizar entero. Si falta un dato, si alguien deja
-- un marcador que no existe, si la fila se borra — sale el de fábrica.
--
-- Un aviso a medias es peor que un aviso viejo: "Te tocaron $ de una cuenta
-- de" en la pantalla de bloqueo de alguien no se recoge.
--
-- ---------------------------------------------------------------------------
-- 3. Por qué el embudo es `notify()` y no un trigger sobre `notifications`
-- ---------------------------------------------------------------------------
-- Los marcadores necesitan VALORES —el nombre de quien pagó, el local, el
-- importe— y esos valores solo existen donde se construye el aviso. Un trigger
-- sobre la tabla llegaría tarde: tendría el texto ya formateado y tendría que
-- volver a buscar los datos por su cuenta, duplicando en un segundo sitio la
-- lógica de cada aviso.
--
-- Así que `notify()` gana dos parámetros opcionales, `p_key` y `p_vars`, y
-- cada sitio que avisa pasa los datos sueltos además del texto ya montado. El
-- texto montado deja de ser el que sale y pasa a ser el respaldo.
--
-- ---------------------------------------------------------------------------
-- 4. Tres avisos se quedan con el texto fijo, a propósito
-- ---------------------------------------------------------------------------
-- `level_up`, `late_fee_charged` y el "Tu parte bajó" de `claim_charge_share`
-- no nacen en funciones que solo avisan: viven dentro de `evaluate_level`,
-- `charge_late_fee` y el reparto de una cuenta. Hacerlos editables obliga a
-- copiar entera una función del camino del dinero para cambiarle una línea, y
-- eso se hace el día que haya que tocarlas por su propio motivo, no hoy.
--
-- Salen igual en el catálogo, con sus estadísticas y su interruptor: lo único
-- que no admiten es que se les cambie el texto.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El catálogo
-- ---------------------------------------------------------------------------

create table if not exists public.notification_templates (
  -- La clave con la que el aviso se identifica a sí mismo al llamar a
  -- `notify()`. Cuando un sitio no pasa clave se usa el nombre del tipo: por
  -- eso los tres avisos de texto fijo se llaman igual que su tipo.
  key                text primary key,
  type               public.notification_type not null,

  -- Para la pantalla. Sin esto el panel enseñaría claves y tipos de enum, que
  -- es exactamente la barrera que este archivo viene a quitar.
  label              text not null,
  trigger_label      text not null,
  help               text,

  -- Los marcadores que este aviso sabe rellenar, y los que no puede perder.
  -- `admin_save_notification_draft` valida contra los dos: escribir {comercio}
  -- donde no hay comercio dejaría el aviso sin mandar y saldría el de fábrica,
  -- que es seguro pero silencioso — mejor no dejar guardarlo.
  variables          text[] not null default '{}',
  required_variables text[] not null default '{}',

  -- El texto que hay en el código. No se toca nunca.
  default_title      text not null,
  default_body       text not null,

  -- Lo que el equipo publicó. Null = va el de fábrica.
  title              text,
  body               text,
  published_by       uuid references auth.users (id),
  published_at       timestamptz,

  -- El borrador. Lo escribe cualquiera del equipo; publicarlo es del super
  -- admin. Un aviso automático mal escrito sale mil veces sin que nadie lo
  -- mande, así que la barrera es más alta que la de una promoción suelta.
  draft_title        text,
  draft_body         text,
  draft_by           uuid references auth.users (id),
  draft_at           timestamptz,

  enabled            boolean not null default true,

  -- Si su texto se puede editar desde el panel. Ver punto 4 de la cabecera.
  editable           boolean not null default true,

  -- Si se puede apagar. La mayoría NO: el aviso del cargo de grupo es el
  -- control antiabuso de docs/05 §2, y el resultado de un pago o el estado de
  -- la cuenta son cosas que la gente tiene derecho a saber. Se pueden apagar
  -- los que solo acompañan: el que entra al grupo, el recordatorio de cuota,
  -- los Bits y la subida de nivel.
  can_disable        boolean not null default false,

  -- Solo para los dos que dispara el cron. El resto son triggers de evento:
  -- no tienen hora, se encienden o se apagan.
  cron_job           text,
  lead_days          integer,
  -- Hora de Caracas. El cron guarda UTC; la conversión vive en
  -- `admin_set_notification_schedule` y en ningún otro sitio.
  run_at             time,

  sort_order         integer not null default 100
);

comment on table public.notification_templates is
  'Catálogo de los avisos automáticos: qué los dispara, su texto y quién lo publicó.';

alter table public.notification_templates enable row level security;
-- Sin políticas: se lee y se escribe por las RPC de abajo, que comprueban rol.

-- El aviso guarda de qué plantilla salió. Sin esto, medir un aviso concreto
-- sería contar por `type` — y hay tres avisos distintos con el tipo
-- `group_charge`, que es justo el caso en el que el número importaría.
alter table public.notifications
  add column if not exists template_key text;

create index if not exists notifications_template_idx
  on public.notifications (template_key, created_at desc)
  where template_key is not null;

-- ---------------------------------------------------------------------------
-- 2. Los marcadores
-- ---------------------------------------------------------------------------

/** Los `{marcadores}` que aparecen en un texto, sin repetir. */
create or replace function public.notification_markers(p_text text)
returns text[]
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$
  select coalesce(array_agg(distinct m[1]), '{}'::text[])
  from regexp_matches(coalesce(p_text, ''), '\{([a-z_]+)\}', 'g') m;
$fn$;

/**
 * Sustituye los marcadores por sus valores.
 *
 * Devuelve NULL si falta uno. Es deliberado y es la regla que sostiene todo
 * este archivo: no se manda medio texto. Quien llama usa el de fábrica.
 */
create or replace function public.render_notification_text(
  p_template text,
  p_vars     jsonb
)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $fn$
declare
  v_out text := p_template;
  v_key text;
  v_val text;
begin
  if p_template is null then
    return null;
  end if;

  foreach v_key in array public.notification_markers(p_template) loop
    v_val := coalesce(p_vars, '{}'::jsonb) ->> v_key;
    if v_val is null then
      return null;
    end if;
    v_out := replace(v_out, '{' || v_key || '}', v_val);
  end loop;

  return v_out;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. El embudo
-- ---------------------------------------------------------------------------
-- `notify()` pasa de 5 argumentos a 7. Los dos nuevos van con valor por
-- defecto, así que un sitio que todavía no pase clave sigue funcionando igual
-- que ayer: se le busca la plantilla por el nombre del tipo y, si no hay
-- ninguna, sale su texto tal cual. Ningún camino nuevo puede quedarse sin
-- avisar por culpa de una fila que falte en una tabla de configuración.

drop function if exists public.notify(uuid, public.notification_type, text, text, jsonb);

create or replace function public.notify(
  p_user_id uuid,
  p_type    public.notification_type,
  p_title   text,
  p_body    text,
  p_data    jsonb default '{}'::jsonb,
  p_key     text default null,
  p_vars    jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_key   text := coalesce(p_key, p_type::text);
  v_tpl   public.notification_templates%rowtype;
  v_title text := p_title;
  v_body  text := p_body;
  v_try   text;
begin
  select * into v_tpl from public.notification_templates where key = v_key;

  if found then
    -- Apagado es apagado: ni push ni bandeja. Un aviso que se guarda pero no
    -- se manda es una bandeja que crece sin que nadie la mire.
    if not v_tpl.enabled then
      return;
    end if;

    if v_tpl.title is not null then
      v_try := public.render_notification_text(v_tpl.title, p_vars);
      if v_try is not null then
        v_title := v_try;
      end if;
    end if;

    if v_tpl.body is not null then
      v_try := public.render_notification_text(v_tpl.body, p_vars);
      if v_try is not null then
        v_body := v_try;
      end if;
    end if;
  end if;

  insert into public.notifications (user_id, type, title, body, data, template_key)
  values (p_user_id, p_type, v_title, v_body, coalesce(p_data, '{}'::jsonb), v_key);
end;
$fn$;

comment on function public.notify(uuid, public.notification_type, text, text, jsonb, text, jsonb) is
  'Crea un aviso. Renderiza la plantilla del catálogo y cae al texto del código si no puede.';

revoke all on function public.notify(uuid, public.notification_type, text, text, jsonb, text, jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Los 15 avisos que existen hoy
-- ---------------------------------------------------------------------------
-- El texto de fábrica es COPIA EXACTA del que hay en el código, con los datos
-- variables convertidos en marcadores. Si alguna vez difieren manda el código:
-- el catálogo solo se usa cuando alguien publica algo encima.
--
-- `on conflict do nothing`: esta migración se puede volver a correr sin
-- borrarle a nadie el texto que haya publicado.

insert into public.notification_templates (
  key, type, label, trigger_label, help,
  variables, required_variables,
  default_title, default_body,
  editable, can_disable, cron_job, lead_days, run_at, sort_order
) values

-- ── Grupos ────────────────────────────────────────────────────────────────
(
  'group_charge.consumo', 'group_charge'::public.notification_type,
  'Alguien dividió una cuenta contigo',
  'Al confirmarse un consumo pagado por un grupo. Va a todos menos a quien pagó.',
  'Es el control antiabuso de docs/05 §2: frente a la autorización permanente del grupo, el aviso ES el control. Por eso no se puede apagar.',
  array['quien', 'comercio', 'monto', 'total', 'personas', 'grupo', 'extra'],
  array['monto'],
  '{quien} pagó en {comercio}',
  'Te tocaron ${monto} de una cuenta de ${total} entre {personas}, en {grupo}.{extra} Se paga en dos cuotas.',
  true, false, null, null, null, 10
),
(
  'group_charge.entra', 'group_charge'::public.notification_type,
  'Entró alguien al grupo',
  'Al entrar una persona nueva al grupo. Va al resto de integrantes.',
  'El reparto cambia cuando entra alguien, y de eso depende cuánto paga cada quien en la próxima ronda.',
  array['quien', 'grupo', 'personas'],
  array['personas'],
  '{quien} entró a {grupo}',
  'Ya son {personas}. Lo que pague cualquiera se reparte entre todos hasta las 10 AM.',
  true, true, null, null, null, 20
),
(
  'group_charge', 'group_charge'::public.notification_type,
  'Tu parte bajó',
  'Cuando alguien se adjudica una parte de una cuenta ya repartida.',
  'Texto fijo: nace dentro de claim_charge_share, que además de avisar mueve deuda y cuotas.',
  '{}', '{}',
  'Tu parte bajó',
  'Alguien más entró en la cuenta de ${total}. Ahora pagas ${monto}.',
  false, false, null, null, null, 30
),

-- ── Pagos ─────────────────────────────────────────────────────────────────
(
  'payment_reconciled', 'payment_reconciled'::public.notification_type,
  'Confirmamos tu pago',
  'Al conciliarse un pago reportado.',
  null,
  array['monto', 'cuotas'],
  array['monto'],
  'Confirmamos tu pago',
  'Recibimos ${monto}. {cuotas} cuota(s) quedaron al día.',
  true, false, null, null, null, 40
),
(
  'payment_rejected', 'payment_rejected'::public.notification_type,
  'No pudimos confirmar tu pago',
  'Al rechazarse un pago reportado.',
  'El cuerpo es el motivo que escribe quien concilia. Sin {motivo} la persona no sabe qué corregir.',
  array['motivo'],
  array['motivo'],
  'No pudimos confirmar tu pago',
  '{motivo}',
  true, false, null, null, null, 50
),
(
  'installment_due', 'installment_due'::public.notification_type,
  'Tu cuota vence pronto',
  'Cron diario. Avisa de las cuotas que vencen dentro de los días de antelación.',
  'El único aviso con horario y con antelación configurables. El número de días sale también en el título.',
  array['dias', 'monto', 'comercio', 'fecha'],
  array['monto'],
  'Tu cuota vence en {dias} días',
  '${monto} de {comercio}. Vence el {fecha}.',
  true, true, 'helios_installment_reminders', 2, '10:15'::time, 60
),
(
  'late_fee_charged', 'late_fee_charged'::public.notification_type,
  'Cargo por mora',
  'Al cargarse la mora de una cuota vencida.',
  'Texto fijo: nace dentro de charge_late_fee, que crea deuda. El cuerpo cambia según haya una cuota en mora o varias.',
  '{}', '{}',
  'Cargo por mora',
  'Se sumaron ${monto} a tu deuda por una cuota con más de {dias} días de retraso. Va incluido en tu próximo pago.',
  false, false, null, null, null, 70
),
(
  'bits_earned', 'bits_earned'::public.notification_type,
  'Ganaste Bits',
  'Al conciliarse un pago que adelantó cuotas.',
  'Solo sale cuando hubo adelanto. Llega pegado al de "Confirmamos tu pago", y en ese orden.',
  array['bits', 'cuotas'],
  array['bits'],
  '¡Ganaste {bits} Bits!',
  'Por adelantar {cuotas}. Pronto vas a poder canjearlos por premios.',
  true, true, null, null, null, 80
),
(
  'level_up', 'level_up'::public.notification_type,
  'Subiste de nivel',
  'Cron diario, después del barrido de mora y de los recordatorios.',
  'Texto fijo: nace dentro de evaluate_level, que además de avisar mueve el límite de la persona.',
  '{}', '{}',
  'Subiste al {nivel}',
  'Tu límite pasa a ${limite}. Lo lograste pagando ${pagado} a tiempo.',
  false, true, 'helios_level_promotions', null, '10:20'::time, 90
),

-- ── Estado de la cuenta ───────────────────────────────────────────────────
(
  'account_frozen', 'account_frozen'::public.notification_type,
  'Saldo congelado',
  'Al pasar la cuenta a congelada por una cuota vencida.',
  null,
  '{}', '{}',
  'Tu saldo está congelado',
  'Tienes una cuota vencida. Al ponerte al día vuelves a poder consumir.',
  true, false, null, null, null, 100
),
(
  'account_suspended', 'account_suspended'::public.notification_type,
  'Bajaste de nivel por mora',
  'Al pasar la cuenta a suspendida, con más de 15 días de retraso.',
  null,
  array['nivel'],
  array['nivel'],
  'Bajaste de nivel',
  'Llevas más de 15 días de retraso. Pasaste al nivel {nivel}.',
  true, false, null, null, null, 110
),
(
  'account_expelled', 'account_expelled'::public.notification_type,
  'Cuenta cerrada',
  'Al cerrarse la cuenta, con más de 30 días sin pago.',
  null,
  '{}', '{}',
  'Tu cuenta quedó cerrada',
  'Pasaron más de 30 días sin pago. Escríbenos para resolver tu situación.',
  true, false, null, null, null, 120
),
(
  'account_restored', 'account_restored'::public.notification_type,
  'Cuenta al día',
  'Al volver la cuenta a activa desde congelada o suspendida.',
  null,
  '{}', '{}',
  'Tu cuenta volvió a la normalidad',
  'Te pusiste al día. Ya puedes volver a consumir.',
  true, false, null, null, null, 130
),

-- ── Verificación ──────────────────────────────────────────────────────────
(
  'kyc_approved', 'kyc_approved'::public.notification_type,
  'Identidad verificada',
  'Al aprobarse la verificación y quedar la cuenta a la espera del PIN.',
  null,
  '{}', '{}',
  'Verificamos tu identidad',
  'Ya puedes crear tu PIN y empezar a usar Helios.',
  true, false, null, null, null, 140
),
(
  'kyc_rejected', 'kyc_rejected'::public.notification_type,
  'Verificación rechazada',
  'Al rechazarse la verificación de identidad.',
  'El cuerpo es el detalle del rechazo. Sin {motivo} la persona no sabe qué repetir.',
  array['motivo'],
  array['motivo'],
  'No pudimos verificar tu identidad',
  '{motivo}',
  true, false, null, null, null, 150
)

on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 5. Los sitios que avisan pasan a decir de dónde vienen
-- ---------------------------------------------------------------------------
-- Siete funciones, doce avisos. El cuerpo de cada una es el que ya había: lo
-- único que cambia es la llamada a `notify()`, que ahora lleva su clave y sus
-- datos sueltos además del texto ya montado.
--
-- Los triggers no se recrean. Apuntan a estas funciones por nombre y
-- `create or replace` no los toca — recrearlos sería arriesgar un hueco entre
-- el drop y el create por nada.

-- ── El cargo de grupo ─────────────────────────────────────────────────────

create or replace function public.notify_group_charge()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_group    text;
  v_merchant text;
  v_who      text;
  v_count    integer;
  v_even     numeric(18,4);
  v_member   record;
  v_extra    text;
begin
  if new.status <> 'confirmed' or old.status = 'confirmed' or new.group_id is null then
    return null;
  end if;

  select g.name into v_group from public.groups g where g.id = new.group_id;
  select m.name into v_merchant from public.merchants m where m.id = new.merchant_id;
  select coalesce(p.full_name, 'Alguien') into v_who
  from public.profiles p where p.id = new.user_id;

  select count(distinct i.user_id) into v_count
  from public.installments i where i.charge_id = new.id;

  v_even := round(new.amount_usd / greatest(v_count, 1), 2);

  for v_member in
    select i.user_id, sum(i.amount_usd) as total
    from public.installments i
    where i.charge_id = new.id and i.user_id <> new.user_id
    group by i.user_id
  loop
    -- Un céntimo por encima de lo parejo es redondeo, no absorción. El umbral
    -- evita convertir el reparto de céntimos en un aviso alarmante.
    v_extra := case
      when v_member.total > v_even + 0.05
        then format(' Te tocó más de lo parejo ($%s) porque a alguien no le llegaba el techo.',
                    trim(to_char(v_even, 'FM999999990.00')))
      else ''
    end;

    perform public.notify(
      v_member.user_id,
      'group_charge',
      format('%s pagó en %s', v_who, v_merchant),
      format('Te tocaron $%s de una cuenta de $%s entre %s, en %s.%s Se paga en dos cuotas.',
             trim(to_char(v_member.total, 'FM999999990.00')),
             trim(to_char(new.amount_usd, 'FM999999990.00')),
             v_count, coalesce(v_group, 'tu grupo'), v_extra),
      jsonb_build_object(
        'charge_id', new.id,
        'group_id', new.group_id,
        'amount_usd', v_member.total,
        'initiated_by', new.user_id
      ),
      'group_charge.consumo',
      jsonb_build_object(
        'quien',    v_who,
        'comercio', v_merchant,
        'monto',    trim(to_char(v_member.total, 'FM999999990.00')),
        'total',    trim(to_char(new.amount_usd, 'FM999999990.00')),
        'personas', v_count,
        'grupo',    coalesce(v_group, 'tu grupo'),
        'extra',    v_extra
      )
    );
  end loop;

  return null;
end;
$$;

revoke all on function public.notify_group_charge() from public, anon, authenticated;

-- ── Entró alguien al grupo ────────────────────────────────────────────────

create or replace function public.notify_group_joined()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_name   text;
  v_group  text;
  v_member record;
  v_count  integer;
begin
  /**
   * Solo se avisa cuando la fila ENTRA de verdad.
   *
   * Antes esto era `if tg_op = 'UPDATE' and old.left_at is null then return`,
   * que solo tapaba los updates sobre quien seguía dentro. Un update sobre una
   * fila YA marcada como salida se colaba, y `claim_charge_share` hace justo
   * eso al bajarle el gastado a quien se fue: el grupo entero recibía "Fulano
   * entró" por alguien que llevaba horas fuera.
   *
   * Dicho al revés, el trigger aguanta cualquier llamante futuro: avisa en el
   * insert, y en el update solo si resucita a quien se había ido.
   */
  if tg_op = 'UPDATE' and not (old.left_at is not null and new.left_at is null) then
    return null;
  end if;

  select coalesce(p.full_name, 'Alguien') into v_name
  from public.profiles p where p.id = new.user_id;
  select g.name into v_group from public.groups g where g.id = new.group_id;

  select count(*) into v_count from public.group_members
  where group_id = new.group_id and left_at is null;

  for v_member in
    select user_id from public.group_members
    where group_id = new.group_id and left_at is null and user_id <> new.user_id
  loop
    perform public.notify(
      v_member.user_id,
      'group_charge',
      format('%s entró a %s', v_name, coalesce(v_group, 'tu grupo')),
      format('Ya son %s. Lo que pague cualquiera se reparte entre todos hasta las 10 AM.',
             v_count),
      jsonb_build_object('group_id', new.group_id, 'user_id', new.user_id),
      'group_charge.entra',
      jsonb_build_object(
        'quien',    v_name,
        'grupo',    coalesce(v_group, 'tu grupo'),
        'personas', v_count
      )
    );
  end loop;

  return null;
end;
$$;

revoke all on function public.notify_group_joined() from public, anon, authenticated;

-- ── Resultado de un pago reportado ────────────────────────────────────────

create or replace function public.notify_payment_result()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_quote  public.payment_quotes%rowtype;
  v_motivo text;
begin
  if new.status = old.status then
    return null;
  end if;

  select * into v_quote from public.payment_quotes where id = new.quote_id;

  if new.status = 'reconciled' then
    perform public.notify(
      new.user_id, 'payment_reconciled',
      'Confirmamos tu pago',
      format('Recibimos $%s. %s cuota(s) quedaron al día.',
             trim(to_char(v_quote.amount_usd, 'FM999999990.00')),
             v_quote.installment_count),
      jsonb_build_object('report_id', new.id, 'amount_usd', v_quote.amount_usd),
      'payment_reconciled',
      jsonb_build_object(
        'monto',  trim(to_char(v_quote.amount_usd, 'FM999999990.00')),
        'cuotas', v_quote.installment_count
      )
    );

  elsif new.status = 'rejected' then
    -- El motivo es el cuerpo entero del aviso de hoy. Se calcula una vez para
    -- que el respaldo y el marcador no puedan decir cosas distintas.
    v_motivo := coalesce(new.rejection_note,
      'No encontramos esa referencia. Revísala y vuelve a reportarla.');

    perform public.notify(
      new.user_id, 'payment_rejected',
      'No pudimos confirmar tu pago',
      v_motivo,
      jsonb_build_object('report_id', new.id),
      'payment_rejected',
      jsonb_build_object('motivo', v_motivo)
    );
  end if;

  return null;
end;
$$;

revoke all on function public.notify_payment_result() from public, anon, authenticated;

-- ── Estado de la cuenta ───────────────────────────────────────────────────

create or replace function public.notify_account_status()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_level_change public.level_changes%rowtype;
  v_nivel        text;
begin
  if new.status = old.status then
    return null;
  end if;

  if new.status = 'frozen' then
    perform public.notify(
      new.id, 'account_frozen',
      'Tu saldo está congelado',
      'Tienes una cuota vencida. Al ponerte al día vuelves a poder consumir.',
      '{}'::jsonb,
      'account_frozen', '{}'::jsonb
    );

  elsif new.status = 'suspended' then
    select * into v_level_change from public.level_changes
    where user_id = new.id order by created_at desc limit 1;

    v_nivel := coalesce(v_level_change.to_level, new.level)::text;

    perform public.notify(
      new.id, 'account_suspended',
      'Bajaste de nivel',
      format('Llevas más de 15 días de retraso. Pasaste al nivel %s.', v_nivel),
      jsonb_build_object('level', new.level),
      'account_suspended',
      jsonb_build_object('nivel', v_nivel)
    );

  elsif new.status = 'expelled' then
    perform public.notify(
      new.id, 'account_expelled',
      'Tu cuenta quedó cerrada',
      'Pasaron más de 30 días sin pago. Escríbenos para resolver tu situación.',
      '{}'::jsonb,
      'account_expelled', '{}'::jsonb
    );

  elsif new.status = 'active' and old.status in ('frozen', 'suspended') then
    perform public.notify(
      new.id, 'account_restored',
      'Tu cuenta volvió a la normalidad',
      'Te pusiste al día. Ya puedes volver a consumir.',
      '{}'::jsonb,
      'account_restored', '{}'::jsonb
    );

  elsif new.status = 'pending_pin' and old.status = 'pending_kyc' then
    perform public.notify(
      new.id, 'kyc_approved',
      'Verificamos tu identidad',
      'Ya puedes crear tu PIN y empezar a usar Helios.',
      '{}'::jsonb,
      'kyc_approved', '{}'::jsonb
    );
  end if;

  return null;
end;
$$;

revoke all on function public.notify_account_status() from public, anon, authenticated;

-- ── Verificación rechazada ────────────────────────────────────────────────

create or replace function public.notify_kyc_rejected()
returns trigger
language plpgsql
security definer
set search_path = kyc, public, pg_temp
as $$
declare
  v_motivo text;
begin
  if new.status = 'rejected' and old.status <> 'rejected' then
    v_motivo := coalesce(new.rejection_detail,
      'Vuelve a intentarlo con mejor luz y la cédula completa en el recuadro.');

    perform public.notify(
      new.user_id, 'kyc_rejected',
      'No pudimos verificar tu identidad',
      v_motivo,
      jsonb_build_object('verification_id', new.id),
      'kyc_rejected',
      jsonb_build_object('motivo', v_motivo)
    );
  end if;

  return null;
end;
$$;

revoke all on function public.notify_kyc_rejected() from public, anon, authenticated;

-- ── Recordatorio antes del vencimiento ────────────────────────────────────
--
-- La antelación deja de ser una constante del cron y pasa a leerse del
-- catálogo. El argumento sigue existiendo y sigue mandando cuando se pasa: es
-- lo que permite probar el aviso a mano sin tocar la configuración de nadie.

create or replace function public.notify_upcoming_installments(p_days_ahead integer default null)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row   record;
  v_count integer := 0;
  v_lead  integer := coalesce(
    p_days_ahead,
    (select lead_days from public.notification_templates where key = 'installment_due'),
    2
  );
  v_due   date := public.helios_business_date(now()) + v_lead;
begin
  for v_row in
    select i.id, i.user_id, i.amount_usd, i.due_date, i.sequence, m.name as merchant
    from public.installments i
    join public.charges c on c.id = i.charge_id
    join public.merchants m on m.id = c.merchant_id
    where i.status = 'pending' and i.due_date = v_due
  loop
    if exists (
      select 1 from public.notifications
      where user_id = v_row.user_id
        and type = 'installment_due'
        and data->>'installment_id' = v_row.id::text
    ) then
      continue;
    end if;

    perform public.notify(
      v_row.user_id, 'installment_due',
      format('Tu cuota vence en %s días', v_lead),
      format('$%s de %s. Vence el %s.',
             trim(to_char(v_row.amount_usd, 'FM999999990.00')),
             v_row.merchant,
             to_char(v_row.due_date, 'DD/MM')),
      jsonb_build_object('installment_id', v_row.id, 'due_date', v_row.due_date),
      'installment_due',
      jsonb_build_object(
        'dias',     v_lead,
        'monto',    trim(to_char(v_row.amount_usd, 'FM999999990.00')),
        'comercio', v_row.merchant,
        'fecha',    to_char(v_row.due_date, 'DD/MM')
      )
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.notify_upcoming_installments(integer)
  from public, anon, authenticated;

-- Sin el 2 en la orden: el cron pregunta al catálogo cada vez. Si siguiera
-- pasándolo a mano, cambiar la antelación desde el panel no haría nada.
select cron.schedule(
  'helios_installment_reminders',
  '15 14 * * *',
  $cron$ select public.notify_upcoming_installments(); $cron$
);

-- ── Bits ──────────────────────────────────────────────────────────────────

create or replace function public.notify_bits_earned()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_bits   integer;
  v_count  integer;
  v_cuotas text;
begin
  if new.status <> 'reconciled' or old.status = 'reconciled' then
    return null;
  end if;

  -- Lo ganado por las cuotas de ESTA cotización. Una cuota se salda una sola
  -- vez, así que su movimiento no puede venir de un pago anterior.
  select coalesce(sum(e.amount), 0), count(*)
    into v_bits, v_count
  from public.bits_entries e
  join public.payment_quote_items qi on qi.installment_id = e.installment_id
  where qi.quote_id = new.quote_id
    and e.reason = 'early_installment';

  if coalesce(v_bits, 0) <= 0 then
    return null;
  end if;

  v_cuotas := case when v_count = 1 then 'tu cuota' else v_count || ' cuotas' end;

  perform public.notify(
    new.user_id, 'bits_earned',
    format('¡Ganaste %s Bits!', v_bits),
    format('Por adelantar %s. Pronto vas a poder canjearlos por premios.', v_cuotas),
    jsonb_build_object('report_id', new.id, 'bits', v_bits, 'installments', v_count),
    'bits_earned',
    jsonb_build_object('bits', v_bits, 'cuotas', v_cuotas)
  );

  return null;
end;
$$;

comment on function public.notify_bits_earned() is
  'Avisa una sola vez, al confirmarse el pago, de los Bits que ganaron sus cuotas adelantadas.';

revoke all on function public.notify_bits_earned() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. El catálogo, para el panel
-- ---------------------------------------------------------------------------
-- Una sola lectura con todo: qué es cada aviso, qué texto sale hoy, qué hay
-- en borrador y cuántos salieron de verdad en los últimos 30 días.
--
-- El canal y la prioridad NO se guardan en la tabla: se le preguntan a
-- `push_envelope`, que es quien los decide de verdad. Copiarlos aquí sería
-- montar una segunda versión que empieza igual y termina mintiendo.

create or replace function public.admin_notification_catalog()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo para el equipo de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.sort_order), '[]'::jsonb)
    into v_rows
  from (
    select
      t.key, t.type::text as type, t.label, t.trigger_label, t.help,
      t.variables, t.required_variables,
      t.default_title, t.default_body,
      t.title, t.body,
      t.draft_title, t.draft_body, t.draft_at,
      t.enabled, t.editable, t.can_disable,
      t.cron_job, t.lead_days, t.run_at, t.sort_order,
      t.published_at,
      pa.full_name as published_by,
      da.full_name as draft_by,

      -- Cómo lo pinta el teléfono. Se lo preguntamos al sobre real.
      (public.push_envelope(
        'preview', t.type, '', '', '{}'::jsonb,
        '00000000-0000-0000-0000-000000000000'::uuid
      ) ->> 'channelId') as channel,
      (public.push_envelope(
        'preview', t.type, '', '', '{}'::jsonb,
        '00000000-0000-0000-0000-000000000000'::uuid
      ) ->> 'priority') as priority,

      -- Los últimos 30 días. Antes de esta migración los avisos no llevaban
      -- clave, así que la cuenta empieza aquí: un cero puede ser "no ha
      -- pasado" y también "es nuevo el contador".
      (select count(*) from public.notifications n
        where n.template_key = t.key
          and n.created_at > now() - interval '30 days') as sent,
      (select count(*) from public.notifications n
        where n.template_key = t.key
          and n.created_at > now() - interval '30 days'
          and n.read_at is not null) as opened,
      (select count(*) from public.push_deliveries d
        join public.notifications n on n.id = d.notification_id
        where n.template_key = t.key
          and n.created_at > now() - interval '30 days'
          and d.status = 'delivered') as delivered,
      (select count(*) from public.push_deliveries d
        join public.notifications n on n.id = d.notification_id
        where n.template_key = t.key
          and n.created_at > now() - interval '30 days'
          and d.status = 'failed') as failed,
      (select max(n.created_at) from public.notifications n
        where n.template_key = t.key) as last_sent_at
    from public.notification_templates t
    left join public.platform_admins pa on pa.user_id = t.published_by
    left join public.platform_admins da on da.user_id = t.draft_by
  ) q;

  return v_rows;
end;
$fn$;

comment on function public.admin_notification_catalog() is
  'Los avisos automáticos: qué los dispara, su texto, su borrador y su alcance real.';

revoke all on function public.admin_notification_catalog() from public, anon;
grant execute on function public.admin_notification_catalog() to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Escribir: borrador, publicación y vuelta atrás
-- ---------------------------------------------------------------------------

/**
 * Guarda un borrador. Lo puede hacer cualquiera del equipo.
 *
 * La validación es lo importante de esta función. Un marcador que no existe
 * no rompe nada en producción —`notify()` cae al texto de fábrica— pero eso
 * significa que el equipo publicaría un texto y saldría OTRO sin que nadie se
 * entere. Es un fallo silencioso, así que se corta aquí.
 */
create or replace function public.admin_save_notification_draft(
  p_key   text,
  p_title text,
  p_body  text
)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_actor   uuid := auth.uid();
  v_tpl     public.notification_templates%rowtype;
  v_title   text := trim(coalesce(p_title, ''));
  v_body    text := trim(coalesce(p_body, ''));
  v_markers text[];
  v_unknown text[];
  v_missing text[];
begin
  if not public.is_platform_admin() then
    raise exception 'Solo para el equipo de Helios' using errcode = '42501';
  end if;

  select * into v_tpl from public.notification_templates where key = p_key;
  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = '22023';
  end if;

  if not v_tpl.editable then
    raise exception 'El texto de "%" vive dentro de una función de dinero y no se edita desde aquí',
      v_tpl.label using errcode = '42501';
  end if;

  -- Los mismos límites que una promoción: son de la bandeja de Android, no
  -- nuestros.
  if length(v_title) = 0 or length(v_title) > 65 then
    raise exception 'El título va entre 1 y 65 caracteres' using errcode = '22023';
  end if;

  if length(v_body) = 0 or length(v_body) > 240 then
    raise exception 'El texto va entre 1 y 240 caracteres' using errcode = '22023';
  end if;

  v_markers := public.notification_markers(v_title || ' ' || v_body);

  select array_agg(m) into v_unknown
  from unnest(v_markers) m
  where not (m = any (v_tpl.variables));

  if v_unknown is not null then
    raise exception 'Este aviso no sabe rellenar %. Los que tiene son: %',
      array_to_string(v_unknown, ', '),
      coalesce(nullif(array_to_string(v_tpl.variables, ', '), ''), 'ninguno')
      using errcode = '22023';
  end if;

  select array_agg(r) into v_missing
  from unnest(v_tpl.required_variables) r
  where not (r = any (v_markers));

  if v_missing is not null then
    raise exception 'Falta %: sin ese dato el aviso no dice nada útil',
      array_to_string(v_missing, ', ') using errcode = '22023';
  end if;

  update public.notification_templates
     set draft_title = v_title,
         draft_body  = v_body,
         draft_by    = v_actor,
         draft_at    = now()
   where key = p_key;

  perform audit.log(v_actor, 'notification.draft', null::uuid,
    jsonb_build_object('key', p_key, 'title', v_title, 'body', v_body));
end;
$fn$;

revoke all on function public.admin_save_notification_draft(text, text, text) from public, anon;
grant execute on function public.admin_save_notification_draft(text, text, text) to authenticated;

/** Tira el borrador sin publicarlo. Cualquiera del equipo. */
create or replace function public.admin_discard_notification_draft(p_key text)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_actor uuid := auth.uid();
begin
  if not public.is_platform_admin() then
    raise exception 'Solo para el equipo de Helios' using errcode = '42501';
  end if;

  update public.notification_templates
     set draft_title = null, draft_body = null, draft_by = null, draft_at = null
   where key = p_key;

  perform audit.log(v_actor, 'notification.draft_discard', null::uuid,
    jsonb_build_object('key', p_key));
end;
$fn$;

revoke all on function public.admin_discard_notification_draft(text) from public, anon;
grant execute on function public.admin_discard_notification_draft(text) to authenticated;

/**
 * Publica el borrador. **Solo super admin.**
 *
 * A partir de aquí el texto sale en el teléfono de todo el que dispare ese
 * aviso, y a diferencia de una promoción no hace falta que nadie lo mande: el
 * aviso se manda solo, mil veces, hasta que alguien lo cambie.
 */
create or replace function public.admin_publish_notification_template(p_key text)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_actor uuid := auth.uid();
  v_tpl   public.notification_templates%rowtype;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Publicar un aviso es del super admin' using errcode = '42501';
  end if;

  select * into v_tpl from public.notification_templates where key = p_key;
  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = '22023';
  end if;

  if v_tpl.draft_title is null or v_tpl.draft_body is null then
    raise exception 'No hay borrador que publicar' using errcode = '22023';
  end if;

  update public.notification_templates
     set title        = v_tpl.draft_title,
         body         = v_tpl.draft_body,
         published_by = v_actor,
         published_at = now(),
         draft_title  = null,
         draft_body   = null,
         draft_by     = null,
         draft_at     = null
   where key = p_key;

  perform audit.log(v_actor, 'notification.publish', null::uuid,
    jsonb_build_object('key', p_key,
                       'title', v_tpl.draft_title,
                       'body', v_tpl.draft_body));
end;
$fn$;

revoke all on function public.admin_publish_notification_template(text) from public, anon;
grant execute on function public.admin_publish_notification_template(text) to authenticated;

/** Vuelve al texto de fábrica. Solo super admin: es publicar, al revés. */
create or replace function public.admin_reset_notification_template(p_key text)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_actor uuid := auth.uid();
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Volver al texto original es del super admin' using errcode = '42501';
  end if;

  update public.notification_templates
     set title = null, body = null, published_by = null, published_at = null
   where key = p_key;

  perform audit.log(v_actor, 'notification.reset', null::uuid,
    jsonb_build_object('key', p_key));
end;
$fn$;

revoke all on function public.admin_reset_notification_template(text) from public, anon;
grant execute on function public.admin_reset_notification_template(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Los disparadores
-- ---------------------------------------------------------------------------

/**
 * Enciende o apaga un aviso. **Solo super admin.**
 *
 * `can_disable` es la lista de los que sí. Los que no están en ella son los
 * que la gente tiene derecho a recibir —el resultado de un pago, el estado de
 * su cuenta, el cargo que le hizo otro— y apagarlos no es una preferencia de
 * producto: es dejar de contarle a alguien lo que pasa con su dinero.
 */
create or replace function public.admin_set_notification_enabled(
  p_key     text,
  p_enabled boolean
)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_actor uuid := auth.uid();
  v_tpl   public.notification_templates%rowtype;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Encender o apagar un aviso es del super admin' using errcode = '42501';
  end if;

  select * into v_tpl from public.notification_templates where key = p_key;
  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = '22023';
  end if;

  if not p_enabled and not v_tpl.can_disable then
    raise exception '"%" no se puede apagar: %', v_tpl.label,
      coalesce(v_tpl.help, 'es información que la persona tiene derecho a recibir')
      using errcode = '42501';
  end if;

  update public.notification_templates set enabled = p_enabled where key = p_key;

  perform audit.log(v_actor,
    case when p_enabled then 'notification.enable' else 'notification.disable' end,
    null::uuid, jsonb_build_object('key', p_key));
end;
$fn$;

revoke all on function public.admin_set_notification_enabled(text, boolean) from public, anon;
grant execute on function public.admin_set_notification_enabled(text, boolean) to authenticated;

/**
 * Cambia la hora y la antelación de un aviso del cron. **Solo super admin.**
 *
 * La orden que corre el cron NO se reescribe: se lee la que ya tiene el job y
 * se vuelve a programar igual, solo con otro horario. Así este archivo no
 * guarda una segunda copia de qué ejecuta cada aviso, que es la copia que se
 * quedaría vieja.
 *
 * La hora entra en horario de Caracas y se guarda en UTC porque es lo que
 * entiende el cron. La conversión pasa por la base de datos de zonas horarias
 * y no por un "menos cuatro": el día que Venezuela vuelva a mover el reloj,
 * esto sigue estando bien.
 */
create or replace function public.admin_set_notification_schedule(
  p_key       text,
  p_run_at    time,
  p_lead_days integer default null
)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_actor uuid := auth.uid();
  v_tpl   public.notification_templates%rowtype;
  v_cmd   text;
  v_utc   time;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Cambiar el horario de un aviso es del super admin' using errcode = '42501';
  end if;

  select * into v_tpl from public.notification_templates where key = p_key;
  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = '22023';
  end if;

  if v_tpl.cron_job is null then
    raise exception '"%" no lo dispara el cron: lo dispara un evento, y un evento no tiene hora',
      v_tpl.label using errcode = '22023';
  end if;

  if p_run_at is null then
    raise exception 'Hace falta una hora' using errcode = '22023';
  end if;

  if p_lead_days is not null and p_lead_days not between 1 and 30 then
    raise exception 'La antelación va entre 1 y 30 días' using errcode = '22023';
  end if;

  select command into v_cmd from cron.job where jobname = v_tpl.cron_job;
  if v_cmd is null then
    raise exception 'El cron no tiene ningún trabajo llamado %', v_tpl.cron_job
      using errcode = '22023';
  end if;

  v_utc := (((current_date + p_run_at) at time zone 'America/Caracas')
            at time zone 'UTC')::time;

  perform cron.schedule(
    v_tpl.cron_job,
    format('%s %s * * *',
           extract(minute from v_utc)::integer,
           extract(hour   from v_utc)::integer),
    v_cmd
  );

  update public.notification_templates
     set run_at    = p_run_at,
         lead_days = coalesce(p_lead_days, lead_days)
   where key = p_key;

  perform audit.log(v_actor, 'notification.schedule', null::uuid,
    jsonb_build_object('key', p_key, 'run_at', p_run_at, 'lead_days', p_lead_days));
end;
$fn$;

revoke all on function public.admin_set_notification_schedule(text, time, integer) from public, anon;
grant execute on function public.admin_set_notification_schedule(text, time, integer) to authenticated;
