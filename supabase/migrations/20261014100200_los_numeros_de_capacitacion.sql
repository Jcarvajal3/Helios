-- ============================================================================
-- Helios — Los números de capacitación
--
-- 20261014100100 creaba pacientes demo fijos: el médico solo veía «Helios ya
-- conoce a este paciente» y nunca el alta de un paciente nuevo, que es lo que
-- hará con casi todos sus pacientes. Decisión de Javier (2026-10-14): en la
-- capacitación se enseña el proceso ENTERO, con datos inventados; lo único
-- fijo es el WhatsApp de quien capacita, que es donde el médico ve lo que
-- verán sus pacientes.
--
-- Así queda:
--
--   1. `demo_phones`: los WhatsApp del equipo que capacita. Todo paciente
--      que se registre con uno de esos números —panel o bot, cualquier
--      clínica, cualquier cédula— nace de prueba y demo (trigger en
--      `profiles`). Se pueden crear tantos como hagan falta: cada cédula
--      inventada es un paciente nuevo con el límite real de $150.
--
--   2. A medianoche (Caracas) `helios_demo_reset` revierte sus órdenes y
--      RETIRA cada paciente demo: le quita la cédula (`document_number`
--      null) y anota `demo_retired_at`. Al día siguiente esa cédula vuelve a
--      ser «paciente nuevo». No se borra la fila: sus órdenes y sus asientos
--      la siguen apuntando, el libro es append-only, y `ledger.balance_by_type`
--      reconoce lo de prueba por la bandera de la persona. Sin cédula y
--      retirada, nadie la vuelve a encontrar desde una clínica.
--
--   3. Fuera lo que ya no hace falta: el alta de pacientes demo a mano, el
--      nivel 9 «Demo» y su límite. Los dos pacientes demo que ya existían
--      pasan al nivel 1, sus teléfonos se vuelven números de capacitación y
--      se retiran en el primer reinicio.
--
-- Sigue igual: sus órdenes no le liquidan nada a la clínica (20261014100000)
-- y no cuentan en ninguna cifra (is_test).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Los números
-- ---------------------------------------------------------------------------

create table if not exists public.demo_phones (
  phone_e164 text primary key,
  label      text not null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id)
);

comment on table public.demo_phones is
  'WhatsApp del equipo que capacita a los médicos. Un paciente registrado con uno de estos números nace de prueba y demo, y se retira a medianoche.';

alter table public.demo_phones enable row level security;
revoke all on public.demo_phones from anon, authenticated;

insert into public.demo_phones (phone_e164, label)
select distinct on (p.phone_e164)
       p.phone_e164,
       coalesce(nullif(btrim(regexp_replace(p.full_name, '^\s*demo\s+', '', 'i')), ''), 'Capacitación')
from public.profiles p
where p.is_demo
order by p.phone_e164, p.created_at
on conflict (phone_e164) do nothing;

-- ---------------------------------------------------------------------------
-- 2. El paciente nace demo por su teléfono
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column if not exists demo_retired_at timestamptz;

comment on column public.profiles.demo_retired_at is
  'Cuándo se retiró este paciente demo: sin cédula, ya no se encuentra desde ninguna clínica.';

create or replace function public.helios_mark_demo_patient()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if exists (select 1 from public.demo_phones d where d.phone_e164 = new.phone_e164) then
    new.is_test := true;
    new.is_demo := true;
  end if;
  return new;
end;
$$;

revoke all on function public.helios_mark_demo_patient() from public, anon, authenticated;

drop trigger if exists profiles_demo_por_telefono on public.profiles;
create trigger profiles_demo_por_telefono
  before insert on public.profiles
  for each row execute function public.helios_mark_demo_patient();

-- ---------------------------------------------------------------------------
-- 3. Fuera el nivel Demo y el alta a mano
-- ---------------------------------------------------------------------------

drop function if exists public.admin_create_demo_patient(text, text, text, text, text);
drop function if exists public.admin_set_demo_limit(numeric);
drop function if exists public.admin_demo_patients();

update public.profiles set level = 1 where level = 9;
delete from public.levels where level = 9;

alter table public.levels drop constraint if exists levels_level_range;
alter table public.levels
  add constraint levels_level_range check (level >= 0 and level <= 5);

-- Las dos vuelven a ser las de antes de 20261014100100.
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
  order by l.level;
end;
$$;

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

drop function if exists public.helios_demo_level();

-- ---------------------------------------------------------------------------
-- 4. El reinicio retira
-- ---------------------------------------------------------------------------
-- `p_phone` null: todos los números. `p_actor` null: el de medianoche. Un
-- paciente con una orden que no se dejó revertir no se retira: sale en
-- `sin_reiniciar` y se intenta otra vez la noche siguiente.

drop function if exists public.admin_reset_demo(uuid);
drop function if exists public.helios_demo_reset(uuid, uuid);

alter table public.demo_resets add column if not exists phone_e164 text;

