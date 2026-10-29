-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — La clínica se llama como su médico titular
--
-- Javier, 2026-10-29: los nombres de clínica no sirven para identificar a
-- nadie («CONSULTORIO 1-12 . PISO 1», «El Rosal», «Centro Salud», una
-- dirección entera). Al médico se le conoce por su nombre, así que el nombre
-- de la clínica pasa a ser el de su titular, «Dra. Ana Lara», sin
-- «Consultorio» delante (decisión de Javier, el mismo día: así las tablas se
-- ordenan y se buscan por el médico).
--
-- 1. `merchants.consultorio`: el nombre que traía la clínica («Grupo Médico
--    708») se queda aquí, como un dato secundario junto a la dirección.
-- 2. Un trigger arma `merchants.name` con el título y el nombre del titular,
--    lo mismo que `helios_doctor_name`. Así lo enseñan a la vez el
--    superadmin, sus filtros, el panel de la clínica, el bot y los avisos,
--    sin tocar las funciones que leen `name`.
--    Lo que se escriba en `name` (el alta, `helios_crear_clinica` y
--    `admin_create_merchant` siguen mandando ahí el nombre del consultorio)
--    pasa a `consultorio`, salvo que sea el propio médico («Dra. Priscila
--    Rodriguez», «Od. Marianghela Martínez»): eso no es un consultorio.
--    Sin titular (clínicas heredadas), el nombre se queda como se escribió.
-- 3. `merchant_directory` y `admin_merchant_detail` devuelven `consultorio`,
--    y `admin_set_merchant_profile` lo corrige (null = no tocar, '' = borrar).
-- 4. Las que ya estaban, sin tocar `updated_at`: no son una edición.
--
-- El nombre que leen los pacientes no cambia: ya era el del médico
-- (`helios_doctor_ref`). La razón social de los contratos (`legal_name`)
-- tampoco.
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1. El consultorio
-- ---------------------------------------------------------------------------

alter table public.merchants add column if not exists consultorio text;

comment on column public.merchants.consultorio is
  'El nombre del consultorio o centro médico («Grupo Médico 708»). Dato secundario, como la dirección: el nombre de la clínica (`name`) es el de su médico titular.';

-- ---------------------------------------------------------------------------
-- 2. El nombre es el del médico
-- ---------------------------------------------------------------------------

