-- ============================================================================
-- Ronda — La ficha dice qué teléfono lleva
--
-- Hasta ahora, para saber si alguien va en iOS o en Android y con qué build,
-- había que preguntárselo por WhatsApp. El sistema tenía media respuesta y no
-- la enseñaba:
--
--   · el SISTEMA sí se guardaba — `user_devices.platform` recibe
--     `Platform.OS` en cada `register_device`— pero no salía en ninguna
--     pantalla del panel;
--   · la VERSIÓN no se guardaba en ningún sitio. `helios_app_gate`
--     (20260913110000) recibe el build en cada arranque para decidir si la
--     build sirve, pero es `language sql` y `stable`, y además la puede
--     llamar `anon` antes del login: no tiene a quién atribuirlo ni puede
--     escribir.
--
-- Esta migración pone las tres columnas que faltaban, enseña a
-- `register_device` a rellenarlas, y saca todo por la ficha del super admin.
--
-- ---------------------------------------------------------------------------
-- Por qué el BUILD y no la versión
-- ---------------------------------------------------------------------------
-- La misma razón que el gate: `version` en app.json lleva en "0.1.0" desde el
-- primer día y no la sube nadie. Lo que identifica un binario es el
-- `versionCode` de Android / `buildNumber` de iOS, que EAS incrementa solo.
-- `app_version` se guarda igual porque es lo que una persona reconoce, pero
-- la cifra que sirve para decidir algo es `app_build`.
--
-- ---------------------------------------------------------------------------
-- Lo que esto NO resuelve
-- ---------------------------------------------------------------------------
-- La columna se llena cuando la app llama a `register_device`. Las filas que
-- ya existen se quedan con null hasta que ese teléfono vuelva a registrarse:
-- no hay nada que rellenar hacia atrás, porque el dato nunca se guardó. La
-- ficha lo pinta con un guion y con la fecha en que se vio ese aparato, que
-- juntas dicen la verdad — «no lo sabemos, y esto es de cuándo».
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las tres columnas
-- ---------------------------------------------------------------------------

alter table public.user_devices
  add column if not exists app_build   integer,
  add column if not exists app_version text,
  add column if not exists os_version  text;

comment on column public.user_devices.app_build is
  'versionCode de Android / buildNumber de iOS: el entero que identifica el binario instalado. Null = ese aparato no ha vuelto a registrarse desde que la app lo manda.';

comment on column public.user_devices.app_version is
  'La version legible de app.json ("0.1.0"). Se guarda para poder nombrarla, pero la que decide es app_build.';

comment on column public.user_devices.os_version is
  'Version del sistema operativo: "14", "17.5". Sirve para acotar un fallo que solo pasa en una.';

-- ---------------------------------------------------------------------------
-- 2. `register_device` las rellena
-- ---------------------------------------------------------------------------
-- Los tres parámetros nuevos van al final y con `default null`, así que una
-- app ya instalada —que llama con tres argumentos— sigue resolviendo contra
-- esta misma función y deja los campos como estaban. La firma vieja se borra
-- para que no queden dos candidatas.

drop function if exists public.register_device(text, text, text);

