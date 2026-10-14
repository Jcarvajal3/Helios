-- ============================================================================
-- Helios — Los pacientes demo para las capacitaciones
--
-- Quien da la capacitación (equipo de Helios) lleva SU teléfono ligado a un
-- paciente demo y va de médico en médico: el médico busca la cédula demo en
-- su panel o en su bot, registra una consulta, al capacitador le llega la
-- pregunta por WhatsApp, contesta «sí» y el médico ve el resto (orden,
-- número, comprobante, fechas de pago). No es un paciente de ninguna clínica:
-- sirve en todas.
--
-- Lo que hacía falta para que eso aguante semanas sin tocarlo:
--
--   1. `profiles.is_demo`. Implica `is_test`, así que todo lo que ya excluye a
--      las cuentas de prueba (métricas, colas, alertas, el libro) lo excluye,
--      y desde 20261014100000 sus órdenes no le liquidan nada a la clínica.
--
--   2. Un nivel propio, el 9 «Demo», con un límite grande (por defecto $3.000:
--      treinta consultas de $100 en un día). Va en `levels` porque la
--      elegibilidad, la vista previa y la creación leen el límite de ahí, sin
--      tocar el nivel 1 de $150. Está apagado y fuera de «Niveles y cupos»:
--      nadie asciende a él ni se activa por error. Su límite se cambia desde
--      la pantalla de pacientes demo.
--
--   3. El reinicio. Cada noche a las 23:30 (Caracas) se revierten las órdenes
--      confirmadas de los pacientes demo y se anulan las que esperan el «sí».
--      Así nunca llegan al primer vencimiento (7 días): ni mora, ni
--      recordatorios, ni liquidaciones, y al día siguiente el límite está
--      entero. El superadmin lo puede lanzar a mano entre dos capacitaciones.
--
--      La reversa es propia (`helios_demo_reverse_charge`) y no la de
--      `admin_reverse_charge`: esa es del super admin con segundo factor, y un
--      trabajo nocturno no tiene sesión. Esta solo acepta órdenes de un
--      paciente demo, así que no sirve para revertir nada real. Hace lo
--      mismo que aquella: asiento espejo, cuotas y cotizaciones caducadas
--      fuera, comisión revertida, liquidaciones pendientes fuera, el cupo de
--      vuelta y la orden `reverted` (el trigger de 20261005000100 cancela sus
--      avisos). No manda el aviso «Anulamos el consumo»: el capacitador no lo
--      necesita cada noche.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La bandera
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column if not exists is_demo boolean not null default false;

alter table public.profiles
  drop constraint if exists profiles_demo_es_de_prueba;
alter table public.profiles
  add constraint profiles_demo_es_de_prueba check (not is_demo or is_test);

comment on column public.profiles.is_demo is
  'Paciente demo de las capacitaciones a médicos: siempre de prueba (is_test), en el nivel Demo, y sus órdenes se revierten cada noche (helios_demo_reset).';

create index if not exists profiles_is_demo_idx on public.profiles (id) where is_demo;

-- ---------------------------------------------------------------------------
-- 2. El nivel Demo
-- ---------------------------------------------------------------------------

alter table public.levels drop constraint if exists levels_level_range;
alter table public.levels
  add constraint levels_level_range check ((level >= 0 and level <= 5) or level = 9);

insert into public.levels (level, monthly_limit_usd, required_spend_usd, required_months, is_active, label)
values (9, 3000, 0, 0, false, 'Demo')
on conflict (level) do nothing;

create or replace function public.helios_demo_level()
returns smallint
language sql
immutable
as $$ select 9::smallint $$;

comment on function public.helios_demo_level() is
  'El nivel de los pacientes demo. Apagado y fuera de «Niveles y cupos».';

