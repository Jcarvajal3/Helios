-- ============================================================================
-- Helios — El paciente lee el nombre del médico titular, con su título
-- (2026-10-19, decidido por Javier; corrige 20261019000100)
--
-- 20261019000100 guardaba un nombre aparte para el paciente
-- (`doctor_display_name`). Javier: «usemos el nombre del médico titular, y el
-- campo nuevo, solo para poner Dr., Dra., etc.». Así que:
--
-- 1. `merchants.doctor_title`: 'Dr.', 'Dra.', 'Lcdo.' o 'Lcda.' (o nada).
--    Sale del nombre que se había guardado; si no había, de un «Dr.» que el
--    titular escribió delante de su nombre. `doctor_display_name` se borra.
-- 2. El nombre es el del titular (`owner_name`), completo y con las
--    mayúsculas arregladas («AROLDO MACAREÑO STELLING» → «Aroldo Macareño
--    Stelling», «del», «de» y «la» en minúscula) y sin un «Dr.» que traiga
--    escrito. Sin titular, el nombre de la clínica.
--    `helios_doctor_name` → «Dra. Nadia Andi Khabbaze Alfaro»;
--    `helios_doctor_ref` → «la Dra. …» (con «Dr.» o «Lcdo.», «el»; sin
--    título, el nombre solo).
-- 3. La ficha lee `doctor_title` y `doctor_name` (lo que leerán sus
--    pacientes) y guarda `doctor_title` (`admin_set_merchant_owner`).
-- ============================================================================

alter table public.merchants
  add column if not exists doctor_title text;

alter table public.merchants
  drop constraint if exists merchants_doctor_title_valido;
alter table public.merchants
  add constraint merchants_doctor_title_valido
  check (doctor_title is null or doctor_title in ('Dr.', 'Dra.', 'Lcdo.', 'Lcda.'));

comment on column public.merchants.doctor_title is
  'Título que va delante del nombre del titular en los mensajes a sus pacientes: Dr., Dra., Lcdo. o Lcda. Vacío: el nombre solo.';

-- El título que ya se había puesto (los 15 aprobados por Javier) o el que el
-- titular escribió delante de su nombre («DR. VICTOR …»).
update public.merchants m
   set doctor_title = x.titulo
  from (
    select id,
           case
             when s ~* '^dra\.?\s'  then 'Dra.'
             when s ~* '^dr\.?\s'   then 'Dr.'
             when s ~* '^lcda\.?\s' then 'Lcda.'
             when s ~* '^lcdo\.?\s' then 'Lcdo.'
           end as titulo
    from (select id, btrim(coalesce(doctor_display_name, owner_name, '')) as s from public.merchants) y
  ) x
 where m.id = x.id and x.titulo is not null and m.doctor_title is null;

alter table public.merchants drop constraint if exists merchants_doctor_display_name_len;
alter table public.merchants drop column if exists doctor_display_name;

-- ---------------------------------------------------------------------------
-- 2. El nombre
-- ---------------------------------------------------------------------------

