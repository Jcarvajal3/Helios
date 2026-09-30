-- ============================================================================
-- Ronda — Super admin: gestión de usuarios y cobranza
--
-- docs/00-BASES §3.12 dejaba dos filas en blanco: "Gestión de usuarios
-- (bloquear, ajustar nivel)" y "Gestión de mora y cobranza". Esto las cierra.
--
-- La decisión de fondo que hay detrás: **el super admin no escribe en
-- `profiles` con un UPDATE**. Cambiar un estado o un nivel a mano es una de
-- las cosas más delicadas que se pueden hacer aquí —congelar a alguien que
-- está al día, o subirle el límite a un moroso— así que pasa por una RPC que
-- exige motivo, comprueba el rol y deja rastro en `audit.admin_actions` y en
-- `level_changes`. Una bitácora que se pueda saltar no sirve de nada.
--
-- Lo que este archivo NO hace, a propósito: no revierte expulsiones de forma
-- automática ni define si son reversibles. docs/00-BASES D-10 sigue abierta.
-- Lo que da es la palanca manual con motivo obligatorio, que es lo que hace
-- falta mientras esa regla no exista.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Lectura del super admin sobre las tablas de usuario
-- ---------------------------------------------------------------------------
-- Políticas ADICIONALES: se combinan con OR con las que ya existen, así que
-- el usuario sigue viendo lo suyo y el admin ve todo.

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'profiles'
      and policyname = 'profiles_read_admin'
  ) then
    create policy "profiles_read_admin"
      on public.profiles for select to authenticated
      using (public.is_platform_admin());
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'installments'
      and policyname = 'installments_read_admin'
  ) then
    create policy "installments_read_admin"
      on public.installments for select to authenticated
      using (public.is_platform_admin());
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'charges'
      and policyname = 'charges_read_admin'
  ) then
    create policy "charges_read_admin"
      on public.charges for select to authenticated
      using (public.is_platform_admin());
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'user_credit_blocks'
      and policyname = 'credit_blocks_read_admin'
  ) then
    create policy "credit_blocks_read_admin"
      on public.user_credit_blocks for select to authenticated
      using (public.is_platform_admin());
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'level_changes'
      and policyname = 'level_changes_read_admin'
  ) then
    create policy "level_changes_read_admin"
      on public.level_changes for select to authenticated
      using (public.is_platform_admin());
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Directorio de usuarios
-- ---------------------------------------------------------------------------
-- Buscar por teléfono, nombre o cédula. Las tres, porque en la práctica quien
-- llama a soporte a las 3 AM da lo que tenga a mano.
--
-- Va como RPC y no como vista consultable con `.ilike()` desde el cliente
-- para poder devolver en la misma fila la deuda viva y el atraso máximo, que
-- son los dos datos por los que de verdad se ordena esta lista.