-- «Niveles y cupos» no lo enseña. Copiada de la versión viva salvo el filtro
-- marcado NUEVO.
create or replace function public.admin_level_config()
returns table(level smallint, label text, monthly_limit_usd numeric, required_spend_usd numeric,
              required_months smallint, is_active boolean, user_count integer, exposure_usd numeric)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  select
    l.level, l.label, l.monthly_limit_usd, l.required_spend_usd,
    l.required_months, l.is_active,
    coalesce(u.cnt, 0)::integer,
    coalesce(u.debt, 0)::numeric
  from public.levels l
  left join (
    select p.level as lvl, count(*)::integer as cnt,
           sum(coalesce(d.open_debt, 0)) as debt
    from public.profiles p
    left join (
      select ins.user_id as uid, sum(ins.amount_usd) as open_debt
      from public.installments ins
      where ins.status = 'pending' and not ins.is_test
      group by 1
    ) d on d.uid = p.id
    where not p.is_test
    group by 1
  ) u on u.lvl = l.level
  where l.level >= 1
    and l.level <> public.helios_demo_level()  -- NUEVO
  order by l.level;
end;
$$;

-- Y no se configura desde ahí. Copiada de la versión viva salvo el bloque
-- marcado NUEVO.
create or replace function public.admin_set_level_config(
  p_level              smallint,
  p_monthly_limit_usd  numeric,
  p_required_spend_usd numeric,
  p_required_months    smallint,
  p_is_active          boolean,
  p_label              text default null,
  p_note               text default null
)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_before jsonb;
begin
  perform public.helios_assert_super_admin('configurar los niveles');

  if p_level = 0 then
    raise exception 'El nivel 0 no se configura: es no tener nivel, y se sale de él verificando la identidad'
      using errcode = '22023';
  end if;

  -- NUEVO: activarlo dejaría ascender a pacientes reales a un límite de demo.
  if p_level = public.helios_demo_level() then
    raise exception 'El nivel Demo se cambia desde Pacientes demo' using errcode = '22023';
  end if;

  if p_monthly_limit_usd < 0 or p_required_spend_usd < 0 or p_required_months < 0 then
    raise exception 'Los valores de un nivel no pueden ser negativos'
      using errcode = '22023';
  end if;

  if p_is_active and p_monthly_limit_usd <= 0 then
    raise exception 'Un nivel activo necesita un límite mayor que cero'
      using errcode = '22023';
  end if;

  select to_jsonb(l) into v_before from public.levels l where l.level = p_level;
  if v_before is null then
    raise exception 'Nivel no encontrado' using errcode = 'P0002';
  end if;

  update public.levels
    set monthly_limit_usd  = p_monthly_limit_usd,
        required_spend_usd = p_required_spend_usd,
        required_months    = p_required_months,
        is_active          = p_is_active,
        label              = coalesce(nullif(trim(p_label), ''), label),
        updated_at         = now()
  where level = p_level;

  perform audit.log(v_actor, 'level.configure', null, jsonb_build_object(
    'level', p_level,
    'before', v_before,
    'after', (select to_jsonb(l) from public.levels l where l.level = p_level),
    'note', nullif(trim(p_note), '')
  ));
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. La reversa de una orden demo
-- ---------------------------------------------------------------------------
-- Devuelve null si la revirtió, o el motivo por el que no (el mismo texto que
-- `helios_charge_reverse_blocker`: cuotas pagadas, pago reportado o abierto).
-- Una orden que no es de un paciente demo es un error, no un motivo.

create or replace function public.helios_demo_reverse_charge(p_charge_id uuid, p_actor uuid)
returns text
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_charge  public.charges%rowtype;
  v_bdate   date := public.helios_business_date(now());
  v_bloqueo text;
  v_tx      uuid;
  v_origen  record;
  v_parte   record;
  v_partes  jsonb;