-- «jesus francisco vivas rodriguez» → «Jesus Francisco Vivas Rodriguez»;
-- «Elizabeth Del valle ponte Castillo» → «Elizabeth del Valle Ponte
-- Castillo». Sin un «Dr.»/«Dra.»/«Lcdo.»/«Lcda.» delante.
create or replace function public.helios_person_name_text(p_name text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select nullif(string_agg(
           case when n > 1 and lower(w) in ('de', 'del', 'la', 'las', 'los', 'y')
                then lower(w) else initcap(w) end,
           ' ' order by n), '')
  from regexp_split_to_table(
         btrim(regexp_replace(regexp_replace(coalesce(p_name, ''), '^\s*(dra|dr|lcda|lcdo|licda|licdo)\.?\s+', '', 'i'),
                              '\s+', ' ', 'g')),
         ' ') with ordinality as t(w, n)
  where w <> '';
$$;

-- «Dra. Nadia Andi Khabbaze Alfaro». Sin titular, el nombre de la clínica.
create or replace function public.helios_doctor_name(p_merchant_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
           when public.helios_person_name_text(m.owner_name) is null then m.name
           else concat_ws(' ', m.doctor_title, public.helios_person_name_text(m.owner_name))
         end
  from public.merchants m where m.id = p_merchant_id;
$$;

-- «la Dra. …», «el Dr. …»; sin título (o sin titular), el nombre solo.
create or replace function public.helios_doctor_ref(p_merchant_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
           when public.helios_person_name_text(m.owner_name) is null then m.name
           when m.doctor_title in ('Dra.', 'Lcda.') then 'la ' || public.helios_doctor_name(m.id)
           when m.doctor_title in ('Dr.', 'Lcdo.')  then 'el ' || public.helios_doctor_name(m.id)
           else public.helios_doctor_name(m.id)
         end
  from public.merchants m where m.id = p_merchant_id;
$$;

revoke all on function public.helios_person_name_text(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. La ficha de la clínica
-- ---------------------------------------------------------------------------

create or replace function public.admin_merchant_detail(p_merchant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_merchant public.merchants%rowtype;
  v_terms    public.merchant_settlement_terms%rowtype;
  v_staff    jsonb;
  v_owed     numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select * into v_merchant from public.merchants where id = p_merchant_id;
  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  select * into v_terms from public.merchant_settlement_terms
  where merchant_id = p_merchant_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', mu.user_id,
    'name', coalesce(nullif(trim(au.raw_user_meta_data ->> 'full_name'), ''), au.email),
    'email', au.email,
    'phone', au.phone,
    'role', mu.role,
    'branch', b.name
  ) order by mu.created_at), '[]'::jsonb) into v_staff
  from public.merchant_users mu
  join auth.users au on au.id = mu.user_id
  left join public.merchant_branches b on b.id = mu.branch_id
  where mu.merchant_id = p_merchant_id and mu.is_active;

  -- La misma cuenta que el guardia de `terminated`: es la cifra que la ficha
  -- enseña como «Le debes X» y la que decide si el botón de Terminar está vivo.
  select coalesce(sum(amount_usd - paid_usd), 0) into v_owed
  from public.settlements
  where merchant_id = p_merchant_id and status in ('pending', 'partial');

  return jsonb_build_object(
    'profile', jsonb_build_object(
      'category', v_merchant.category,
      'city', v_merchant.city,
      'handle', v_merchant.handle,
      'logo_url', v_merchant.logo_url,
      'social_url', v_merchant.social_url,
      'tax_id', v_merchant.tax_id,
      'specialty', v_merchant.specialty,
      'mpps_number', v_merchant.mpps_number,
      'phone', v_merchant.phone,
      'email', v_merchant.email,
      'address', v_merchant.address,
      -- (2026-10-09): el titular.
      'owner_name', v_merchant.owner_name,
      'owner_document', v_merchant.owner_document,
      'college_number', v_merchant.college_number,
      -- NUEVO (2026-10-19): su título y cómo lo leen sus pacientes.
      'doctor_title', v_merchant.doctor_title,
      'doctor_name', public.helios_doctor_name(v_merchant.id)
    ),
    'terms', jsonb_build_object(
      'upfront_pct', v_terms.upfront_pct,
      'per_installment_pct', v_terms.per_installment_pct,
      'commission_pct', v_terms.commission_pct,
      'policy', v_terms.policy,
      -- Helios: la comisión pactada (null = la global) y la que se aplica hoy.
      'staff_commission_usd', (select t.staff_commission_usd
                                 from public.helios_terms_at(p_merchant_id, public.helios_business_date(now())) t),
      'staff_commission_effective_usd', public.helios_staff_commission_for(p_merchant_id, public.helios_business_date(now()))
    ),
    'staff', v_staff,
    'pending_usd', v_owed,
    'payout_account', public.admin_merchant_payout_account(p_merchant_id)
  );
end;
$$;

-- `p`: las claves que se tocan. Ausente o null = no tocar; '' = borrar (salvo
-- el nombre del titular, que no se borra).
create or replace function public.admin_set_merchant_owner(p_merchant_id uuid, p jsonb)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('editar clínicas');
  v_nombre text := nullif(btrim(regexp_replace(p->>'owner_name', '\s+', ' ', 'g')), '');
  v_raw    text := btrim(p->>'owner_document');
  v_doc    text;
  v_col    text := btrim(p->>'college_number');
  v_titulo text := btrim(p->>'doctor_title');
begin
  if v_nombre is not null and (length(v_nombre) < 3 or length(v_nombre) > 120) then
    raise exception 'El nombre del titular no es válido' using errcode = '22023';
  end if;
  if nullif(v_raw, '') is not null then
    v_doc := public.helios_documento(v_raw, 'VEP');
    if v_doc is null then
      raise exception 'La cédula o el pasaporte del titular no parecen válidos' using errcode = '22023';
    end if;
  elsif v_raw = '' then
    v_doc := '';
  end if;
  if v_col is not null and length(v_col) > 30 then
    raise exception 'El número del Colegio es demasiado largo' using errcode = '22023';
  end if;
  if v_titulo <> '' and v_titulo not in ('Dr.', 'Dra.', 'Lcdo.', 'Lcda.') then
    raise exception 'El título debe ser Dr., Dra., Lcdo. o Lcda.' using errcode = '22023';
  end if;

  update public.merchants
     set owner_name     = coalesce(v_nombre, owner_name),
         owner_document = case when v_doc is null then owner_document else nullif(v_doc, '') end,
         college_number = case when v_col is null then college_number else nullif(v_col, '') end,
         doctor_title   = case when v_titulo is null then doctor_title else nullif(v_titulo, '') end,
         updated_at     = now()
   where id = p_merchant_id;

  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.set_owner', p_merchant_id, jsonb_build_object(
    'owner_name', v_nombre, 'owner_document', v_doc, 'college_number', v_col,
    'doctor_title', v_titulo));
end;
$$;