/** «Dra. Ana Lara» con el título y el nombre que se le pasen; null sin nombre. */
create or replace function public.helios_nombre_del_medico(p_titulo text, p_nombre text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case when public.helios_person_name_text(p_nombre) is null then null
              else concat_ws(' ', nullif(btrim(coalesce(p_titulo, '')), ''), public.helios_person_name_text(p_nombre))
         end
$$;

revoke all on function public.helios_nombre_del_medico(text, text) from public, anon, authenticated;

create or replace function public.helios_la_clinica_se_llama_como_su_medico()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_medico  text := public.helios_nombre_del_medico(new.doctor_title, new.owner_name);
  v_escrito text := nullif(btrim(coalesce(new.name, '')), '');
begin
  -- Lo escrito en `name` es el consultorio, si es nuevo y no es el médico.
  if v_escrito is not null
     and v_escrito is distinct from v_medico
     and v_escrito !~* '^\s*((dra|dr|lcda|lcdo|licda|licdo)\.?|od\.)\s+'
     and (tg_op = 'INSERT' or new.name is distinct from old.name)
     and (tg_op = 'INSERT' or new.consultorio is not distinct from old.consultorio)
  then
    new.consultorio := v_escrito;
  end if;

  new.consultorio := nullif(btrim(coalesce(new.consultorio, '')), '');

  -- Sin titular, el nombre se queda como vino (o el consultorio, si se borró).
  new.name := coalesce(v_medico, v_escrito, new.consultorio, new.name);
  return new;
end;
$$;

-- Corre después de `merchants_nombre_del_titular` (por orden alfabético), que
-- arregla las mayúsculas del titular y saca su título del nombre.
drop trigger if exists merchants_nombre_es_el_medico on public.merchants;
create trigger merchants_nombre_es_el_medico
  before insert or update of name, owner_name, doctor_title, consultorio on public.merchants
  for each row execute function public.helios_la_clinica_se_llama_como_su_medico();

-- ---------------------------------------------------------------------------
-- 3. Lo leen y lo corrigen
-- ---------------------------------------------------------------------------

create or replace view public.merchant_directory
with (security_invoker = true) as
 SELECT id,
    name,
    legal_name,
    tax_id,
    status,
    created_at,
    ( SELECT count(*) AS count
           FROM merchant_users mu
          WHERE mu.merchant_id = m.id AND mu.is_active) AS staff_count,
    ( SELECT count(*) AS count
           FROM charges c
          WHERE c.merchant_id = m.id AND c.status = 'confirmed'::charge_status AND NOT c.is_test) AS sales_count,
    category,
    city,
    handle,
    logo_url,
    social_url,
    is_test,
    ( SELECT count(*) AS count
           FROM charges c
          WHERE c.merchant_id = m.id AND c.status = 'confirmed'::charge_status AND NOT c.is_test AND c.business_date > (helios_business_date(now()) - 30)) AS sales_30d,
    ( SELECT COALESCE(sum(COALESCE(c.base_usd, c.amount_usd)), 0::numeric) AS "coalesce"
           FROM charges c
          WHERE c.merchant_id = m.id AND c.status = 'confirmed'::charge_status AND NOT c.is_test AND c.business_date > (helios_business_date(now()) - 30)) AS financed_30d,
    owner_name,
    -- NUEVO (20261029190000).
    consultorio
   FROM merchants m;

create or replace function public.admin_merchant_detail(p_merchant_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
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
      -- NUEVO (20261029190000): el nombre del consultorio.
      'consultorio', v_merchant.consultorio,
      -- (2026-10-09): el titular.
      'owner_name', v_merchant.owner_name,
      'owner_document', v_merchant.owner_document,
      'college_number', v_merchant.college_number,
      -- (2026-10-19): su título y cómo lo leen sus pacientes.
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
$function$;

-- Un parámetro más al final: se quita la firma vieja para que no quede una
-- sobrecarga ambigua.
drop function if exists public.admin_set_merchant_profile(uuid, merchant_category, text, text, text, text, text, text, text, text, text, text);

create function public.admin_set_merchant_profile(
  p_merchant_id uuid,
  p_category merchant_category,
  p_city text,
  p_handle text,
  p_logo_url text,
  p_social_url text default null,
  p_tax_id text default null,
  p_specialty text default null,
  p_mpps_number text default null,
  p_phone text default null,
  p_email text default null,
  p_address text default null,
  p_consultorio text default null)
returns void
language plpgsql
security definer
set search_path to 'public', 'audit', 'pg_temp'
as $function$
declare
  v_actor  uuid := auth.uid();
  v_handle text;
  v_tax_id text;
  v_email  text := lower(btrim(p_email));
begin
  perform public.helios_assert_super_admin('editar clínicas');

  v_handle := nullif(trim(coalesce(p_handle, '')), '');
  if v_handle is not null then
    v_handle := regexp_replace(v_handle, '^@+', '');
  end if;

  v_tax_id := public.normalize_tax_id(p_tax_id);

  if v_tax_id is not null and exists (
    select 1 from public.merchants where tax_id = v_tax_id and id <> p_merchant_id
  ) then
    raise exception 'Ese RIF ya es de otra clínica' using errcode = '23505';
  end if;

  if nullif(v_email, '') is not null and not public.helios_valid_email(v_email) then
    raise exception 'Correo inválido' using errcode = '22023';
  end if;

  update public.merchants
    set category    = p_category,
        city        = nullif(trim(coalesce(p_city, '')), ''),
        handle      = v_handle,
        logo_url    = nullif(trim(coalesce(p_logo_url, '')), ''),
        social_url  = nullif(trim(coalesce(p_social_url, '')), ''),
        -- Null deja el RIF como estaba: la pantalla de perfil no debe poder
        -- borrar un identificador fiscal por omisión.
        tax_id      = coalesce(v_tax_id, tax_id),
        specialty   = case when p_specialty   is null then specialty   else nullif(trim(p_specialty), '')   end,
        mpps_number = case when p_mpps_number is null then mpps_number else nullif(trim(p_mpps_number), '') end,
        phone       = case when p_phone       is null then phone       else nullif(trim(p_phone), '')       end,
        email       = case when p_email       is null then email       else nullif(v_email, '')             end,
        address     = case when p_address     is null then address     else nullif(trim(p_address), '')     end,
        consultorio = case when p_consultorio is null then consultorio else nullif(trim(p_consultorio), '') end,
        updated_at  = now()
  where id = p_merchant_id;

  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.set_profile', p_merchant_id, jsonb_build_object(
    'category', p_category, 'city', p_city, 'handle', v_handle,
    'logo_url', p_logo_url, 'social_url', p_social_url, 'tax_id', v_tax_id,
    'specialty', p_specialty, 'mpps_number', p_mpps_number, 'phone', p_phone,
    'email', v_email, 'address', p_address, 'consultorio', p_consultorio
  ));
end;
$function$;

revoke all on function public.admin_set_merchant_profile(uuid, merchant_category, text, text, text, text, text, text, text, text, text, text, text) from public, anon;
grant execute on function public.admin_set_merchant_profile(uuid, merchant_category, text, text, text, text, text, text, text, text, text, text, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Las que ya estaban
-- ---------------------------------------------------------------------------

alter table public.merchants disable trigger merchants_touch_updated_at;

-- El nombre pasa a `consultorio` (con la misma regla del trigger) y el
-- trigger, que salta con el cambio, deja `name` con el médico.
update public.merchants
   set consultorio = case
                       when btrim(name) is distinct from public.helios_nombre_del_medico(doctor_title, owner_name)
                        and name !~* '^\s*((dra|dr|lcda|lcdo|licda|licdo)\.?|od\.)\s+'
                       then btrim(name)
                     end
 where consultorio is null;

alter table public.merchants enable trigger merchants_touch_updated_at;