begin
  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  if not exists (select 1 from public.profiles p where p.id = v_charge.user_id and p.is_demo) then
    raise exception 'Solo se reinician las órdenes de un paciente demo' using errcode = '42501';
  end if;

  v_bloqueo := public.helios_charge_reverse_blocker(p_charge_id);
  if v_bloqueo is not null then
    return v_bloqueo;
  end if;

  -- Lo de cada persona, antes de borrar las cuotas.
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', s.user_id, 'financed', s.financed, 'payable', s.payable)), '[]'::jsonb)
  into v_partes
  from (
    select i.user_id, sum(i.financed_usd) as financed, sum(i.amount_usd) as payable
    from public.installments i
    where i.charge_id = p_charge_id
    group by i.user_id
  ) s;

  -- 1. El asiento espejo. Misma clave que `admin_reverse_charge`: una orden no
  --    se revierte dos veces, por ninguno de los dos caminos.
  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('manual_adjustment', 'reverse_charge:' || p_charge_id::text, v_bdate, p_charge_id,
          'Consumo revertido: reinicio de la demo')
  returning id into v_tx;

  for v_origen in
    select e.account_id, e.debit, e.credit
    from ledger.transactions t
    join ledger.entries e on e.transaction_id = t.id
    where t.reference_id = p_charge_id
      and t.type <> 'manual_adjustment'
  loop
    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, v_origen.account_id, v_origen.credit, v_origen.debit);
  end loop;

  -- 2. Las cotizaciones caducadas y las cuotas.
  delete from public.payment_quotes q
  where q.valid_until <= now()
    and not exists (select 1 from public.payment_reports r where r.quote_id = q.id)
    and exists (
      select 1
      from public.payment_quote_items qi
      join public.installments i on i.id = qi.installment_id
      where qi.quote_id = q.id and i.charge_id = p_charge_id
    );

  delete from public.installments where charge_id = p_charge_id;

  -- 3. La comisión y las liquidaciones pendientes (desde 20261014100000 no
  --    debería haber ninguna; si alguna es de antes, se va).
  update public.staff_commissions
     set status = 'revertida', settlement_id = null
   where charge_id = p_charge_id;

  delete from public.settlements
  where charge_id = p_charge_id and status = 'pending';

  -- 4. El cupo vuelve.
  for v_parte in
    select (e->>'user_id')::uuid     as user_id,
           (e->>'financed')::numeric as financed,
           (e->>'payable')::numeric  as payable
    from jsonb_array_elements(v_partes) e
  loop
    update public.user_credit_blocks
    set charged_usd = greatest(charged_usd - v_parte.financed, 0),
        fee_usd     = greatest(fee_usd - (v_parte.payable - v_parte.financed), 0)
    where user_id = v_parte.user_id and closed_at is null;
  end loop;

  -- 5. La orden queda revertida.
  update public.charges
  set status      = 'reverted',
      void_reason = 'Reinicio de la demo',
      voided_by   = p_actor,
      voided_at   = now()
  where id = p_charge_id;

  return null;
end;
$$;