create or replace function public.admin_user_directory(
  p_search text default null,
  p_status text default null,
  p_limit  integer default 50
)
returns table (
  user_id        uuid,
  full_name      text,
  phone_e164     text,
  document_number text,
  status         text,
  level          smallint,
  level_limit_usd numeric,
  is_blacklisted boolean,
  created_at     timestamptz,
  open_debt_usd  numeric,
  overdue_usd    numeric,
  days_overdue   integer,
  charge_count   integer,
  last_charge_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_needle text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_needle := nullif(trim(coalesce(p_search, '')), '');

  return query
  select
    p.id,
    p.full_name,
    p.phone_e164,
    p.document_number,
    p.status::text,
    p.level,
    l.monthly_limit_usd,
    p.is_blacklisted,
    p.created_at,
    coalesce(d.open_debt, 0)::numeric,
    coalesce(d.overdue, 0)::numeric,
    coalesce(d.days_late, 0)::integer,
    coalesce(c.cnt, 0)::integer,
    c.last_at
  from public.profiles p
  join public.levels l on l.level = p.level
  left join (
    select
      i.user_id as uid,
      sum(i.amount_usd) as open_debt,
      sum(i.amount_usd) filter (where i.due_date < v_today) as overdue,
      max(v_today - i.due_date) filter (where i.due_date < v_today) as days_late
    from public.installments i
    where i.status = 'pending'
    group by 1
  ) d on d.uid = p.id
  left join (
    select ch.user_id as uid, count(*)::integer as cnt, max(ch.confirmed_at) as last_at
    from public.charges ch
    where ch.status = 'confirmed'
    group by 1
  ) c on c.uid = p.id
  where
    (p_status is null or p.status::text = p_status)
    and (
      v_needle is null
      or p.phone_e164 ilike '%' || v_needle || '%'
      or p.full_name ilike '%' || v_needle || '%'
      or p.document_number ilike '%' || v_needle || '%'
    )
  -- Primero quien más atrasado está: esta lista se abre para cobrar, no para
  -- navegar el padrón.
  order by coalesce(d.days_late, 0) desc, coalesce(d.open_debt, 0) desc, p.created_at desc
  limit least(coalesce(p_limit, 50), 200);
end;
$$;

revoke all on function public.admin_user_directory(text, text, integer) from public, anon;
grant execute on function public.admin_user_directory(text, text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Ficha del usuario
-- ---------------------------------------------------------------------------
-- Todo lo que hace falta para atender una llamada o decidir un ajuste, en una
-- sola respuesta: quién es, cuánto debe, en qué bloque de crédito está, su
-- historial de consumos, sus cuotas, sus pagos reportados y por qué cambió de
-- nivel. Sin esto, cada duda de soporte es una consulta SQL a mano.

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

  return v_result;
end;
$$;

revoke all on function public.admin_user_detail(uuid) from public, anon;
grant execute on function public.admin_user_detail(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Cambiar el estado de un usuario
-- ---------------------------------------------------------------------------
-- La escalera de mora la maneja `process_mora()` sola. Esto es la palanca
-- manual para lo que el motor no puede saber: un fraude detectado, un acuerdo
-- de pago, una expulsión que se decide revertir.
--
-- El motivo es obligatorio. Sin él, dentro de seis meses nadie sabrá por qué
-- esta cuenta está suspendida y la respuesta será "estaba así".

create or replace function public.admin_set_user_status(
  p_user_id uuid,
  p_status  public.profile_status,
  p_note    text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_before public.profile_status;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super_admin puede cambiar el estado de una cuenta'
      using errcode = '42501';
  end if;

  if p_note is null or length(trim(p_note)) < 3 then
    raise exception 'Cambiar el estado de una cuenta requiere motivo'
      using errcode = '22023';
  end if;

  select status into v_before from public.profiles where id = p_user_id for update;
  if not found then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  if v_before = p_status then
    return;
  end if;

  update public.profiles set status = p_status, updated_at = now() where id = p_user_id;

  perform audit.log(v_actor, 'user.set_status', p_user_id, jsonb_build_object(
    'before', v_before, 'after', p_status, 'note', p_note
  ));
end;
$$;

revoke all on function public.admin_set_user_status(uuid, public.profile_status, text)
  from public, anon;
grant execute on function public.admin_set_user_status(uuid, public.profile_status, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Ajustar el nivel a mano
-- ---------------------------------------------------------------------------
-- El motor de niveles (docs/00-BASES §2.6) sube solo y baja por mora. Esto es
-- la excepción con nombre y apellido: queda en `level_changes` con motivo
-- `manual_admin` y actor, igual que exige docs/01 §6.
--
-- **No permite saltar a un nivel inactivo.** Los niveles 4 y 5 existen en el
-- esquema con `is_active = false` y límite 0; ponerle a alguien el nivel 4
-- hoy le dejaría el límite en cero, que es lo contrario de lo que quien
-- pulsa el botón pretende.

create or replace function public.admin_set_user_level(
  p_user_id uuid,
  p_level   smallint,
  p_note    text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_before smallint;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super_admin puede ajustar el nivel' using errcode = '42501';
  end if;

  if p_note is null or length(trim(p_note)) < 3 then
    raise exception 'Ajustar el nivel requiere motivo' using errcode = '22023';
  end if;

  if not exists (select 1 from public.levels where level = p_level and is_active) then
    raise exception 'El nivel % no está activo', p_level using errcode = '22023';
  end if;

  select level into v_before from public.profiles where id = p_user_id for update;
  if not found then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  if v_before = p_level then
    return;
  end if;

  update public.profiles set level = p_level, updated_at = now() where id = p_user_id;

  insert into public.level_changes (user_id, from_level, to_level, reason, actor, note)
  values (p_user_id, v_before, p_level, 'manual_admin', v_actor, p_note);

  perform audit.log(v_actor, 'user.set_level', p_user_id, jsonb_build_object(
    'before', v_before, 'after', p_level, 'note', p_note
  ));
end;
$$;

revoke all on function public.admin_set_user_level(uuid, smallint, text) from public, anon;
grant execute on function public.admin_set_user_level(uuid, smallint, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Marca interna permanente
-- ---------------------------------------------------------------------------
-- `is_blacklisted` sobrevive a la expulsión: si esa cédula vuelve a
-- registrarse, queremos saberlo (docs/00-BASES §2.8). Se separa del estado a
-- propósito — una cuenta puede estar expulsada sin ser fraude, y puede haber
-- fraude en una cuenta que todavía figura activa.

create or replace function public.admin_set_blacklist(
  p_user_id uuid,
  p_flag    boolean,
  p_reason  text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super_admin puede marcar una cuenta' using errcode = '42501';
  end if;

  if p_flag and (p_reason is null or length(trim(p_reason)) < 3) then
    raise exception 'Marcar una cuenta requiere motivo' using errcode = '22023';
  end if;

  update public.profiles
    set is_blacklisted = p_flag,
        blacklist_reason = case when p_flag then p_reason else null end,
        updated_at = now()
  where id = p_user_id;

  if not found then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'user.set_blacklist', p_user_id, jsonb_build_object(
    'flag', p_flag, 'reason', p_reason
  ));
end;
$$;

revoke all on function public.admin_set_blacklist(uuid, boolean, text) from public, anon;
grant execute on function public.admin_set_blacklist(uuid, boolean, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Cola de cobranza
-- ---------------------------------------------------------------------------
-- docs/00-BASES §3.9 tiene la tabla de cadencia entera en blanco: el proceso
-- operativo no existe. Lo que sí existe y no cambia es **a quién hay que
-- llamar hoy y por cuánto**, agrupado por tramo de la escalera de
-- consecuencias (docs/06 §3).
--
-- Se agrupa por usuario, no por cuota: quien llama llama a una persona, y esa
-- persona puede deber tres cuotas de dos locales distintos. Una fila por
-- cuota convertiría una llamada en tres.
--
-- El tramo `por_vencer` (cuotas que vencen en los próximos días) está incluido
-- a propósito: la cobranza que funciona es la que ocurre antes del
-- vencimiento, no después.

create or replace function public.admin_collections(p_horizon_days integer default 3)
returns table (
  user_id        uuid,
  full_name      text,
  phone_e164     text,
  status         text,
  level          smallint,
  bucket         text,
  open_usd       numeric,
  overdue_usd    numeric,
  upcoming_usd   numeric,
  days_overdue   integer,
  next_due_date  date,
  installment_count integer,
  merchants      text[],
  last_payment_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today   date := public.helios_business_date(now());
  v_horizon integer := greatest(least(coalesce(p_horizon_days, 3), 30), 0);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  with pending as (
    select
      i.user_id as uid,
      i.amount_usd,
      i.due_date,
      m.name as merchant_name
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    join public.merchants m on m.id = ch.merchant_id
    where i.status = 'pending'
      and i.due_date <= v_today + v_horizon
  ),
  grouped as (
    select
      uid,
      sum(amount_usd) as open_usd,
      sum(amount_usd) filter (where due_date < v_today) as overdue_usd,
      sum(amount_usd) filter (where due_date >= v_today) as upcoming_usd,
      max(v_today - due_date) as days_late,
      min(due_date) as next_due,
      count(*)::integer as cnt,
      array_agg(distinct merchant_name) as merchant_names
    from pending
    group by 1
  )
  select
    g.uid,
    p.full_name,
    p.phone_e164,
    p.status::text,
    p.level,
    case
      when g.days_late > 30 then 'expulsion'
      when g.days_late > 15 then 'baja_nivel'
      when g.days_late >= 1 then 'congelado'
      when g.days_late = 0  then 'vence_hoy'
      else 'por_vencer'
    end,
    g.open_usd::numeric,
    coalesce(g.overdue_usd, 0)::numeric,
    coalesce(g.upcoming_usd, 0)::numeric,
    greatest(g.days_late, 0)::integer,
    g.next_due,
    g.cnt,
    g.merchant_names,
    (
      select max(pr.created_at) from public.payment_reports pr
      where pr.user_id = g.uid and pr.status = 'reconciled'
    )
  from grouped g
  join public.profiles p on p.id = g.uid
  order by g.days_late desc nulls last, g.open_usd desc;
end;
$$;

revoke all on function public.admin_collections(integer) from public, anon;
grant execute on function public.admin_collections(integer) to authenticated;