create or replace function public.helios_demo_reset(p_phone text default null, p_actor uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_c      record;
  v_motivo text;
  v_rev    integer := 0;
  v_anul   integer := 0;
  v_ret    integer := 0;
  v_sin    jsonb := '[]'::jsonb;
  v_out    jsonb;
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
                         where p.is_demo and (p_phone is null or p.phone_e164 = p_phone))
    returning 1
  )
  select count(*) into v_anul from anuladas;

  -- Las confirmadas: revertidas.
  for v_c in
    select c.id, c.order_number
    from public.charges c
    join public.profiles p on p.id = c.user_id
    where p.is_demo
      and (p_phone is null or p.phone_e164 = p_phone)
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

  -- Y los pacientes, retirados: sin cédula nadie los vuelve a encontrar, y
  -- esa cédula vuelve a ser la de un paciente nuevo.
  with retirados as (
    update public.profiles p
       set document_number = null,
           demo_retired_at = now()
     where p.is_demo
       and p.demo_retired_at is null
       and (p_phone is null or p.phone_e164 = p_phone)
       and not exists (select 1 from public.charges c
                       where c.user_id = p.id and c.status in ('pending', 'confirmed'))
    returning 1
  )
  select count(*) into v_ret from retirados;

  v_out := jsonb_build_object(
    'revertidas', v_rev,
    'anuladas', v_anul,
    'retirados', v_ret,
    'sin_reiniciar', v_sin
  );

  insert into public.demo_resets (actor, phone_e164, detail)
  values (p_actor, p_phone, v_out);

  -- La bitácora es de personas (`actor` no admite null): el de medianoche
  -- queda solo en `demo_resets`.
  if p_actor is not null then
    perform audit.log(p_actor, 'demo.reset', null, v_out || jsonb_build_object('phone_e164', p_phone));
  end if;

  return v_out;
end;
$$;

revoke all on function public.helios_demo_reset(text, uuid) from public, anon, authenticated;

-- 00:00 en Caracas = 04:00 UTC.
select cron.schedule('helios_demo_reset', '0 4 * * *', 'select public.helios_demo_reset();');

-- ---------------------------------------------------------------------------
-- 5. Lo que usa el superadmin
-- ---------------------------------------------------------------------------

/** Los números de capacitación, lo que tiene cada uno ahora y el último reinicio. */
create or replace function public.admin_demo_phones()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'phones', coalesce((
      select jsonb_agg(jsonb_build_object(
               'phone_e164', d.phone_e164,
               'label', d.label,
               'created_at', d.created_at,
               'patients', (select count(*) from public.profiles p
                            where p.phone_e164 = d.phone_e164 and p.is_demo and p.demo_retired_at is null),
               'open_orders', (select count(*) from public.charges c
                               join public.profiles p on p.id = c.user_id
                               where p.phone_e164 = d.phone_e164 and p.is_demo and c.status = 'confirmed'),
               'pending_orders', (select count(*) from public.charges c
                                  join public.profiles p on p.id = c.user_id
                                  where p.phone_e164 = d.phone_e164 and p.is_demo
                                    and c.status = 'pending' and c.expires_at > now())
             ) order by d.label, d.phone_e164)
      from public.demo_phones d
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

revoke all on function public.admin_demo_phones() from public, anon;
grant execute on function public.admin_demo_phones() to authenticated;

/**
 * Añade el WhatsApp de quien capacita. No vale el de un paciente real: sus
 * respuestas y las del demo se mezclarían en la misma conversación.
 */
create or replace function public.admin_add_demo_phone(p_phone text, p_label text)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid;
  v_phone text;
  v_label text := nullif(regexp_replace(btrim(coalesce(p_label, '')), '\s+', ' ', 'g'), '');
begin
  v_actor := public.helios_assert_super_admin('añadir un número de capacitación');

  v_phone := public.helios_patient_field('phone', p_phone);
  if v_phone is null then
    raise exception 'Teléfono móvil inválido' using errcode = '22023';
  end if;
  if v_label is null or length(v_label) > 60 then
    raise exception 'Escribe quién capacita con ese número (hasta 60 caracteres)' using errcode = '22023';
  end if;

  if exists (select 1 from public.demo_phones where phone_e164 = v_phone) then
    raise exception 'Ese número ya es de capacitación' using errcode = '22023';
  end if;

  if exists (select 1 from public.profiles where phone_e164 = v_phone and not is_test) then
    raise exception 'Ese número es de un paciente real: usa otro para capacitar' using errcode = '22023';
  end if;

  insert into public.demo_phones (phone_e164, label, created_by)
  values (v_phone, v_label, v_actor);

  perform audit.log(v_actor, 'demo.phone_added', null,
    jsonb_build_object('phone_e164', v_phone, 'label', v_label));

  return jsonb_build_object('phone_e164', v_phone, 'label', v_label);
end;
$$;

revoke all on function public.admin_add_demo_phone(text, text) from public, anon;
grant execute on function public.admin_add_demo_phone(text, text) to authenticated;

/**
 * Quita un número. Los pacientes que ya se registraron con él siguen siendo
 * demo y se retiran a medianoche; los nuevos ya serán reales.
 */
create or replace function public.admin_remove_demo_phone(p_phone text)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid;
  v_label text;
begin
  v_actor := public.helios_assert_super_admin('quitar un número de capacitación');

  delete from public.demo_phones where phone_e164 = p_phone
  returning label into v_label;

  if v_label is null then
    raise exception 'Ese número no es de capacitación' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'demo.phone_removed', null,
    jsonb_build_object('phone_e164', p_phone, 'label', v_label));
end;
$$;

revoke all on function public.admin_remove_demo_phone(text) from public, anon;
grant execute on function public.admin_remove_demo_phone(text) to authenticated;

/** El reinicio a mano, de un número o de todos (null). */
create or replace function public.admin_reset_demo(p_phone text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid;
begin
  v_actor := public.helios_assert_super_admin('reiniciar la demo');

  if p_phone is not null and not exists (select 1 from public.demo_phones where phone_e164 = p_phone) then
    raise exception 'Ese número no es de capacitación' using errcode = '22023';
  end if;

  return public.helios_demo_reset(p_phone, v_actor);
end;
$$;

revoke all on function public.admin_reset_demo(text) from public, anon;
grant execute on function public.admin_reset_demo(text) to authenticated;