revoke all on function public.helios_demo_reverse_charge(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. El reinicio
-- ---------------------------------------------------------------------------
-- `p_user` null: todos los pacientes demo. `p_actor` null: el trabajo de la
-- noche. Una orden que no se deja revertir no frena a las demás: sale en
-- `sin_reiniciar` con su motivo.
--
-- Cada reinicio, a mano o de noche, deja su fila en `demo_resets`: es lo que
-- la pantalla enseña como «último reinicio».

create table if not exists public.demo_resets (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  actor      uuid references auth.users(id),
  user_id    uuid references public.profiles(id),
  detail     jsonb not null default '{}'::jsonb
);

comment on table public.demo_resets is
  'Cada reinicio de los pacientes demo: actor null = el trabajo de la noche; user_id null = todos.';

alter table public.demo_resets enable row level security;
revoke all on public.demo_resets from anon, authenticated;

create or replace function public.helios_demo_reset(p_user uuid default null, p_actor uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_c        record;
  v_motivo   text;
  v_rev      integer := 0;
  v_anul     integer := 0;
  v_sin      jsonb := '[]'::jsonb;
  v_out      jsonb;
begin
  -- Las que esperan el «sí»: anuladas (el trigger cancela su pregunta).
  with anuladas as (
    update public.charges c
       set status = 'voided',
           void_reason = 'Reinicio de la demo',
           voided_by = p_actor,
           voided_at = now()
     where c.status = 'pending'
       and c.user_id in (select p.id from public.profiles p
                         where p.is_demo and (p_user is null or p.id = p_user))
    returning 1
  )
  select count(*) into v_anul from anuladas;

  -- Las confirmadas: revertidas.
  for v_c in
    select c.id, c.order_number
    from public.charges c
    join public.profiles p on p.id = c.user_id
    where p.is_demo
      and (p_user is null or p.id = p_user)
      and c.status = 'confirmed'
    order by c.created_at
  loop
    begin
      v_motivo := public.helios_demo_reverse_charge(v_c.id, p_actor);
    exception when others then
      v_motivo := sqlerrm;
    end;

    if v_motivo is null then
      v_rev := v_rev + 1;
    else
      v_sin := v_sin || jsonb_build_object('charge_id', v_c.id, 'order_number', v_c.order_number,
                                           'motivo', v_motivo);
    end if;
  end loop;

  v_out := jsonb_build_object(
    'revertidas', v_rev,
    'anuladas', v_anul,
    'sin_reiniciar', v_sin
  );

  insert into public.demo_resets (actor, user_id, detail)
  values (p_actor, p_user, v_out);

  -- La bitácora es de personas (`actor` no admite null): el de la noche
  -- queda solo en `demo_resets`.
  if p_actor is not null then
    perform audit.log(p_actor, 'demo.reset', p_user, v_out);
  end if;

  return v_out;
end;
$$;

revoke all on function public.helios_demo_reset(uuid, uuid) from public, anon, authenticated;

-- 23:30 en Caracas = 03:30 UTC. Antes de la medianoche: la reversa cae en el
-- mismo día operativo que las órdenes.
select cron.schedule('helios_demo_reset', '30 3 * * *', 'select public.helios_demo_reset();');

-- ---------------------------------------------------------------------------
-- 5. Lo que usa el superadmin
-- ---------------------------------------------------------------------------

/**
 * Los pacientes demo, el límite del nivel Demo y el último reinicio.
 */
create or replace function public.admin_demo_patients()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_limit numeric(18,4) := (select l.monthly_limit_usd from public.levels l
                            where l.level = public.helios_demo_level());
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'limit_usd', v_limit,
    'patients', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id,
               'full_name', p.full_name,
               'document_number', p.document_number,
               'phone_e164', p.phone_e164,
               'email', p.email,
               'created_at', p.created_at,
               'used_usd', public.helios_credit_used_usd(p.id),
               'available_usd', case when public.can_take_debt(p.id)
                                     then greatest(v_limit - public.helios_credit_used_usd(p.id), 0)
                                     else 0 end,
               'blocked_reason', public.helios_available_blocked_reason(p.id),
               'pending_orders', (select count(*) from public.charges c
                                  where c.user_id = p.id and c.status = 'pending' and c.expires_at > now()),
               'open_orders', (select count(*) from public.charges c
                               where c.user_id = p.id and c.status = 'confirmed')
             ) order by p.created_at)
      from public.profiles p
      where p.is_demo
    ), '[]'::jsonb),
    'last_reset', (
      select jsonb_build_object('at', r.created_at, 'automatic', r.actor is null, 'detail', r.detail)
      from public.demo_resets r
      order by r.created_at desc, r.id desc
      limit 1
    )
  );
end;
$$;

revoke all on function public.admin_demo_patients() from public, anon;
grant execute on function public.admin_demo_patients() to authenticated;

/**
 * Crea un paciente demo con el teléfono de quien da la capacitación. Los
 * datos que pide el alta de un paciente y que aquí no significan nada
 * (dirección, estado) se rellenan con «Paciente de demostración».
 */