create or replace function public.register_device(
  p_device_hash text,
  p_device_name text default null,
  p_platform    text default null,
  p_app_build   integer default null,
  p_app_version text default null,
  p_os_version  text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_user    uuid := auth.uid();
  v_trusted boolean;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if p_device_hash is null or length(p_device_hash) < 8 then
    raise exception 'device_hash inválido' using errcode = '22023';
  end if;

  insert into public.user_devices (
    user_id, device_hash, device_name, platform,
    app_build, app_version, os_version, is_trusted
  )
  values (
    v_user, p_device_hash, p_device_name, p_platform,
    p_app_build, p_app_version, p_os_version, true
  )
  on conflict (user_id, device_hash) do update
    set last_seen_at = now(),
        -- `coalesce` en todos: una app vieja llama sin estos argumentos, y
        -- machacar con null borraría lo que ya se sabía de ese aparato.
        device_name = coalesce(excluded.device_name, public.user_devices.device_name),
        platform    = coalesce(excluded.platform,    public.user_devices.platform),
        app_build   = coalesce(excluded.app_build,   public.user_devices.app_build),
        app_version = coalesce(excluded.app_version, public.user_devices.app_version),
        os_version  = coalesce(excluded.os_version,  public.user_devices.os_version)
  returning is_trusted into v_trusted;

  return coalesce(v_trusted, false);
end;
$fn$;

comment on function public.register_device(text, text, text, integer, text, text) is
  'Registra el aparato actual y anota que app lleva. Devuelve true si ya era de confianza.';

revoke all on function public.register_device(text, text, text, integer, text, text)
  from public, anon;
grant execute on function public.register_device(text, text, text, integer, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 3. La ficha del super admin lo enseña
-- ---------------------------------------------------------------------------
-- El cuerpo sale entero de 20260917160000 y solo se le añade el bloque
-- `devices`: transcribir a mano trescientas líneas de plpgsql para tocar una
-- es la manera más fiable de perder una por el camino.

create or replace function public.admin_user_detail(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_result jsonb;
  v_block  public.user_credit_blocks%rowtype;
  v_limit  numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'user_id', p.id,
    'full_name', p.full_name,
    'phone_e164', p.phone_e164,
    'document_number', p.document_number,
    'birth_date', p.birth_date,
    'status', p.status,
    'level', p.level,
    'is_blacklisted', p.is_blacklisted,
    'blacklist_reason', p.blacklist_reason,
    'is_test', p.is_test,
    'created_at', p.created_at
  ), l.monthly_limit_usd
  into v_result, v_limit
  from public.profiles p
  join public.levels l on l.level = p.level
  where p.id = p_user_id;

  if v_result is null then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  -- El bloque de crédito abierto explica el disponible. Es la pregunta #1 de
  -- soporte: "pagué una cuota, ¿por qué sigo en cero?" (docs/00-BASES §2.2).
  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user_id and closed_at is null;

  v_result := v_result || jsonb_build_object('credit', jsonb_build_object(
    'level_limit_usd', v_limit,
    'block_charged_usd', coalesce(v_block.charged_usd, 0),
    'block_paid_usd', coalesce(v_block.paid_usd, 0),
    'available_usd', greatest(v_limit - (coalesce(v_block.charged_usd, 0)
                                       - coalesce(v_block.paid_usd, 0)), 0),
    'to_unlock_usd', coalesce(v_block.charged_usd, 0) - coalesce(v_block.paid_usd, 0),
    'block_opened_at', v_block.opened_at
  ));

  v_result := v_result || jsonb_build_object('debt', (
    select jsonb_build_object(
      'open_usd', coalesce(sum(amount_usd) filter (where status = 'pending'), 0),
      'overdue_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and due_date < v_today), 0),
      'paid_usd', coalesce(sum(amount_usd) filter (where status = 'paid'), 0),
      'days_overdue', coalesce(max(v_today - due_date)
        filter (where status = 'pending' and due_date < v_today), 0)
    )
    from public.installments where user_id = p_user_id
  ));

  v_result := v_result || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'charge_id', i.charge_id,
      -- El número de la orden de la que sale esta cuota: es lo que el equipo
      -- teclea en el buscador y lo que el local dicta por teléfono.
      'order_number', ch.order_number,
      'sequence', i.sequence,
      'amount_usd', i.amount_usd,
      'due_date', i.due_date,
      'status', i.status,
      'paid_at', i.paid_at,
      'merchant_name', m.name,
      'days_overdue', greatest(v_today - i.due_date, 0)
    ) order by i.due_date, i.sequence)
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    join public.merchants m on m.id = ch.merchant_id
    where i.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('charges', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ch.id,
      'order_number', ch.order_number,
      'amount_usd', ch.amount_usd,
      'status', ch.status,
      'business_date', ch.business_date,
      'confirmed_at', ch.confirmed_at,
      'merchant_name', m.name,
      'branch_name', b.name,
      'void_reason', ch.void_reason
    ) order by ch.created_at desc)
    from public.charges ch
    join public.merchants m on m.id = ch.merchant_id
    join public.merchant_branches b on b.id = ch.branch_id
    where ch.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('payments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', pr.id,
      'status', pr.status,
      'bank', pr.bank,
      'reference', pr.reference,
      'method', pr.method,
      'amount_usd', q.amount_usd,
      'amount_ves', q.amount_ves,
      'rejection_note', pr.rejection_note,
      'created_at', pr.created_at
    ) order by pr.created_at desc)
    from public.payment_reports pr
    join public.payment_quotes q on q.id = pr.quote_id
    where pr.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('level_changes', coalesce((
    select jsonb_agg(jsonb_build_object(
      'from_level', lc.from_level,
      'to_level', lc.to_level,
      'reason', lc.reason,
      'note', lc.note,
      'actor', lc.actor,
      'created_at', lc.created_at
    ) order by lc.created_at desc)
    from public.level_changes lc
    where lc.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('kyc', (
    select jsonb_build_object(
      'status', v.status,
      'rejection_reason', v.rejection_reason,
      'rejection_detail', v.rejection_detail,
      'reviewed_at', v.reviewed_at,
      'created_at', v.created_at
    )
    from kyc.verifications v
    where v.user_id = p_user_id
    order by v.created_at desc limit 1
  ));

  -- Bits. El saldo va con SUS MOVIMIENTOS y no solo con la cifra: la pregunta
  -- que llega a soporte no es cuántos tiene, es de dónde salieron.
  v_result := v_result || jsonb_build_object('bits', (
    select jsonb_build_object(
      'balance', coalesce(sum(amount), 0),
      'awarded_count', count(*) filter (where amount > 0),
      'last_award_at', max(created_at) filter (where amount > 0)
    )
    from public.bits_entries where user_id = p_user_id
  ));

  v_result := v_result || jsonb_build_object('bits_entries', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', e.id,
      'amount', e.amount,
      'reason', e.reason,
      'created_at', e.created_at,
      -- De qué cuota salió. `business_date` es el día de la COMPRA, que con la
      -- escalera es la mitad de la explicación: los Bits son la distancia
      -- entre esa fecha y el día en que se pagó.
      'business_date', ch.business_date,
      'due_date', i.due_date,
      'paid_at', i.paid_at,
      'merchant_name', m.name
    ) order by e.created_at desc)
    from public.bits_entries e
    left join public.installments i on i.id = e.installment_id
    left join public.charges ch on ch.id = i.charge_id
    left join public.merchants m on m.id = ch.merchant_id
    where e.user_id = p_user_id
  ), '[]'::jsonb));

  -- ── Qué teléfono lleva ──────────────────────────────────────────────────
  -- Los aparatos de esa persona, el último visto primero. Es lo que contesta
  -- «¿en iOS o en Android?» y «¿tiene la build nueva?» sin tener que
  -- preguntárselo por WhatsApp — que es como se preguntaba hasta ahora.
  --
  -- `app_build` puede venir null y eso NO es un aparato raro: es un aparato
  -- que no ha vuelto a registrarse desde que la app aprendió a mandarlo. La
  -- pantalla lo dice con un guion.
  v_result := v_result || jsonb_build_object('devices', coalesce((
    select jsonb_agg(jsonb_build_object(
      'device_name',   d.device_name,
      'platform',      d.platform,
      'app_build',     d.app_build,
      'app_version',   d.app_version,
      'os_version',    d.os_version,
      'is_trusted',    d.is_trusted,
      'first_seen_at', d.first_seen_at,
      'last_seen_at',  d.last_seen_at
    ) order by d.last_seen_at desc)
    from public.user_devices d
    where d.user_id = p_user_id
  ), '[]'::jsonb));

  return v_result;
end;
$$;