create or replace function public.admin_create_demo_patient(
  p_document   text,
  p_first_name text,
  p_last_name  text,
  p_phone      text,
  p_email      text
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid;
  v_doc   text;
  v_first text;
  v_last  text;
  v_phone text;
  v_email text;
  v_id    uuid;
begin
  v_actor := public.helios_assert_super_admin('crear un paciente demo');

  v_doc   := public.helios_document_key(p_document);
  v_first := public.helios_patient_field('first_name', p_first_name);
  v_last  := public.helios_patient_field('last_name', p_last_name);
  v_phone := public.helios_patient_field('phone', p_phone);
  v_email := public.helios_patient_field('email', p_email);

  if v_first is null or v_last is null then
    raise exception 'Faltan el nombre y el apellido' using errcode = '22023';
  end if;
  if v_phone is null then
    raise exception 'Teléfono móvil inválido' using errcode = '22023';
  end if;
  if v_email is null then
    raise exception 'Correo inválido' using errcode = '22023';
  end if;

  if exists (select 1 from public.profiles where document_key = v_doc) then
    raise exception 'Esa cédula ya es de un paciente: usa otra para la demo' using errcode = '22023';
  end if;

  -- El «sí» escrito se busca por teléfono: dos pacientes con el mismo número
  -- no sabrían a quién responde.
  if exists (select 1 from public.profiles where phone_e164 = v_phone) then
    raise exception 'Ese teléfono ya es de otro paciente' using errcode = '22023';
  end if;

  insert into public.profiles (
    document_number, first_name, last_name, full_name, phone_e164, email,
    state, address, status, level, is_test, is_demo, registered_by
  ) values (
    v_doc, v_first, v_last, v_first || ' ' || v_last, v_phone, v_email,
    'Paciente de demostración', 'Paciente de demostración', 'active',
    public.helios_demo_level(), true, true, v_actor
  )
  returning id into v_id;

  perform audit.log(v_actor, 'demo.patient_created', v_id, jsonb_build_object(
    'document_number', v_doc, 'full_name', v_first || ' ' || v_last, 'phone_e164', v_phone));

  return jsonb_build_object('id', v_id);
end;
$$;

revoke all on function public.admin_create_demo_patient(text, text, text, text, text) from public, anon;
grant execute on function public.admin_create_demo_patient(text, text, text, text, text) to authenticated;

/** El límite del nivel Demo. */
create or replace function public.admin_set_demo_limit(p_limit_usd numeric)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid;
  v_before numeric;
begin
  v_actor := public.helios_assert_super_admin('cambiar el límite de la demo');

  if p_limit_usd is null or p_limit_usd < public.helios_min_charge_usd() or p_limit_usd > 100000 then
    raise exception 'El límite de la demo va del mínimo de una orden a $100.000' using errcode = '22023';
  end if;

  select monthly_limit_usd into v_before from public.levels where level = public.helios_demo_level();

  update public.levels
     set monthly_limit_usd = round(p_limit_usd, 2), updated_at = now()
   where level = public.helios_demo_level();

  perform audit.log(v_actor, 'demo.limit', null, jsonb_build_object(
    'before', v_before, 'after', round(p_limit_usd, 2)));
end;
$$;

revoke all on function public.admin_set_demo_limit(numeric) from public, anon;
grant execute on function public.admin_set_demo_limit(numeric) to authenticated;

/**
 * El reinicio a mano, de un paciente demo o de todos (null). Solo toca
 * órdenes de pacientes demo.
 */
create or replace function public.admin_reset_demo(p_user_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
begin
  v_actor := public.helios_assert_super_admin('reiniciar la demo');

  if p_user_id is not null
     and not exists (select 1 from public.profiles where id = p_user_id and is_demo) then
    raise exception 'Ese paciente no es demo' using errcode = '22023';
  end if;

  return public.helios_demo_reset(p_user_id, v_actor);
end;
$$;

revoke all on function public.admin_reset_demo(uuid) from public, anon;
grant execute on function public.admin_reset_demo(uuid) to authenticated;
